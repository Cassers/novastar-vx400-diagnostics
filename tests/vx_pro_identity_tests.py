"""Real script/BAT identity exchanges against disposable loopback only."""
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
from runtime_tests import POWERSHELL, ROOT, receive, make_reply

REQUEST = bytes.fromhex('55 aa 00 01 fe 00 00 00 00 00 00 00 02 00 00 00 02 00 58 56')

class IdentityServer:
    def __init__(self, fault=None, port=0):
        self.fault = fault
        self.requests = []
        self.errors = []
        self.socket = socket.socket()
        self.socket.bind(('127.0.0.1', port))
        self.port = self.socket.getsockname()[1]
        self.socket.listen(1)
        self.socket.settimeout(12)
        self.thread = threading.Thread(target=self.run, daemon=True)
    def __enter__(self):
        self.thread.start()
        return self
    def run(self):
        try:
            with self.socket.accept()[0] as peer:
                peer.settimeout(3)
                request = receive(peer, 20)
                self.requests.append(request)
                if request != REQUEST:
                    raise AssertionError('Not the exact hardcoded identity READ')
                reply = bytearray(make_reply(request, struct.pack('<H', 0xBEEF)))
                if self.fault == 'timeout':
                    time.sleep(.7)
                    return
                if self.fault == 'sequence': reply[3] ^= 1
                if self.fault == 'address': reply[12] ^= 1
                if self.fault in ('sequence', 'address'):
                    reply[-2:] = struct.pack('<H', (0x5555 + sum(reply[2:-2])) & 0xFFFF)
                if self.fault == 'checksum': reply[-1] ^= 1
                if self.fault == 'excessive': reply[16:18] = b'\xff\xff'
                if self.fault == 'truncated': reply = reply[:19]
                peer.sendall(reply)
                # No further command, write, discovery or retry on this connection.
                try:
                    if peer.recv(1): raise AssertionError('Unexpected extra request')
                except ConnectionResetError:
                    pass  # Rejected oversized frames can close with unread bytes.
        except Exception as error:
            self.errors.append(str(error))
    def __exit__(self, *args):
        self.thread.join(13)
        self.socket.close()
        if self.thread.is_alive(): raise AssertionError('Simulator did not stop')

@unittest.skipUnless(POWERSHELL, 'PowerShell unavailable')
class IdentityTests(unittest.TestCase):
    def invoke(self, directory, server, code=0, extra=None, script=None):
        path = Path(directory)/'report.json'
        args = [POWERSHELL, '-NoProfile', '-File', str(script or ROOT/'Diagnosticar-VxProIdentidad.ps1'),
                '-DeviceAddress', '127.0.0.1', '-TcpPort', str(server.port),
                '-TimeoutMs', '250', '-OutputPath', str(path)]
        result = subprocess.run(args + (extra or []), capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        record = json.loads(result.stdout)
        self.assertEqual(record, json.loads(path.read_text(encoding='utf-8-sig')))
        self.assertTrue(record['readOnly'])
        self.assertFalse(record['identityMappingVerified'])
        self.assertFalse(record['controlEnabled'])
        self.assertFalse(record['firmwareQueried'])
        self.assertEqual(bytes.fromhex(record['requestHex']), REQUEST)
        return record
    def assert_server(self, server):
        self.assertEqual(server.requests, [REQUEST])
        self.assertFalse(server.errors, server.errors)
    def test_unknown_id_is_observed_without_enabling_control(self):
        with IdentityServer() as server, tempfile.TemporaryDirectory() as directory:
            record = self.invoke(directory, server)
            self.assertTrue(record['success'])
            self.assertEqual(record['status'], 'protocol_valid_identity_unmapped')
            self.assertEqual(record['modelIdRaw'], 0xBEEF)
            self.assertEqual(record['modelIdHex'], '0xBEEF')
            self.assertTrue(record['checksumValid'] and record['correlationValid'])
        self.assert_server(server)
    def test_malformed_and_timeout_never_become_verified(self):
        for fault in ('checksum', 'sequence', 'address', 'excessive', 'truncated', 'timeout'):
            with self.subTest(fault=fault), IdentityServer(fault) as server, tempfile.TemporaryDirectory() as directory:
                record = self.invoke(directory, server, code=2)
                self.assertFalse(record['success'])
                self.assertIsNone(record['modelIdRaw'])
                self.assertTrue(record['error'])
            self.assert_server(server)
    def test_invalid_ipv4_and_existing_output_are_safe(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'plan.config.json'
            path.write_text('{"keep":true}')
            result = subprocess.run([POWERSHELL, '-NoProfile', '-File', str(ROOT/'Diagnosticar-VxProIdentidad.ps1'),
                                     '-DeviceAddress', '127.0.0.1;bad', '-OutputPath', str(path)],
                                    capture_output=True, text=True, timeout=12)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(path.read_text(), '{"keep":true}')
            self.assertFalse(json.loads(result.stdout)['success'])

    @unittest.skipUnless(os.name == 'nt', 'Native BAT and NTFS MOTW require Windows')
    def test_native_bat_marked_download_prompt_and_scope(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)/"diagnostic & O'Brien %USERNAME%"
            directory.mkdir()
            for name in ('Diagnosticar-VxProIdentidad.bat', 'Diagnosticar-VxProIdentidad.ps1', 'Vx400.Protocol.psm1'):
                shutil.copyfile(ROOT/name, directory/name)
            (directory/'unrelated.ps1').write_text('throw "must not execute"')
            env = dict(os.environ, VXPRO_FIXTURE=str(directory), VXPRO_TEST_BAT=str(directory/'Diagnosticar-VxProIdentidad.bat'))
            mark = "$ErrorActionPreference='Stop'; foreach($name in @('Diagnosticar-VxProIdentidad.ps1','Vx400.Protocol.psm1','unrelated.ps1')){Set-Content -LiteralPath (Join-Path $env:VXPRO_FIXTURE $name) -Stream Zone.Identifier -Value \"[ZoneTransfer]`r`nZoneId=3`r`n\" -Encoding ASCII}"
            subprocess.run([POWERSHELL, '-NoProfile', '-Command', mark], env=env, check=True, capture_output=True, timeout=15)
            negative = directory/'must-not-run.json'
            blocked = subprocess.run([POWERSHELL, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'RemoteSigned', '-File', str(directory/'Diagnosticar-VxProIdentidad.ps1'), '-DeviceAddress', 'invalid', '-OutputPath', str(negative)], capture_output=True, text=True, timeout=15)
            self.assertNotEqual(blocked.returncode, 0)
            self.assertFalse(negative.exists(), 'Negative MOTW control must refuse execution')
            # No BAT arguments: actual double-click path prompts for IPv4, default TCP15200.
            with IdentityServer(port=15200) as server:
                result = subprocess.run([os.environ['COMSPEC'], '/D', '/V:ON', '/S', '/C', '""%VXPRO_TEST_BAT%""'],
                                        input='127.0.0.1\n\n', capture_output=True, text=True, env=env, timeout=20)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                start = result.stdout.index('{'); end = result.stdout.rindex('}')+1
                record = json.loads(result.stdout[start:end])
                self.assertEqual(record['modelIdRaw'], 0xBEEF)
                self.assertFalse(record['controlEnabled'])
                self.assertEqual(record['tcpPort'], 15200)
                report = Path(record['reportPath'])
                self.assertTrue(report.is_file())
                report.unlink()
            self.assert_server(server)
            check = "$ErrorActionPreference='Stop'; foreach($name in @('Diagnosticar-VxProIdentidad.ps1','Vx400.Protocol.psm1')){if(Get-Item -LiteralPath (Join-Path $env:VXPRO_FIXTURE $name) -Stream Zone.Identifier -ErrorAction SilentlyContinue){throw 'Bundled code still marked'}}; $null=Get-Item -LiteralPath (Join-Path $env:VXPRO_FIXTURE 'unrelated.ps1') -Stream Zone.Identifier -ErrorAction Stop"
            subprocess.run([POWERSHELL, '-NoProfile', '-Command', check], env=env, check=True, capture_output=True, timeout=15)

if __name__ == '__main__':
    unittest.main(verbosity=2)
