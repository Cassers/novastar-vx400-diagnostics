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
    def __init__(self, drop_read_at=None, drop_brightness=False, offline_writes=False, read_gate=None):
        super().__init__()
        self.offline_writes = offline_writes
        self.read_gate = read_gate
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
                    if self.read_gate is not None and request[10] == 0:
                        self.read_gate.wait(6)
                        self.read_gate = None
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

    def launch(self, directory, config_path, control=True, polls=40, manual=False):
        args = [POWERSHELL, '-NoLogo', '-NoProfile', '-File', str(ROOT/'Watch-Vx400Plan.ps1'),
                '-ConfigPath', str(config_path), '-DataDirectory', str(directory), '-MaxPolls', str(polls)]
        if control:
            args.append('-EnableControl')
        if manual:
            args.append('-ManualDry')
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

    def manual_command(self, directory, path, display='White', value=10, enabled=True):
        args=[POWERSHELL, '-NoLogo', '-NoProfile', '-File', str(ROOT/'Set-Vx400Manual.ps1'),
              '-ConfigPath', str(path), '-DataDirectory', str(directory), '-BrightnessPercent', str(value), '-Display', display]
        if enabled: args.append('-EnableControl')
        return subprocess.run(args, capture_output=True, text=True, timeout=12)

    def test_manual_panel_acknowledges_low_brightness_before_white_and_normal(self):
        with PlanDevice() as device, tempfile.TemporaryDirectory() as directory:
            path, _ = self.config(directory, device)
            for display, command in [('White', b'\x06\x04'), ('Normal', b'\x03\x00')]:
                marker=len(device.requests)
                result=self.manual_command(directory, path, display=display, value=12)
                self.assertEqual(result.returncode,0,result.stderr)
                payload=json.loads(result.stdout)
                self.assertTrue(payload['success']); self.assertFalse(payload['measured'])
                self.assertEqual([r[18:-2] for r in device.requests[marker:] if r[10]==1], [b'\x05\x00',bytes([30]),command])

    def test_manual_panel_lost_brightness_ack_never_enables_pattern(self):
        with PlanDevice(drop_brightness=True) as device, tempfile.TemporaryDirectory() as directory:
            path, _ = self.config(directory, device)
            result=self.manual_command(directory,path)
            self.assertEqual(result.returncode,2)
            values=[r[18:-2] for r in writes(device)]
            self.assertNotIn(b'\x06\x04',values);self.assertNotIn(b'\x03\x00',values)
            self.assertEqual(values[-2:],[b'\x05\x00',b'\x00'])

    def test_manual_panel_cannot_override_running_dry_or_readonly_controller(self):
        with PlanDevice() as device, tempfile.TemporaryDirectory() as directory:
            path, _ = self.config(directory, device)
            p=self.launch(directory,path,control=False,polls=100)
            try:
                self.wait_state(p,directory,lambda s:s.get('communication')=='reachable')
                result=self.manual_command(directory,path)
                self.assertEqual(result.returncode,2)
                self.assertIn('Another controller',result.stderr)
                self.assertFalse(writes(device))
                self.stop(directory);self.finish(p)
            finally:
                if p.poll() is None:p.kill();p.communicate()

    def test_manual_panel_bad_identity_reply_blocks_writes(self):
        with FakeDevice(fault='identity_checksum') as device, tempfile.TemporaryDirectory() as directory:
            path,_=self.config(directory,device)
            result=self.manual_command(directory,path)
            self.assertEqual(result.returncode,2);self.assertFalse(writes(device))

    @unittest.skipIf(os.name == 'nt', 'Unix suspend fixture for manual one-shot')
    def test_manual_panel_suspended_identity_reply_is_not_trusted(self):
        gate=threading.Event()
        with PlanDevice(read_gate=gate) as device,tempfile.TemporaryDirectory() as directory:
            path,_=self.config(directory,device)
            p=subprocess.Popen([POWERSHELL,'-NoProfile','-File',str(ROOT/'Set-Vx400Manual.ps1'),
                '-ConfigPath',str(path),'-DataDirectory',directory,'-BrightnessPercent','10','-Display','White','-EnableControl'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                deadline=time.monotonic()+5
                while not device.requests and time.monotonic()<deadline:time.sleep(.005)
                self.assertTrue(device.requests)
                os.kill(p.pid,signal.SIGSTOP);gate.set();time.sleep(2.2);os.kill(p.pid,signal.SIGCONT)
                self.finish(p,code=2)
                self.assertFalse(writes(device))
            finally:
                gate.set()
                if p.poll() is None:
                    os.kill(p.pid,signal.SIGCONT);p.kill();p.communicate()

    def test_manual_panel_requires_explicit_control(self):
        with PlanDevice() as device, tempfile.TemporaryDirectory() as directory:
            path,_=self.config(directory,device)
            result=self.manual_command(directory,path,enabled=False)
            self.assertEqual(result.returncode,2);self.assertFalse(device.requests)

    def test_manual_handoff_pauses_monitor_but_rejects_active_dry(self):
        with PlanDevice() as device,tempfile.TemporaryDirectory() as directory:
            path,_=self.config(directory,device,slow=True)
            p=self.launch(directory,path,control=False,polls=100)
            self.wait_state(p,directory,lambda s:s.get('communication')=='reachable')
            (Path(directory)/'manual-pause.request').write_text(str(uuid.uuid4()))
            self.finish(p)
            self.assertIn('manual_pause_accepted',[e['event'] for e in self.events(directory)])
            p=self.launch(directory,path,manual=True,polls=100)
            try:
                self.wait_state(p,directory,lambda s:s.get('state')=='DRY')
                command=str(uuid.uuid4());(Path(directory)/'manual-pause.request').write_text(command)
                self.wait_state(p,directory,lambda s:s.get('manualPauseRejectedId')==command)
                self.assertIsNone(p.poll())
                self.assertEqual(self.state(directory)['state'],'DRY')
                self.stop(directory);self.finish(p)
            finally:
                if p.poll() is None:p.kill();p.communicate()

    def test_manual_dry_runs_once_without_falsifying_power_checks(self):
        with PlanDevice() as device, tempfile.TemporaryDirectory() as directory:
            path, config = self.config(directory, device)
            config.update(panelPowerCouplingVerified=False, startupProtectionVerified=False)
            atomic_json(path, config)
            # A pending gate is resolved by this new, explicit interactive launch.
            atomic_json(Path(directory)/'estado.json', dict(operatorPending=True, operatorGateId=str(uuid.uuid4())))
            self.finish(self.launch(directory, path, manual=True, polls=100))
            events = self.events(directory)
            self.assertEqual(sum(e['event']=='manual_dry_completed' for e in events), 1)
            self.assertEqual(sum(e['event']=='profile_started' for e in events), 1)
            self.assertEqual(self.state(directory)['state'], 'STOPPED')
            self.assertEqual(self.state(directory)['execution'], 'manual-dry')
            self.assertFalse(self.state(directory)['operatorPending'])
            self.assertFalse(json.loads(path.read_text())['panelPowerCouplingVerified'])
            values = [r[18:-2] for r in writes(device)]
            self.assertEqual(values[:3], [b'\x05\x00', b'\x19', b'\x06\x04'])
            self.assertEqual(values[-1], b'\x05\x00')
            self.assertEqual([brightness(r) for r in writes(device) if brightness(r) is not None][-1], 25)

    def test_manual_dry_read_loss_cancels_without_restart(self):
        with PlanDevice(drop_read_at=[4]) as device, tempfile.TemporaryDirectory() as directory:
            path, _ = self.config(directory, device, slow=True)
            self.finish(self.launch(directory, path, manual=True, polls=100), code=2)
            self.assertEqual(device.read_count, 4)
            self.assertTrue(self.state(directory)['operatorPending'])
            self.assertEqual(self.state(directory)['state'], 'FAULT')
            self.assertEqual(sum(e['event']=='profile_started' for e in self.events(directory)), 1)
            self.assertNotIn('manual_dry_completed', [e['event'] for e in self.events(directory)])

    def test_manual_dry_without_control_rejected_before_network_or_storage(self):
        with PlanDevice() as device, tempfile.TemporaryDirectory() as directory:
            path, _ = self.config(directory, device)
            self.finish(self.launch(directory, path, manual=True, control=False), code=2)
            self.assertFalse(device.requests)
            self.assertFalse((Path(directory)/'estado.json').exists())

    def test_readonly_default_recovers_without_writes(self):
        with PlanDevice(drop_read_at=[3]) as device, tempfile.TemporaryDirectory() as directory:
            path, _ = self.config(directory, device)
            p = self.launch(directory, path, control=False, polls=8)
            self.finish(p)
            self.assertFalse(writes(device))
            self.assertIn('reconnected', [e['event'] for e in self.events(directory)])
            self.assertFalse(self.state(directory)['operatorPending'])
            self.assertFalse(device.errors)

    @unittest.skipUnless(os.name == 'nt', 'Windows FILE_SHARE_DELETE regression')
    def test_brief_windows_reader_lock_does_not_stop_state_publication(self):
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                      wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        kernel.CreateFileW.restype = wintypes.HANDLE
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle.restype = wintypes.BOOL
        with PlanDevice() as device, tempfile.TemporaryDirectory() as directory:
            path, _ = self.config(directory, device)
            p = self.launch(directory, path, control=False, polls=100)
            handle = None
            try:
                before = self.wait_state(p, directory, lambda s: s.get('communication') == 'reachable')['updatedUtc']
                # Read/write sharing, deliberately excluding delete-sharing like ordinary Windows readers.
                handle = kernel.CreateFileW(str(Path(directory)/'estado.json'), 0x80000000, 3, None, 3, 0, None)
                self.assertNotEqual(handle, wintypes.HANDLE(-1).value, ctypes.get_last_error())
                time.sleep(.35)
                self.assertIsNone(p.poll(), 'A brief reader lock stopped the monitor')
                kernel.CloseHandle(handle); handle = None
                self.wait_state(p, directory, lambda s: s.get('updatedUtc') not in (None, before))
                self.stop(directory); self.finish(p)
                self.assertNotIn('process_fault', [e['event'] for e in self.events(directory)])
                self.assertFalse(writes(device))
            finally:
                if handle not in (None, wintypes.HANDLE(-1).value): kernel.CloseHandle(handle)
                if p.poll() is None:
                    p.kill(); p.communicate()

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
                time.sleep(.5)
                # A Windows atomic replacement can make a single open transiently unavailable.
                # Wait for a readable snapshot, then assert its values (never wait for the expected value).
                held = self.wait_state(p, directory, lambda s: 'operatorPending' in s)
                self.assertEqual(held['operatorLastCommandId'], second_hold['id'])
                self.assertTrue(held['operatorPending'])
                self.assertEqual(len(writes(device)), count)
                self.command(directory, gate, 'restart')
                self.wait_state(p, directory, lambda s: s.get('state') == 'PREHEAT')
                completed = self.wait_state(p, directory, lambda s: s.get('state') == 'BLACK', timeout=10)
                self.assertFalse(completed['operatorPending'])
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
