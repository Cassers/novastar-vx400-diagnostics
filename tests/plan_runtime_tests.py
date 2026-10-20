"""Synthetic-second plans against loopback simulator. Not thermal recommendations."""
import json
import os
import signal
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest
import uuid
from datetime import datetime, timedelta, timezone

from runtime_tests import FakeDevice, POWERSHELL, ROOT, make_reply, receive


def stamp(value=None):
    return (value or datetime.now(timezone.utc)).isoformat().replace('+00:00', 'Z')


def atomic_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value), encoding='utf-8')
    temporary.replace(path)


class PlanDevice(FakeDevice):
    def __init__(self, drop_read_at=None, drop_brightness=False, offline_writes=False):
        super().__init__()
        self.offline_writes = offline_writes
        self.read_count = 0
        self.drop_read_at = set(drop_read_at or [])
        self.drop_brightness = drop_brightness
        self.failed_at = None
        self.trace = []

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
                    count = struct.unpack_from('<H', request, 16)[0] if request[10] == 1 else 0
                    request += receive(connection, count + 2)
                    self.requests.append(request)
                    self.trace.append((time.monotonic(), request))
                    assert struct.unpack_from('<H', request, len(request)-2)[0] == ((0x5555+sum(request[2:-2])) & 0xffff)
                    address = struct.unpack_from('<I', request, 12)[0]
                    if request[10] == 0:
                        self.read_count += 1
                        if self.read_count in self.drop_read_at:
                            self.failed_at = len(self.requests)-1
                            continue
                    elif self.offline_writes and self.read_count in self.drop_read_at:
                        continue
                    elif self.drop_brightness and address == 0x02000001:
                        self.drop_brightness = False
                        self.failed_at = len(self.requests)-1
                        continue
                    payload = b'' if request[10] == 1 else b'\x11\x62'
                    reply = make_reply(request, payload)
                    connection.sendall(reply[:5])
                    connection.sendall(reply[5:])
                except (BrokenPipeError, ConnectionResetError):
                    pass
                except Exception as error:
                    self.errors.append(repr(error))


def writes(device):
    return [r for r in device.requests if r[10] == 1]


def brightness(request):
    return request[18] if struct.unpack_from('<I', request, 12)[0] == 0x02000001 else None


@unittest.skipUnless(POWERSHELL, 'PowerShell unavailable')
class PlanRuntimeTests(unittest.TestCase):
    def config(self, directory, device, slow=False):
        config = json.loads((ROOT/'plan.config.json').read_text(encoding='utf-8-sig'))
        config.update(deviceAddress='127.0.0.1', tcpPort=device.port, pollIntervalSeconds=.1, timeoutMs=250,
                      onlineSuccesses=1, offlineFailures=2, maximumObservationGapSeconds=2,
                      panelPowerCouplingVerified=True, startupProtectionVerified=True,
                      dailyStarts=[], operatingWindows=[])
        for name, phases in config['profiles'].items():
            for phase in phases:
                phase['minutes'] = .02 if slow else .003
        config_path = Path(directory)/'config.json'
        atomic_json(config_path, config)
        return config_path, config

    def launch(self, directory, config_path, control=True, polls=40):
        args = [POWERSHELL, '-NoLogo', '-NoProfile', '-File', str(ROOT/'Watch-Vx400Plan.ps1'),
                '-ConfigPath', str(config_path), '-DataDirectory', str(directory), '-MaxPolls', str(polls)]
        if control:
            args.append('-EnableControl')
        return subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def finish(self, process, timeout=15, code=0):
        out, err = process.communicate(timeout=timeout)
        self.assertEqual(process.returncode, code, out+'\n'+err)
        return out, err

    def state(self, directory):
        try:
            return json.loads((Path(directory)/'estado.json').read_text(encoding='utf-8-sig'))
        except (OSError, ValueError):
            return {}

    def wait_state(self, process, directory, predicate, timeout=10):
        end = time.monotonic()+timeout
        while time.monotonic() < end:
            state = self.state(directory)
            if predicate(state):
                return state
            if process.poll() is not None:
                out, err = process.communicate()
                self.fail(f'Process exited {process.returncode}: {out}\n{err}; state={state}')
            time.sleep(.025)
        self.fail(f'Timed out: {self.state(directory)}')

    def stop(self, directory):
        (Path(directory)/'stop.request').touch()

    def events(self, directory):
        return [json.loads(line) for line in (Path(directory)/'eventos.jsonl').read_text(encoding='utf-8-sig').splitlines()]

    def command(self, directory, gate, action):
        command = dict(id=str(uuid.uuid4()), gateId=gate, action=action, utc=stamp())
        atomic_json(Path(directory)/'operador.json', command)
        return command

    def test_readonly_default_recovers_without_writes(self):
        with PlanDevice(drop_read_at=[3]) as device, tempfile.TemporaryDirectory() as directory:
            path, _ = self.config(directory, device)
            p = self.launch(directory, path, control=False, polls=8)
            self.finish(p)
            self.assertFalse(writes(device))
            self.assertIn('reconnected', [e['event'] for e in self.events(directory)])
            self.assertFalse(self.state(directory)['operatorPending'])
            self.assertFalse(device.errors)

    def test_control_outside_calendar_stays_black(self):
        with PlanDevice() as device, tempfile.TemporaryDirectory() as directory:
            path, _ = self.config(directory, device)
            self.finish(self.launch(directory, path, polls=10))
            self.assertEqual(sum(e['event'] == 'profile_started' for e in self.events(directory)), 0)
            values = [r[18:-2] for r in writes(device)]
            self.assertEqual(values[:2], [b'\x05\x00', b'\x19'])
            self.assertNotIn(b'\x06\x04', values)
            self.assertNotIn(b'\x03\x00', values)
            self.assertEqual(values[-2:], [b'\x05\x00', b'\x00'])
            self.assertFalse(device.errors)

    def test_lost_brightness_ack_never_enables_normal_or_white(self):
        with PlanDevice(drop_brightness=True) as device, tempfile.TemporaryDirectory() as directory:
            path, _ = self.config(directory, device)
            self.finish(self.launch(directory, path, polls=8), code=2)
            values = [r[18:-2] for r in writes(device)]
            self.assertNotIn(b'\x03\x00', values)
            self.assertNotIn(b'\x06\x04', values)
            self.assertEqual(sum(e['event'] == 'control_fault' for e in self.events(directory)), 1)
            self.assertTrue(self.state(directory)['operatorPending'])
            gate = self.state(directory)['operatorGateId']
            self.finish(self.launch(directory, path, polls=4))
            self.assertTrue(self.state(directory)['operatorPending'])
            self.assertEqual(self.state(directory)['operatorGateId'], gate)

    def test_recovery_requires_fresh_gate_hold_then_restart_full_preheat(self):
        with PlanDevice(drop_read_at=[3]) as device, tempfile.TemporaryDirectory() as directory:
            path, _ = self.config(directory, device, slow=True)
            p = self.launch(directory, path, polls=150)
            try:
                state = self.wait_state(p, directory, lambda s: s.get('operatorPending') and s.get('communication') == 'reachable')
                gate = state['operatorGateId']
                count = len(writes(device))
                first_hold = self.command(directory, gate, 'hold')
                self.wait_state(p, directory, lambda s: s.get('operatorLastCommandId') == first_hold['id'])
                second_hold = self.command(directory, gate, 'hold')
                self.wait_state(p, directory, lambda s: s.get('operatorLastCommandId') == second_hold['id'])
                atomic_json(Path(directory)/'operador.json', first_hold)
                time.sleep(.2)
                self.assertEqual(self.state(directory)['operatorLastCommandId'], second_hold['id'])
                time.sleep(.3)
                self.assertTrue(self.state(directory)['operatorPending'])
                self.assertEqual(len(writes(device)), count)
                self.command(directory, gate, 'restart')
                self.wait_state(p, directory, lambda s: s.get('state') == 'PREHEAT')
                self.wait_state(p, directory, lambda s: s.get('state') == 'BLACK', timeout=10)
                self.assertFalse(self.state(directory)['operatorPending'])
                starts = [e['detail'] for e in self.events(directory) if e['event'] == 'profile_started']
                self.assertEqual(sum(s.startswith('PREHEAT') for s in starts), 1)
                self.assertNotIn('operating', [e['event'] for e in self.events(directory)])
                self.stop(directory)
                self.finish(p)
            finally:
                if p.poll() is None:
                    p.kill();p.communicate()

    def test_pending_survives_restart_stale_command_cannot_approve_new_loss(self):
        with PlanDevice(drop_read_at=[3]) as device, tempfile.TemporaryDirectory() as directory:
            path, _ = self.config(directory, device, slow=True)
            p = self.launch(directory, path, polls=200)
            try:
                state = self.wait_state(p, directory, lambda s: s.get('operatorPending') and s.get('communication') == 'reachable')
                first_gate = state['operatorGateId']
                p.kill();p.communicate(timeout=5)
                p = self.launch(directory, path, polls=200)
                state = self.wait_state(p, directory, lambda s: s.get('operatorPending') and s.get('communication') == 'reachable')
                self.assertEqual(state['operatorGateId'], first_gate)
                device.drop_read_at.add(device.read_count+2)
                state = self.wait_state(p, directory, lambda s: s.get('operatorGateId') not in (None, first_gate) and s.get('communication') == 'reachable')
                second_gate = state['operatorGateId']
                self.command(directory, first_gate, 'restart')
                time.sleep(.4)
                state = self.state(directory)
                self.assertTrue(state['operatorPending'])
                self.assertEqual(state['operatorGateId'], second_gate)
                self.assertEqual(state['state'], 'WAIT_OPERATOR')
                self.stop(directory);self.finish(p)
            finally:
                if p.poll() is None:
                    p.kill();p.communicate()

    def test_cancelled_preheat_cools_from_actual_level_without_upward_jump(self):
        with PlanDevice() as device, tempfile.TemporaryDirectory() as directory:
            path, config = self.config(directory, device, slow=True)
            now = datetime.now(timezone.utc)
            item = dict(id=str(uuid.uuid4()), title='Synthetic test', startUtc=stamp(now+timedelta(seconds=3)), endUtc=stamp(now+timedelta(seconds=30)), cancelled=False)
            atomic_json(Path(directory)/'solicitudes.json', dict(schemaVersion=1, items=[item]))
            p = self.launch(directory, path, polls=100)
            try:
                self.wait_state(p, directory, lambda s: s.get('state') == 'PREHEAT' and (s.get('brightnessRequested') or 0) > 12)
                item['cancelled'] = True
                marker = len(device.requests)
                atomic_json(Path(directory)/'solicitudes.json', dict(schemaVersion=1, items=[item]))
                self.wait_state(p, directory, lambda s: s.get('state') == 'COOLDOWN')
                self.wait_state(p, directory, lambda s: s.get('state') == 'BLACK', timeout=6)
                values = [brightness(r) for r in device.requests[marker:] if r[10] == 1 and brightness(r) is not None]
                # BLACK finally requests 10% behind blackout; cooldown itself never increases.
                for previous, current in zip(values, values[1:]):
                    self.assertLessEqual(current, previous)
                self.stop(directory);self.finish(p)
            finally:
                if p.poll() is None:
                    p.kill();p.communicate()

    def test_invalid_live_requests_halt_and_dark(self):
        with PlanDevice() as device, tempfile.TemporaryDirectory() as directory:
            path, _ = self.config(directory, device, slow=True)
            p = self.launch(directory, path, polls=100)
            try:
                self.wait_state(p, directory, lambda s: s.get('state') == 'BLACK')
                atomic_json(Path(directory)/'solicitudes.json', dict(schemaVersion=1, items='invalid'))
                self.finish(p, code=2)
                self.assertEqual([r[18:-2] for r in writes(device)][-2:], [b'\x05\x00', b'\x00'])
            finally:
                if p.poll() is None:
                    p.kill();p.communicate()

    def test_poweroff_dark_failures_keep_operator_gate_usable(self):
        with PlanDevice(drop_read_at=[3, 4, 5], offline_writes=True) as device, tempfile.TemporaryDirectory() as directory:
            path, _ = self.config(directory, device, slow=True)
            p = self.launch(directory, path, polls=100)
            try:
                state = self.wait_state(p, directory, lambda s: s.get('operatorPending') and s.get('communication') == 'reachable')
                self.assertEqual(state['state'], 'WAIT_OPERATOR')
                self.command(directory, state['operatorGateId'], 'restart')
                self.wait_state(p, directory, lambda s: s.get('state') == 'PREHEAT')
                self.stop(directory);self.finish(p)
            finally:
                if p.poll() is None:
                    p.kill();p.communicate()

    def test_full_preheat_then_operation_then_end_cooldown(self):
        with PlanDevice() as device, tempfile.TemporaryDirectory() as directory:
            path, config = self.config(directory, device)
            now = datetime.now(timezone.utc)
            item = dict(id=str(uuid.uuid4()), title='Synthetic end', startUtc=stamp(now+timedelta(seconds=.4)), endUtc=stamp(now+timedelta(seconds=3)), cancelled=False)
            atomic_json(Path(directory)/'solicitudes.json', dict(schemaVersion=1, items=[item]))
            p = self.launch(directory, path, polls=100)
            try:
                self.wait_state(p, directory, lambda s: s.get('state') == 'OPERATING')
                self.wait_state(p, directory, lambda s: s.get('state') == 'COOLDOWN')
                self.wait_state(p, directory, lambda s: s.get('state') == 'BLACK')
                events = self.events(directory)
                started = next(e for e in events if e['event'] == 'profile_started' and e['detail'].startswith('PREHEAT'))
                operating = next(e for e in events if e['event'] == 'operating')
                elapsed = (datetime.fromisoformat(operating['utc'])-datetime.fromisoformat(started['utc'])).total_seconds()
                self.assertGreaterEqual(elapsed, .72)
                self.stop(directory);self.finish(p)
                self.assertFalse((Path(directory)/'stop.request').exists())
                self.finish(self.launch(directory, path, control=False, polls=2))
                self.assertFalse(self.state(directory)['operatorPending'])
            finally:
                if p.poll() is None:
                    p.kill();p.communicate()

    def test_due_daily_dry_starts_from_zero_even_when_slot_is_late(self):
        with PlanDevice() as device, tempfile.TemporaryDirectory() as directory:
            path, config = self.config(directory, device)
            local = datetime.now(timezone.utc)-timedelta(hours=5)
            config['dailyStarts'] = [local.strftime('%H:%M')]
            for phase in config['profiles']['dry']:
                phase['minutes'] = 1
            atomic_json(path, config)
            self.finish(self.launch(directory, path, polls=4))
            started = [e for e in self.events(directory) if e['event'] == 'profile_started']
            self.assertEqual(len(started), 1)
            self.assertTrue(started[0]['detail'].startswith('DRY'))
            self.assertEqual([r[18:-2] for r in writes(device)][:3], [b'\x05\x00', b'\x19', b'\x06\x04'])

    @unittest.skipIf(os.name == 'nt', 'SIGSTOP/SIGCONT fixture only on Unix; Windows suspension checked manually')
    def test_observation_gap_persists_operator_question(self):
        with PlanDevice() as device, tempfile.TemporaryDirectory() as directory:
            path, _ = self.config(directory, device)
            p = self.launch(directory, path, polls=100)
            try:
                self.wait_state(p, directory, lambda s: s.get('state') == 'BLACK')
                os.kill(p.pid, signal.SIGSTOP)
                time.sleep(2.2)
                os.kill(p.pid, signal.SIGCONT)
                state = self.wait_state(p, directory, lambda s: s.get('operatorPending') and s.get('state') == 'WAIT_OPERATOR')
                self.assertTrue(state['operatorGateId'])
                self.assertNotIn('profile_started', [e['event'] for e in self.events(directory)])
                self.stop(directory);self.finish(p)
            finally:
                if p.poll() is None:
                    os.kill(p.pid, signal.SIGCONT)
                    p.kill();p.communicate()

    def test_validateonly_no_storage_no_network(self):
        with PlanDevice() as device, tempfile.TemporaryDirectory() as directory:
            path, _ = self.config(directory, device)
            data = Path(directory)/'uncreated'
            result = subprocess.run([POWERSHELL, '-NoLogo', '-NoProfile', '-File', str(ROOT/'Watch-Vx400Plan.ps1'),
                                     '-ConfigPath', str(path), '-DataDirectory', str(data), '-ValidateOnly'], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(data.exists())
            self.assertFalse(device.requests)


if __name__ == '__main__':
    unittest.main(verbosity=2)
