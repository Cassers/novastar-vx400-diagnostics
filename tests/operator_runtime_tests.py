"""Operator engine subprocess against loopback only. Synthetic short ramps, not thermal curves."""
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import tempfile
import time
import unittest
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone, timedelta
from plan_runtime_tests import PlanDevice, atomic_json, stamp, writes, brightness
from runtime_tests import ROOT, receive, make_reply
from layer_runtime_tests import block, BASE
import socket
import threading

PS = os.environ.get('VX400_POWERSHELL') or shutil.which('powershell') or shutil.which('pwsh')


class OperatorLayerDevice(PlanDevice):
    def __init__(self, mismatch=False):
        super().__init__(model_id=0x620E)
        self.blocks=[block(i) for i in range(3)]
        for i,data in enumerate(self.blocks):
            data[3]=i
        self.mismatch=mismatch
        self.write_gate=None
        self.write_blocked=threading.Event()

    def run(self):
        while not self.stop.is_set():
            try:
                connection,_=self.listener.accept()
            except socket.timeout:
                continue
            with connection:
                try:
                    connection.settimeout(2)
                    request=receive(connection,18)
                    count=struct.unpack_from('<H',request,16)[0]
                    is_write=request[10]==1
                    request+=receive(connection,(count if is_write else 0)+2)
                    self.requests.append(request)
                    address=struct.unpack_from('<I',request,12)[0]
                    payload=b''
                    if address==2:
                        payload=b'\x0e\x62'
                    elif address in [BASE+i*48 for i in range(3)]:
                        index=(address-BASE)//48
                        if is_write:
                            self.blocks[index]=bytearray(request[18:-2])
                            if self.mismatch:
                                self.blocks[(index+1)%3][0]^=1
                        else:
                            payload=bytes(self.blocks[index])
                    elif not is_write:
                        raise AssertionError(address)
                    if is_write and address==0x13000004 and self.write_gate is not None:
                        gate=self.write_gate
                        self.write_gate=None
                        self.write_blocked.set()
                        gate.wait(5)
                    connection.sendall(make_reply(request,payload))
                except (BrokenPipeError,ConnectionResetError):
                    pass
                except Exception as error:
                    self.errors.append(repr(error))

@unittest.skipUnless(PS, 'PowerShell unavailable')
class OperatorRuntime(unittest.TestCase):
    def setUp(self):
        self.children=[]

    @contextmanager
    def fixture(self):
        # Release exact test children BEFORE TemporaryDirectory removes Windows locks,
        # including when an assertion fails. unittest cleanups alone run too late.
        with tempfile.TemporaryDirectory() as directory:
            try:
                yield directory
            finally:
                for base,process,cleanup in self.children:
                    if base==Path(directory):
                        cleanup()

    def setup_config(self, directory, device, **settings):
        base = Path(directory)
        plan = json.loads((ROOT/'plan.config.json').read_text(encoding='utf-8-sig'))
        plan.update(deviceModel='VX400', deviceAddress='127.0.0.1', tcpPort=device.port,
                    pollIntervalSeconds=.1, timeoutMs=250, onlineSuccesses=1,
                    maximumObservationGapSeconds=2, panelPowerCouplingVerified=True,
                    startupProtectionVerified=True, dailyStarts=[], operatingWindows=[])
        operator = json.loads((ROOT/'operator.config.json').read_text(encoding='utf-8-sig'))
        operator.update(configured=True, mediaEnabled=False, preheatMinutes=.003,
                        cooldownMinutes=.01)
        operator.update(settings)
        atomic_json(base/'plan.json', plan)
        atomic_json(base/'operator.json', operator)
        return base

    def launch(self, base, control=True, polls=300, extra=()):
        args = [PS, '-NoLogo', '-NoProfile', '-File', str(ROOT/'Watch-VxOperator.ps1'),
                '-ConfigPath', str(base/'plan.json'), '-OperatorConfigPath', str(base/'operator.json'),
                '-DataDirectory', str(base/'data'), '-MaxPolls', str(polls)]
        if control:
            args += ['-EnableControl']
        process=subprocess.Popen(args + list(extra), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def cleanup():
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=10)
        self.children.append((base,process,cleanup))
        self.addCleanup(cleanup)
        return process

    def state(self, base):
        try:
            return json.loads((base/'data/operator-state.json').read_text(encoding='utf-8-sig'))
        except (OSError, ValueError):
            return {}

    def wait(self, base, process, predicate, timeout=12):
        end = time.monotonic()+timeout
        while time.monotonic() < end:
            state = self.state(base)
            if state.get('ownerProcessId') == process.pid and predicate(state):
                return state
            if process.poll() is not None:
                out, err = process.communicate()
                self.fail(f'Exited {process.returncode}: {out}\n{err}\n{state}')
            time.sleep(.025)
        self.fail(f'Timeout: {self.state(base)}')

    def command(self, base, session, action, **fields):
        value = dict(schemaVersion=1, id=str(uuid.uuid4()), sessionId=session, utc=stamp(), action=action)
        value.update(fields)
        atomic_json(base/'data/operator-command.json', value)
        return value

    def stop(self, base, process, code=0):
        (base/'data/stop.request').touch()
        out, err = process.communicate(timeout=10)
        self.assertEqual(process.returncode, code, out+'\n'+err)

    def test_validate_only_no_directory_or_network(self):
        with PlanDevice() as device, self.fixture() as directory:
            base = self.setup_config(directory, device)
            process = self.launch(base, extra=['-ValidateOnly'])
            out, err = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, out+err)
            self.assertFalse((base/'data').exists())
            self.assertFalse(device.requests)

    def test_monitor_never_writes(self):
        with PlanDevice() as device, self.fixture() as directory:
            base = self.setup_config(directory, device)
            process = self.launch(base, control=False, polls=4)
            out, err = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, out+err)
            self.assertFalse(writes(device))

    def test_preheat_ready_shutdown_interlocks_replay(self):
        with PlanDevice() as device, self.fixture() as directory:
            base = self.setup_config(directory, device)
            process = self.launch(base)
            state = self.wait(base, process, lambda s:s.get('communication')=='reachable' and s.get('state')=='BLACK')
            session = state['sessionId']
            command = self.command(base, session, 'preheat')
            state = self.wait(base, process, lambda s:s.get('state')=='READY')
            self.assertAlmostEqual(state['brightnessRequestedPercent'], 25, delta=.4)
            self.assertTrue(state['preheatReady'])
            self.assertFalse(state['outputBlackoutConfirmed'])
            before = len(writes(device))
            atomic_json(base/'data/operator-command.json', command)
            time.sleep(.25)
            self.assertEqual(len(writes(device)), before)
            self.command(base, session, 'shutdown')
            self.wait(base, process, lambda s:s.get('state')=='COOLDOWN')
            self.command(base, session, 'preheat')
            self.wait(base, process, lambda s:'interlock' in s.get('lastCommandResult',''))
            state=self.wait(base, process, lambda s:s.get('state')=='BLACK')
            self.assertTrue(state['outputBlackoutConfirmed'])
            after = [brightness(r) for r in writes(device)[before:] if brightness(r) is not None]
            self.assertTrue(all(a>=b for a,b in zip(after, after[1:])), after)
            self.stop(base, process)
            self.assertFalse(device.errors)

    def test_stale_extra_fields_old_session_rejected(self):
        with PlanDevice() as device, self.fixture() as directory:
            base = self.setup_config(directory, device)
            process = self.launch(base)
            state=self.wait(base, process, lambda s:s.get('communication')=='reachable')
            for fields in [dict(percent=80), dict(utc='2000-01-01T00:00:00Z'), dict(sessionId=str(uuid.uuid4()))]:
                command=self.command(base, state['sessionId'], 'preheat', **fields)
                self.wait(base, process, lambda s:s.get('lastCommandId')==command['id'] and s.get('lastCommandResult','').startswith('Rejected'))
                self.assertEqual(self.state(base)['state'], 'BLACK')
            self.stop(base, process)

    def test_loss_gates_no_automatic_resume_restart(self):
        with PlanDevice(drop_read_at=range(12,15)) as device, self.fixture() as directory:
            base = self.setup_config(directory, device, preheatMinutes=.03)
            process = self.launch(base)
            state=self.wait(base, process, lambda s:s.get('communication')=='reachable')
            self.command(base, state['sessionId'], 'preheat')
            self.wait(base, process, lambda s:s.get('state')=='WAIT_OPERATOR')
            self.wait(base, process, lambda s:s.get('communication')=='reachable')
            time.sleep(.3)
            self.assertEqual(self.state(base)['state'], 'WAIT_OPERATOR')
            hold=self.command(base,self.state(base)['sessionId'],'shutdown')
            state=self.wait(base,process,lambda s:s.get('lastCommandId')==hold['id'])
            self.assertEqual(state['state'],'WAIT_OPERATOR')
            self.assertTrue(state['outputBlackoutConfirmed'])
            self.assertEqual(state['brightnessRequestedPercent'],0)
            self.stop(base, process)
            process=self.launch(base)
            self.wait(base, process, lambda s:s.get('communication')=='reachable' and s.get('operatorPending'))
            self.command(base, self.state(base)['sessionId'], 'preheat')
            self.wait(base, process, lambda s:s.get('state')=='READY')
            self.stop(base, process)

    def test_wrong_model_no_write(self):
        with PlanDevice(model_id=0x620E) as device, self.fixture() as directory:
            base=self.setup_config(directory, device)
            process=self.launch(base,polls=3)
            out,err=process.communicate(timeout=10)
            self.assertEqual(process.returncode,0,out+err)
            self.assertFalse(writes(device))
            self.assertTrue(self.state(base)['operatorPending'])

    def test_endpoint_contention_never_overwrites_owner_state(self):
        with PlanDevice() as device, self.fixture() as directory:
            base=self.setup_config(directory,device)
            first=self.launch(base)
            owner=self.wait(base,first,lambda s:s.get('communication')=='reachable')
            second=self.launch(base,polls=1)
            out,err=second.communicate(timeout=10)
            self.assertEqual(second.returncode,2,out+err)
            self.assertEqual(self.state(base)['sessionId'],owner['sessionId'])
            self.stop(base,first)


    def test_ready_layer_switch_and_scale_preserve_all_other_bytes(self):
        with OperatorLayerDevice() as device, self.fixture() as directory:
            base=self.setup_config(directory,device,canvasWidth=1600,canvasHeight=900)
            plan=json.loads((base/'plan.json').read_text());plan['deviceModel']='VX600';atomic_json(base/'plan.json',plan)
            process=self.launch(base)
            state=self.wait(base,process,lambda s:s.get('communication')=='reachable')
            session=state['sessionId']
            self.command(base,session,'preheat')
            self.wait(base,process,lambda s:s.get('state')=='READY')
            original=bytes(device.blocks[0])
            command=self.command(base,session,'layer',layer='Main',enabled=True)
            self.wait(base,process,lambda s:s.get('lastCommandId')==command['id'] and len(s.get('layers',[]))==3 and s['layers'][0]['enabled'])
            self.assertEqual(bytes(device.blocks[0][1:]),original[1:])
            command=self.command(base,session,'scale')
            self.wait(base,process,lambda s:s.get('lastCommandId')==command['id'] and s.get('layers',[{}])[0].get('width')==1600)
            self.assertEqual(struct.unpack_from('<IIII',device.blocks[0],5),(0,0,1600,900))
            self.assertEqual(bytes(device.blocks[0][21:]),original[21:])
            self.stop(base,process)
            self.assertFalse(device.errors)

    def test_layer_side_effect_opens_gate(self):
        with OperatorLayerDevice(mismatch=True) as device, self.fixture() as directory:
            base=self.setup_config(directory,device)
            plan=json.loads((base/'plan.json').read_text());plan['deviceModel']='VX600';atomic_json(base/'plan.json',plan)
            process=self.launch(base)
            state=self.wait(base,process,lambda s:s.get('communication')=='reachable')
            self.command(base,state['sessionId'],'preheat')
            self.wait(base,process,lambda s:s.get('state')=='READY')
            self.command(base,state['sessionId'],'layer',layer='Main',enabled=True)
            state=self.wait(base,process,lambda s:s.get('state')=='WAIT_OPERATOR')
            self.assertIn('readback mismatch',state['message'])
            self.stop(base,process)

    def test_command_remains_pending_until_display_ack(self):
        with OperatorLayerDevice() as device, self.fixture() as directory:
            base=self.setup_config(directory,device)
            plan=json.loads((base/'plan.json').read_text())
            plan.update(deviceModel='VX600',timeoutMs=5000,maximumObservationGapSeconds=10)
            atomic_json(base/'plan.json',plan)
            process=self.launch(base)
            release=threading.Event()
            try:
                state=self.wait(base,process,lambda s:s.get('communication')=='reachable')
                prepare=self.command(base,state['sessionId'],'preheat')
                self.wait(base,process,lambda s:s.get('state')=='READY' and s.get('lastCommandId')==prepare['id'])
                device.write_gate=release
                shutdown=self.command(base,state['sessionId'],'shutdown')
                self.assertTrue(device.write_blocked.wait(3),'Display write never reached delayed ACK')
                pending=self.wait(base,process,lambda s:s.get('state')=='COOLDOWN')
                self.assertNotEqual(pending['lastCommandId'],shutdown['id'])
                self.assertFalse(pending['outputBlackoutConfirmed'])
                release.set()
                self.wait(base,process,lambda s:s.get('lastCommandId')==shutdown['id'])
            finally:
                release.set()
                self.stop(base,process)


    def test_daily_consumed_before_start_and_no_restart_resume(self):
        now=datetime.now(timezone.utc)
        end=now+timedelta(minutes=2)
        if end.date()!=now.date():
            self.skipTest('Synthetic daily fixture crosses midnight')
        with PlanDevice() as device,self.fixture() as directory:
            base=self.setup_config(directory,device,dailyStart=now.strftime('%H:%M'),dailyEnd=end.strftime('%H:%M'),dryRampMinutes=.003,dryFallMinutes=.003)
            plan=json.loads((base/'plan.json').read_text());plan.update(timeZone='UTC',maximumObservationGapSeconds=120);atomic_json(base/'plan.json',plan)
            process=self.launch(base)
            self.wait(base,process,lambda s:s.get('state')=='DRY' and s.get('phase')=='Dry hold')
            ledger=json.loads((base/'data/operator-session.json').read_text())
            self.assertEqual(ledger['lastConsumedDay'],now.strftime('%Y-%m-%d'))
            self.assertTrue(ledger['active'])
            self.stop(base,process)
            process=self.launch(base)
            self.wait(base,process,lambda s:s.get('communication')=='reachable' and s.get('state')=='WAIT_OPERATOR')
            self.stop(base,process)

    @unittest.skipIf(os.name=='nt','POSIX suspension harness; Windows gap covered by clock logic')
    def test_observation_gap_discards_active_preheat(self):
        with PlanDevice() as device,self.fixture() as directory:
            base=self.setup_config(directory,device,preheatMinutes=.2)
            process=self.launch(base)
            state=self.wait(base,process,lambda s:s.get('communication')=='reachable')
            self.command(base,state['sessionId'],'preheat')
            self.wait(base,process,lambda s:s.get('state')=='PREHEAT')
            os.kill(process.pid,signal.SIGSTOP)
            time.sleep(2.2)
            os.kill(process.pid,signal.SIGCONT)
            state=self.wait(base,process,lambda s:s.get('state')=='WAIT_OPERATOR')
            self.assertTrue(state['operatorPending'])
            self.stop(base,process)


    def test_scale_unknown_canvas_rejects_without_hardware_write(self):
        with OperatorLayerDevice() as device,self.fixture() as directory:
            base=self.setup_config(directory,device)
            plan=json.loads((base/'plan.json').read_text());plan['deviceModel']='VX600';atomic_json(base/'plan.json',plan)
            process=self.launch(base)
            state=self.wait(base,process,lambda s:s.get('communication')=='reachable')
            self.command(base,state['sessionId'],'preheat')
            self.wait(base,process,lambda s:s.get('state')=='READY')
            count=len(writes(device))
            command=self.command(base,state['sessionId'],'scale')
            state=self.wait(base,process,lambda s:s.get('lastCommandId')==command['id'])
            self.assertTrue(state['lastCommandResult'].startswith('Rejected'),state)
            self.assertEqual(state['state'],'READY')
            self.assertEqual(len(writes(device)),count)
            self.stop(base,process)

    def test_late_daily_consumes_day_without_dry(self):
        now=datetime.now(timezone.utc)
        if now.hour==0 and now.minute<1:
            self.skipTest('Fixture requires time later than00:01UTC')
        with PlanDevice() as device,self.fixture() as directory:
            base=self.setup_config(directory,device,dailyStart='00:00',dailyEnd='00:01',dryRampMinutes=.003,dryFallMinutes=.003)
            plan=json.loads((base/'plan.json').read_text());plan['timeZone']='UTC';atomic_json(base/'plan.json',plan)
            process=self.launch(base)
            self.wait(base,process,lambda s:s.get('communication')=='reachable')
            time.sleep(.2)
            self.assertEqual(self.state(base)['state'],'BLACK')
            ledger=json.loads((base/'data/operator-session.json').read_text())
            self.assertEqual(ledger['lastConsumedDay'],now.strftime('%Y-%m-%d'))
            self.assertFalse(any(r[18]>25 for r in writes(device) if brightness(r) is not None))
            self.stop(base,process)

    def test_previous_unclean_active_gates_startup(self):
        with PlanDevice() as device, self.fixture() as directory:
            base=self.setup_config(directory,device)
            (base/'data').mkdir()
            atomic_json(base/'data/operator-session.json',dict(schemaVersion=1,sessionId=str(uuid.uuid4()),lastConsumedDay='2026-01-01',consumedCommandIds=[],operatorPending=False,active=True))
            process=self.launch(base)
            self.wait(base,process,lambda s:s.get('communication')=='reachable' and s.get('state')=='WAIT_OPERATOR')
            self.assertFalse(any(brightness(r) and brightness(r)>25 for r in writes(device)))
            self.stop(base,process)

if __name__=='__main__':
    unittest.main()
