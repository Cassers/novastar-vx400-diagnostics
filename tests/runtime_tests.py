"""End-to-end PowerShell tests against a local fake VX400. No hardware access."""
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
POWERSHELL = os.environ.get("VX400_POWERSHELL") or shutil.which("powershell") or shutil.which("pwsh")


def receive(connection, count):
    data = b""
    while len(data) < count:
        chunk = connection.recv(count - len(data))
        if not chunk:
            raise EOFError("partial request")
        data += chunk
    return data


def make_reply(request, payload=b""):
    header = bytearray(request[:18])
    header[:2] = b"\xaa\x55"
    header[4:6] = bytes((request[5], request[4]))
    header[16:18] = struct.pack("<H", len(payload))
    frame = header + payload
    return bytes(frame) + struct.pack("<H", (0x5555 + sum(frame[2:])) & 0xFFFF)


class FakeDevice:
    def __init__(self, fault=None):
        self.fault = fault
        self.requests = []
        self.errors = []
        self.stop = threading.Event()
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.port = self.listener.getsockname()[1]
        self.listener.listen()
        self.listener.settimeout(0.1)
        self.thread = threading.Thread(target=self.run, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join(timeout=3)
        self.listener.close()

    def run(self):
        while not self.stop.is_set():
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            with connection:
                connection.settimeout(2)
                try:
                    request = receive(connection, 18)
                    is_write = request[10] == 1
                    count = struct.unpack_from("<H", request, 16)[0] if is_write else 0
                    request += receive(connection, count + 2)
                    self.requests.append(request)
                    checksum = struct.unpack_from("<H", request, len(request)-2)[0]
                    assert checksum == ((0x5555 + sum(request[2:-2])) & 0xFFFF)
                    address = struct.unpack_from("<I", request, 12)[0]
                    payload = b"" if is_write else b"\x11\x62" if address == 2 else bytes(256)
                    reply = make_reply(request, payload)
                    if self.fault == "identity_checksum" and address == 2:
                        reply = reply[:-1] + bytes((reply[-1] ^ 1,))
                    if self.fault == "write_no_ack" and is_write and len([r for r in self.requests if r[10] == 1]) == 1:
                        continue  # device applied the request but reply was lost
                    if self.fault == "restore_brightness_no_ack" and is_write and address == 0x02000001 and request[18] == 76:
                        continue
                    # Force split header/payload/checksum over several TCP reads.
                    for offset in range(0, len(reply), 3):
                        connection.sendall(reply[offset:offset+3])
                        time.sleep(0.001)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                except Exception as error:
                    self.errors.append(repr(error))


@unittest.skipUnless(POWERSHELL, "PowerShell runtime not installed")
class RuntimeTests(unittest.TestCase):
    def run_script(self, directory, arguments):
        result = subprocess.run([POWERSHELL, "-NoLogo", "-NoProfile", "-File", str(ROOT / "Test-Vx400.ps1"),
                                 "-OutputDirectory", str(directory), *arguments], capture_output=True, text=True, timeout=30)
        paths = list(Path(directory).glob("vx400-*/diagnostico.json"))
        report = json.loads(paths[0].read_text(encoding="utf-8-sig")) if paths else None
        return result, report

    def test_inventory_no_firmware_fabrication(self):
        with tempfile.TemporaryDirectory() as directory:
            result, report = self.run_script(directory, ["-InventoryOnly", "-AssumeLatestFirmware"])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(report["assumptions"]["latest_firmware_assumed"])
            self.assertFalse(report["firmware"]["controller"]["verified_automatically"])
            self.assertFalse(report["firmware"]["controller"]["version"])

    def test_default_only_sends_documented_reads(self):
        with FakeDevice() as device, tempfile.TemporaryDirectory() as directory:
            result, report = self.run_script(directory, ["-DeviceAddress", "127.0.0.1", "-TcpPort", str(device.port)])
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(len(device.requests), 2)
            self.assertTrue(all(request[10] == 0 for request in device.requests))
            self.assertEqual(report["active_tests"], [])
            self.assertFalse(device.errors, device.errors)

    def test_bad_checksum_blocks_active_requests(self):
        with FakeDevice("identity_checksum") as device, tempfile.TemporaryDirectory() as directory:
            result, report = self.run_script(directory, ["-DeviceAddress", "127.0.0.1", "-TcpPort", str(device.port),
                "-EnableActiveTests", "-TestBrightness", "5", "-RestoreBrightness", "30", "-RestoreMode", "Normal"])
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertTrue(all(request[10] == 0 for request in device.requests))
            identity = next(item for item in report["checks"] if item["name"] == "identificacion")
            self.assertEqual(identity["status"], "inconclusive")
            self.assertTrue(identity["evidence"]["raw_hex"])

    def test_active_success_and_restoration(self):
        with FakeDevice() as device, tempfile.TemporaryDirectory() as directory:
            result, report = self.run_script(directory, ["-DeviceAddress", "127.0.0.1", "-TcpPort", str(device.port),
                "-EnableActiveTests", "-TestBrightness", "5", "-TestPattern", "White", "-HoldSeconds", "1",
                "-RestoreBrightness", "30", "-RestoreMode", "Normal"])
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            writes = [r for r in device.requests if r[10] == 1]
            self.assertEqual([r[18:-2] for r in writes], [b"\x0c", b"\x06\x04", b"\x05\x00", b"\x4c", b"\x03\x00"])
            self.assertEqual(len(report["restoration"]), 3)
            self.assertFalse(device.errors, device.errors)

    def test_uncertain_write_still_restores(self):
        with FakeDevice("write_no_ack") as device, tempfile.TemporaryDirectory() as directory:
            result, report = self.run_script(directory, ["-DeviceAddress", "127.0.0.1", "-TcpPort", str(device.port),
                "-EnableActiveTests", "-TestBrightness", "5", "-RestoreBrightness", "30", "-RestoreMode", "Normal"])
            self.assertEqual(result.returncode, 2)
            writes = [r for r in device.requests if r[10] == 1]
            self.assertEqual([r[18:-2] for r in writes], [b"\x0c", b"\x05\x00", b"\x4c", b"\x03\x00"])
            self.assertEqual(len(report["restoration"]), 3)

    def test_no_normal_after_failed_brightness_restore(self):
        with FakeDevice("restore_brightness_no_ack") as device, tempfile.TemporaryDirectory() as directory:
            result, report = self.run_script(directory, ["-DeviceAddress", "127.0.0.1", "-TcpPort", str(device.port),
                "-EnableActiveTests", "-TestBrightness", "5", "-HoldSeconds", "1", "-RestoreBrightness", "30", "-RestoreMode", "Normal"])
            self.assertEqual(result.returncode, 2)
            writes = [r[18:-2] for r in device.requests if r[10] == 1]
            self.assertNotIn(b"\x03\x00", writes)
            self.assertEqual(report["restoration"][-1]["status"], "failed")

    def test_missing_explicit_enable_has_no_network(self):
        with FakeDevice() as device, tempfile.TemporaryDirectory() as directory:
            result, _ = self.run_script(directory, ["-DeviceAddress", "127.0.0.1", "-TcpPort", str(device.port), "-TestBrightness", "5"])
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(device.requests, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
