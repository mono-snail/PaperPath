import copy
import unittest
from CheckCorePaths import evaluate


class CoreGateTests(unittest.TestCase):
    def setUp(self):
        self.ref = 'PaperPathUITests/testActualResult()'
        self.policy = dict(targetPercent=100,scope='test',manualGates=[],paths=[dict(id='core',title='Core',cases=[
            dict(test=self.ref,feature='documentTools.fillForm',runner='quality',requiresOutputAudit=True)])])
        self.run = dict(path='test-evidence',valid=True,sourceCurrent=True,tests={self.ref},
            auditFeatures={'documentTools.fillForm':[self.ref]})

    def check(self,run=None): return evaluate(self.policy,[self.run if run is None else run],{self.ref: {}})

    def test_current_execution_and_actual_output_are_required(self):
        self.assertEqual(self.check()['status'],'CORE_PATHS_PASSED')

    def test_ui_pass_without_output_cannot_pass_core(self):
        run=copy.deepcopy(self.run);run['auditFeatures']={}
        self.assertEqual(self.check(run)['status'],'CORE_GAPS')

    def test_output_without_ui_execution_cannot_pass_core(self):
        run=copy.deepcopy(self.run);run['tests']=set()
        self.assertEqual(self.check(run)['status'],'CORE_GAPS')

    def test_failed_or_stale_run_cannot_pass_core(self):
        run=copy.deepcopy(self.run);run['valid']=False;run['sourceCurrent']=False
        self.assertEqual(self.check(run)['status'],'CORE_GAPS')

    def test_stale_source_cannot_pass_even_with_a_pass_label(self):
        run=copy.deepcopy(self.run);run['sourceCurrent']=False
        self.assertEqual(self.check(run)['status'],'CORE_GAPS')

    def test_empty_case_set_is_rejected(self):
        self.policy['paths'][0]['cases']=[]
        with self.assertRaises(AssertionError):self.check()


if __name__=='__main__':unittest.main()
