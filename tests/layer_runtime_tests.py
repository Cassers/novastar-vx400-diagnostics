"""Layer entrypoint integration: actual child PowerShell, TCP simulator, no hardware."""
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

from runtime_tests import receive, make_reply

ROOT = Path(__file__).resolve().parents[1]
POWERSHELL = os.environ.get("VX400_POWERSHELL") or shutil.which("powershell") or shutil.which("pwsh")
BASE = 0x13020010


def block(number):
    data = bytearray(48)
    data[1], data[4], data[47] = number, 0x11, 100
    struct.pack_into("<IIII", data, 5, 10, 20, 1920, 1080)
    data[21:47] = bytes(range(150, 176))
    return data


class LayerDevice:
    def __init__(self, fault=None):
        self.fault, self.requests, self.errors = fault, [], []
        self.blocks = [block(i) for i in range(3)]
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
        self.thread.join(timeout=4)
        self.listener.close()

    @property
    def writes(self):
        return [r for r in self.requests if r[10] == 1]

    def run(self):
        while not self.stop.is_set():
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            with connection:
                try:
                    connection.settimeout(2)
                    request = receive(connection, 18)
                    is_write = request[10] == 1
                    count = struct.unpack_from("<H", request, 16)[0]
                    request += receive(connection, (count if is_write else 0) + 2)
                    self.requests.append(request)
                    assert struct.unpack_from("<H", request, len(request)-2)[0] == ((0x5555 + sum(request[2:-2])) & 65535)
                    address = struct.unpack_from("<I", request, 12)[0]
                    if address == 2:
                        payload = b"\x11\x62" if self.fault == "wrong_model" else b"\x0e\x62"
                    else:
                        assert address in [BASE + 48*i for i in range(3)]
                        assert count == 48
                        index = (address - BASE)//48
                        if is_write:
                            if self.fault != "readback_mismatch":
                                self.blocks[index] = bytearray(request[18:-2])
                            if self.fault == "other_layer_sideeffect":
                                self.blocks[2][0] ^= 1
                            payload = b""
                        else:
                            payload = bytes(self.blocks[index])
                            if self.fault == "malformed" and index == 1:
                                payload = payload[:1] + b"\x02" + payload[2:]
                            if self.fault == "unavailable":
                                payload = b""
                            if self.fault == "observation_gap":
                                time.sleep(.5)
                    if self.fault == "no_ack" and is_write:
                        continue
                    reply = make_reply(request, payload)
                    if self.fault == "bad_ack" and is_write:
                        reply = reply[:-1] + bytes([reply[-1] ^ 1])
                    for offset in range(0, len(reply), 7):
                        connection.sendall(reply[offset:offset+7])
                except (BrokenPipeError, ConnectionResetError):
                    pass
                except Exception as error:
                    self.errors.append(repr(error))


@unittest.skipUnless(POWERSHELL, "PowerShell runtime not installed")
class LayerRuntimeTests(unittest.TestCase):
    def invoke(self, device, directory, action="Read", patch=None, enable=True, model="VX600", gap=None):
        directory = Path(directory)
        config = json.loads((ROOT/"plan.config.json").read_text(encoding="utf-8-sig"))
        config.update(deviceAddress="127.0.0.1", tcpPort=device.port, deviceModel=model)
        if gap is not None:
            config.update(maximumObservationGapSeconds=gap, pollIntervalSeconds=0.1, timeoutMs=1000)
        (directory/"config.json").write_text(json.dumps(config))
        args = [POWERSHELL, "-NoProfile", "-File", str(ROOT/"Invoke-VxLayer.ps1"),
                "-ConfigPath", str(directory/"config.json"), "-DataDirectory", str(directory/"data"), "-Action", action]
        if action == "Apply":
            (directory/"changes.json").write_text(json.dumps(patch if patch is not None else {"enabled": True}))
            args += ["-Layer", "PIP1", "-ChangesPath", str(directory/"changes.json")]
            if enable:
                args += ["-EnableControl"]
        result = subprocess.run(args, capture_output=True, text=True, timeout=20)
        report = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertFalse(device.errors, device.errors)
        return result, report

    def test_read_three_layers_no_writes(self):
        with LayerDevice() as device, tempfile.TemporaryDirectory() as directory:
            result, report = self.invoke(device, directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([v["layer"] for v in report["layers"]], ["Main", "PIP1", "PIP2"])
            self.assertTrue(all(isinstance(v["enabled"], bool) for v in report["layers"]))
            self.assertEqual(report["deviceModel"], "VX600")
            self.assertEqual(len(device.requests), 4)
            self.assertEqual(device.writes, [])

    def test_apply_preserves_full_block_and_verifies_all_three(self):
        with LayerDevice() as device, tempfile.TemporaryDirectory() as directory:
            before = bytes(device.blocks[1])
            result, report = self.invoke(device, directory, "Apply")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(report["success"])
            self.assertTrue(report["layers"][1]["enabled"])
            self.assertEqual(len(device.writes), 1)
            self.assertEqual(device.writes[0][18:-2], b"\x01" + before[1:])
            self.assertEqual([struct.unpack_from("<I", r, 12)[0] for r in device.requests[-3:]], [BASE, BASE+48, BASE+96])
            event = json.loads((Path(directory)/"data/eventos.jsonl").read_text().strip())
            self.assertEqual(event["event"], "layers_apply")

    def test_validation_rejects_before_network(self):
        for options in [dict(enable=False), dict(patch={"enabled": 1}), dict(patch={"enabled": True, "x": 50}), dict(model="VX400")]:
            with self.subTest(options=options), LayerDevice() as device, tempfile.TemporaryDirectory() as directory:
                result, report = self.invoke(device, directory, "Apply", **options)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(report["success"])
                self.assertEqual(device.requests, [])

    def test_read_failures_never_write(self):
        for fault in ["wrong_model", "malformed", "unavailable", "observation_gap"]:
            with self.subTest(fault=fault), LayerDevice(fault) as device, tempfile.TemporaryDirectory() as directory:
                result, report = self.invoke(device, directory, "Apply", gap=1.2 if fault == "observation_gap" else None)
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertFalse(report["success"])
                self.assertFalse(report["uncertain"])
                if fault == "observation_gap":
                    self.assertIn("observation gap", report["error"].lower())
                self.assertEqual(device.writes, [])
                self.assertEqual(json.loads((Path(directory)/"data/eventos.jsonl").read_text())["event"], "layers_failed")

    def test_write_failure_has_no_recovery_writes_or_fake_success(self):
        for fault in ["readback_mismatch", "other_layer_sideeffect", "bad_ack", "no_ack"]:
            with self.subTest(fault=fault), LayerDevice(fault) as device, tempfile.TemporaryDirectory() as directory:
                result, report = self.invoke(device, directory, "Apply")
                self.assertEqual(result.returncode, 2)
                self.assertFalse(report["success"])
                self.assertTrue(report["uncertain"])
                self.assertEqual(len(device.writes), 1)
                self.assertEqual(json.loads((Path(directory)/"data/eventos.jsonl").read_text())["event"], "layers_failed")

    def test_mosaic_conflict_blocks_enable(self):
        with LayerDevice() as device, tempfile.TemporaryDirectory() as directory:
            device.blocks[0][0], device.blocks[0][2], device.blocks[0][4] = 1, 6, 224
            result, report = self.invoke(device, directory, "Apply")
            self.assertEqual(result.returncode, 2)
            self.assertIn("MOSAIC", report["error"])
            self.assertEqual(device.writes, [])

    def test_disable_unknown_source_preserves_every_other_byte(self):
        with LayerDevice() as device, tempfile.TemporaryDirectory() as directory:
            device.blocks[1][0], device.blocks[1][2] = 1, 99
            before = bytes(device.blocks[1])
            result, report = self.invoke(device, directory, "Apply", patch={"enabled": False})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(report["layers"][1]["enabled"])
            self.assertEqual(device.writes[0][18:-2], b"\x00"+before[1:])

    def test_disabled_main_mosaic_still_blocks_pip(self):
        with LayerDevice() as device, tempfile.TemporaryDirectory() as directory:
            device.blocks[0][2], device.blocks[0][4] = 6, 224
            result, report = self.invoke(device, directory, "Apply")
            self.assertEqual(result.returncode, 2)
            self.assertIn("MOSAIC", report["error"])
            self.assertEqual(device.writes, [])

    def test_storage_lock_blocks_without_touching_owner_log(self):
        with LayerDevice() as device, tempfile.TemporaryDirectory() as directory:
            data = Path(directory)/"data"
            data.mkdir()
            event = data/"eventos.jsonl"
            event.write_text("owner evidence\n")
            ready = Path(directory)/"ready"
            lock_path = str(data/"watcher.lock").replace("'", "''")
            ready_path = str(ready).replace("'", "''")
            command = f"$s=[IO.File]::Open('{lock_path}',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);[IO.File]::WriteAllText('{ready_path}','ready');[Console]::ReadLine();$s.Dispose()"
            owner = subprocess.Popen([POWERSHELL, "-NoProfile", "-Command", command], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic()+8
                while not ready.exists() and time.monotonic()<deadline:
                    time.sleep(.05)
                self.assertTrue(ready.exists())
                result, report = self.invoke(device, directory)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(report["success"])
                self.assertEqual(device.requests, [])
                self.assertEqual(event.read_text(), "owner evidence\n")
            finally:
                owner.communicate("\n", timeout=5)

    def test_endpoint_mutex_blocks_read_without_touching_owner_log(self):
        with LayerDevice() as device, tempfile.TemporaryDirectory() as directory:
            # Same named mutex algorithm as watcher/manual; process owns until released.
            key = f"127.0.0.1:{device.port}"
            import hashlib
            mutex_name = ("Global\\" if os.name == "nt" else "") + "NovaStarVX400-" + hashlib.sha256(key.encode()).hexdigest().upper()
            ready = Path(directory)/"ready"
            command = "$m=[Threading.Mutex]::new($false,'" + mutex_name + "');$null=$m.WaitOne();[IO.File]::WriteAllText('" + str(ready).replace("'", "''") + "','ready');[Console]::ReadLine();$m.ReleaseMutex();$m.Dispose()"
            owner = subprocess.Popen([POWERSHELL, "-NoProfile", "-Command", command], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic()+8
                while not ready.exists() and time.monotonic()<deadline:
                    time.sleep(.05)
                self.assertTrue(ready.exists())
                result, report = self.invoke(device, directory)
                self.assertEqual(result.returncode, 2)
                self.assertIn("owns", report["error"])
                self.assertEqual(device.requests, [])
                self.assertFalse((Path(directory)/"data/eventos.jsonl").exists())
            finally:
                owner.communicate("\n", timeout=5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
