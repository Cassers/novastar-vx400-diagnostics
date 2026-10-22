"""Actual probe child processes against loopback only; no screen writes."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import plan_runtime_tests as plan
from plan_runtime_tests import PlanDevice, atomic_json, writes
from runtime_tests import POWERSHELL, ROOT


@unittest.skipUnless(POWERSHELL, 'PowerShell unavailable')
class ProbeRuntimeTests(unittest.TestCase):
    def config(self, directory, device, model):
        path, config = plan.PlanRuntimeTests().config(directory, device)
        config['deviceModel'] = model
        atomic_json(path, config)
        return path

    def probe(self, path, code=0):
        result = subprocess.run([POWERSHELL, '-NoLogo', '-NoProfile', '-File',
                                 str(ROOT/'Test-VxConnection.ps1'), '-ConfigPath', str(path)],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, code, result.stdout+'\n'+result.stderr)
        return json.loads(result.stdout)

    def test_both_models_are_confirmed_by_reads_only(self):
        for model, model_id in [('VX400', 0x6211), ('VX600', 0x620e)]:
            with self.subTest(model=model), PlanDevice(model_id=model_id) as device, tempfile.TemporaryDirectory() as directory:
                path = self.config(directory, device, model)
                result = self.probe(path)
                self.assertTrue(result['success'])
                self.assertTrue(result['readOnly'])
                self.assertEqual(result['modelId'], model_id)
                self.assertEqual(result['model'], model)
                self.assertEqual(device.read_count, 1)
                self.assertFalse(writes(device))
                self.assertFalse(device.errors)

    def test_wrong_model_is_a_visible_failure_without_writes(self):
        with PlanDevice(model_id=0x6211) as device, tempfile.TemporaryDirectory() as directory:
            result = self.probe(self.config(directory, device, 'VX600'), code=2)
            self.assertFalse(result['success'])
            self.assertIn('Wrong ModelID', result['message'])
            self.assertFalse(writes(device))

    def test_existing_engine_keeps_probe_from_contacting_the_device(self):
        fixture = plan.PlanRuntimeTests()
        with PlanDevice(model_id=0x620e) as device, tempfile.TemporaryDirectory() as directory:
            path = self.config(directory, device, 'VX600')
            engine = fixture.launch(directory, path, control=False, polls=200)
            try:
                fixture.wait_state(engine, directory, lambda s: s.get('communication') == 'reachable')
                result = self.probe(path, code=2)
                self.assertFalse(result['success'])
                self.assertIn('Otro controlador', result['message'])
                self.assertFalse(writes(device))
                fixture.stop(directory)
                fixture.finish(engine)
            finally:
                if engine.poll() is None:
                    engine.kill();engine.communicate()


if __name__ == '__main__':
    unittest.main(verbosity=2)
