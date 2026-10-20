"""Integration tests: synthetic profiles on 127.0.0.1 ONLY, no hardware."""
import json
import shutil
from pathlib import Path
import struct
import subprocess
import tempfile
import time
import unittest

from runtime_tests import FakeDevice, POWERSHELL, ROOT, make_reply, receive


class WatcherDevice(FakeDevice):
    def __init__(self, fault=None):
        super().__init__(fault)
        self.poll = 0
        self.writes_with_time = []
        self.on_write = None

    def run(self):
        import socket
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
                    count = struct.unpack_from('<H', request, 16)[0] if is_write else 0
                    request += receive(connection, count + 2)
                    self.requests.append(request)
                    address = struct.unpack_from('<I', request, 12)[0]
                    if not is_write:
                        self.poll += 1
                        if self.fault == 'outage' and 4 <= self.poll <= 6:
                            continue
                        if self.fault == 'one_missed_read' and self.poll == 4:
                            continue
                        payload = b'\x11\x62' if self.fault != 'wrong_model' else b'\x12\x62'
                    else:
                        self.writes_with_time.append((time.monotonic(), address, request[18:-2]))
                        if self.on_write:
                            self.on_write(address, request[18:-2])
                        if self.fault == 'stage_ack_lost' and address == 0x02000001 and request[18] == 25:
                            continue
                        payload = b''
                    reply = make_reply(request, payload)
                    for offset in range(0, len(reply), 3):
                        connection.sendall(reply[offset:offset+3])
                except (BrokenPipeError, ConnectionResetError):
                    pass
                except Exception as error:
                    self.errors.append(repr(error))


def profile(port):
    config = json.loads((ROOT / 'watcher.config.json').read_text(encoding='utf-8-sig'))
    config.update(deviceAddress='127.0.0.1', tcpPort=port, pollIntervalSeconds=0.5,
                  timeoutMs=250, maximumObservationGapSeconds=5)
    # Deliberately synthetic. NEVER a recommendation for LED panels.
    config['sequence'].update(approved=True, curveReference='SIMULATOR ONLY: synthetic protocol test',
                             panelPowerCouplingVerified=True, startupProtectionVerified=True,
                             normalBrightnessPercent=30,
                             stages=[dict(brightnessPercent=5, durationSeconds=1),
                                     dict(brightnessPercent=10, durationSeconds=1)])
    return config


@unittest.skipUnless(POWERSHELL, 'PowerShell runtime required')
class WatcherTests(unittest.TestCase):
    def run_watcher(self, config, directory, arguments=(), polls=12, script=None):
        folder = Path(directory)
        path = folder / 'config.json'
        path.write_text(json.dumps(config), encoding='utf-8')
        result = subprocess.run([POWERSHELL, '-NoLogo', '-NoProfile', '-File', str(script or ROOT / 'Watch-Vx400.ps1'),
                                 '-ConfigPath', str(path), '-DataDirectory', str(folder / 'data'),
                                 '-MaxPolls', str(polls), *arguments], capture_output=True, text=True, timeout=35)
        log_path = folder / 'data/eventos.jsonl'
        events = [json.loads(line) for line in log_path.read_text(encoding='utf-8-sig').splitlines()] if log_path.exists() else []
        return result, events

    def test_default_monitor_only_reads_and_logs_recovery(self):
        with WatcherDevice('outage') as device, tempfile.TemporaryDirectory() as directory:
            result, events = self.run_watcher(profile(device.port), directory)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertTrue(all(request[10] == 0 for request in device.requests))
            names = [event['event'] for event in events]
            self.assertEqual(names.count('conexion_inicial'), 1)
            self.assertEqual(names.count('sin_comunicacion'), 1)
            self.assertEqual(names.count('comunicacion_recuperada'), 1)
            self.assertFalse(device.errors, device.errors)

    def test_sequence_order_minimum_durations_and_single_cycle(self):
        with WatcherDevice() as device, tempfile.TemporaryDirectory() as directory:
            result, events = self.run_watcher(profile(device.port), directory, ['-EnableSequence'])
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            writes = device.writes_with_time
            self.assertEqual([entry[2] for entry in writes], [b'\x05\x00', b'\x0c', b'\x06\x04', b'\x19',
                b'\x05\x00', b'\x4c', b'\x03\x00', b'\x05\x00', b'\x00'])
            self.assertGreaterEqual(writes[3][0] - writes[2][0], 0.99)
            self.assertGreaterEqual(writes[4][0] - writes[3][0], 0.99)
            self.assertEqual(sum(e['event'] == 'ciclo_completado' for e in events), 1)

    def test_single_missed_poll_restarts_at_first_stage(self):
        with WatcherDevice('one_missed_read') as device, tempfile.TemporaryDirectory() as directory:
            result, events = self.run_watcher(profile(device.port), directory, ['-EnableSequence'], polls=15)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(sum(e['event'] == 'inicio_ciclo' for e in events), 2)
            writes = [entry[2] for entry in device.writes_with_time]
            self.assertEqual(writes.count(b'\x0c'), 2)
            self.assertEqual(writes.count(b'\x03\x00'), 1)
            self.assertNotIn('sin_comunicacion', [e['event'] for e in events])

    def test_lost_ack_latches_fault_never_normal_or_repeat(self):
        with WatcherDevice('stage_ack_lost') as device, tempfile.TemporaryDirectory() as directory:
            result, events = self.run_watcher(profile(device.port), directory, ['-EnableSequence'])
            self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
            writes = [entry[2] for entry in device.writes_with_time]
            self.assertNotIn(b'\x03\x00', writes)
            self.assertEqual(writes.count(b'\x0c'), 1)
            self.assertIn('fallo_secuencia', [e['event'] for e in events])
            self.assertEqual(writes[-2:], [b'\x05\x00', b'\x00'])

    def test_wrong_model_never_writes(self):
        with WatcherDevice('wrong_model') as device, tempfile.TemporaryDirectory() as directory:
            result, events = self.run_watcher(profile(device.port), directory, ['-EnableSequence'], polls=4)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertTrue(device.requests)
            self.assertTrue(all(r[10] == 0 for r in device.requests))
            self.assertNotIn('inicio_ciclo', [e['event'] for e in events])

    def test_shipped_profile_blocks_writes_before_network(self):
        with WatcherDevice() as device, tempfile.TemporaryDirectory() as directory:
            config = profile(device.port)
            config['sequence']['approved'] = False
            result, events = self.run_watcher(config, directory, ['-EnableSequence'])
            self.assertEqual(result.returncode, 2)
            self.assertEqual(device.requests, [])
            self.assertEqual(events, [])

    def test_nonmonotonic_curve_rejected(self):
        with WatcherDevice() as device, tempfile.TemporaryDirectory() as directory:
            config = profile(device.port)
            config['sequence']['stages'][1]['brightnessPercent'] = 1
            result, _ = self.run_watcher(config, directory, ['-EnableSequence'])
            self.assertEqual(result.returncode, 2)
            self.assertEqual(device.requests, [])

    def test_missing_protection_rejected(self):
        with WatcherDevice() as device, tempfile.TemporaryDirectory() as directory:
            config = profile(device.port)
            config['sequence']['startupProtectionVerified'] = False
            result, _ = self.run_watcher(config, directory, ['-EnableSequence'])
            self.assertEqual(result.returncode, 2)
            self.assertEqual(device.requests, [])

    def test_disk_error_does_not_prevent_dark_attempts(self):
        with WatcherDevice() as device, tempfile.TemporaryDirectory() as directory:
            def block_state_save(address, data):
                if address == 0x13000004 and data == b'\x06\x04':
                    (Path(directory) / 'data/estado.json.tmp').mkdir(exist_ok=True)
            device.on_write = block_state_save
            result, _ = self.run_watcher(profile(device.port), directory, ['-EnableSequence'])
            self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
            writes = [entry[2] for entry in device.writes_with_time]
            self.assertNotIn(b'\x03\x00', writes)
            self.assertEqual(writes[-2:], [b'\x05\x00', b'\x00'])

    def test_endpoint_mutex_blocks_second_process_even_other_log_folder(self):
        with WatcherDevice() as device, tempfile.TemporaryDirectory() as directory:
            config = profile(device.port)
            path = Path(directory) / 'first.json'
            path.write_text(json.dumps(config), encoding='utf-8')
            first = subprocess.Popen([POWERSHELL, '-NoLogo', '-NoProfile', '-File', str(ROOT / 'Watch-Vx400.ps1'),
                '-ConfigPath', str(path), '-DataDirectory', str(Path(directory) / 'first')],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 10
                while not device.requests and time.monotonic() < deadline and first.poll() is None:
                    time.sleep(0.05)
                self.assertIsNone(first.poll(), 'first process unexpectedly exited')
                self.assertTrue(device.requests, 'first process never polled')
                config['deviceAddress'] = '127.1'  # Same IPv4 endpoint, legacy spelling.
                result, _ = self.run_watcher(config, directory, polls=2)
                self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
                self.assertIn('Another watcher owns this endpoint', result.stderr)
                self.assertFalse((Path(directory) / 'data').exists(), 'loser must not create its own state or logs')
                # Also reject an identical log directory without corrupting its owner's files.
                deadline = time.monotonic() + 5
                while device.poll < 3 and time.monotonic() < deadline:
                    time.sleep(0.05)
                audit_files = [Path(directory) / 'first' / name for name in ['estado.json', 'eventos.jsonl']]
                before = [f.read_bytes() for f in audit_files]
                loser = subprocess.run([POWERSHELL, '-NoProfile', '-File', str(ROOT / 'Watch-Vx400.ps1'),
                    '-ConfigPath', str(path), '-DataDirectory', str(Path(directory) / 'first'), '-MaxPolls', '2'],
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(loser.returncode, 2, loser.stderr)
                self.assertEqual(before, [f.read_bytes() for f in audit_files])
            finally:
                first.terminate()
                first.wait(timeout=5)

    def test_pause_after_read_cannot_advance_brightness(self):
        with WatcherDevice() as device, tempfile.TemporaryDirectory() as directory:
            # Inject an OS/process scheduling pause between read and transition in a
            # disposable copy. Production exposes no arbitrary-code test hook.
            copy = Path(directory) / 'program'
            copy.mkdir()
            for name in ['Watch-Vx400.ps1', 'Vx400.Automation.psm1', 'Vx400.Protocol.psm1']:
                shutil.copyfile(ROOT / name, copy / name)
            script = copy / 'Watch-Vx400.ps1'
            source = script.read_text(encoding='utf-8-sig')
            anchor = '            if ($connected -and $EnableSequence -and -not $faultLatched) {'
            self.assertEqual(source.count(anchor), 1)
            script.write_text(source.replace(anchor, '            if ($polls -eq 4) { Start-Sleep -Seconds 6 }\n' + anchor), encoding='utf-8-sig')
            result, events = self.run_watcher(profile(device.port), directory, ['-EnableSequence'], polls=6, script=script)
            self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
            writes = [entry[2] for entry in device.writes_with_time]
            self.assertNotIn(b'\x19', writes, 'must not raise to second stage after stale observation')
            self.assertNotIn(b'\x03\x00', writes)
            self.assertIn('fallo_secuencia', [e['event'] for e in events])

    def test_observation_gap_preserves_latched_fault(self):
        with WatcherDevice('stage_ack_lost') as device, tempfile.TemporaryDirectory() as directory:
            copy = Path(directory) / 'program'
            copy.mkdir()
            for name in ['Watch-Vx400.ps1', 'Vx400.Automation.psm1', 'Vx400.Protocol.psm1']:
                shutil.copyfile(ROOT / name, copy / name)
            script = copy / 'Watch-Vx400.ps1'
            source = script.read_text(encoding='utf-8-sig')
            anchor = '        $polls++'
            self.assertEqual(source.count(anchor), 1)
            script.write_text(source.replace(anchor, anchor+'\n        if ($polls -eq 5) { Start-Sleep -Seconds 6 }'), encoding='utf-8-sig')
            result, events = self.run_watcher(profile(device.port), directory, ['-EnableSequence'], polls=7, script=script)
            self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
            state = json.loads((Path(directory) / 'data/estado.json').read_text(encoding='utf-8-sig'))
            self.assertEqual(state['state'], 'fallo')
            gaps = [e for e in events if e['event'] == 'observacion_interrumpida']
            self.assertEqual(len(gaps), 1)
            self.assertEqual(gaps[0]['state'], 'fallo')


if __name__ == '__main__':
    unittest.main(verbosity=2)
