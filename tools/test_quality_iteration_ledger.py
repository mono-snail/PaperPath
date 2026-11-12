"""The autonomous loop must preserve the user's round and retry ceilings."""
from copy import deepcopy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import QualityIterationLedger as ledger


class QualityIterationLimitTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        self.root.joinpath('docs').mkdir()
        self.definition = dict(features={'one': {}}, targetPercent=100)
        patches = [patch.object(ledger, 'LEDGER', self.root / 'docs/ledger.json'),
                   patch.object(ledger, 'ARTIFACTS', self.root / 'artifacts'),
                   patch.object(ledger, 'targets', side_effect=lambda: deepcopy(self.definition))]
        for value in patches:
            value.start()
            self.addCleanup(value.stop)

    def test_round_21_is_rejected_even_if_all_previous_rounds_failed(self):
        for number in range(20):
            ledger.update('begin', title='Substantive package ' + str(number + 1))
            ledger.update('finish', outcome='FAILED', note='Explicit retained failure')
        state = ledger.update('status')
        self.assertEqual(state['completed'], 20)
        self.assertEqual(state['status'], 'LIMIT_REACHED_USER_VERIFICATION')
        with self.assertRaises(ValueError): ledger.update('begin', title='Forbidden 21')

    def test_fourth_simulator_attempt_and_overlapping_round_are_rejected(self):
        ledger.update('begin', title='One package')
        for _ in range(3): ledger.update('attempt', note='One bounded runtime invocation')
        with self.assertRaises(ValueError): ledger.update('attempt')
        with self.assertRaises(ValueError): ledger.update('begin', title='Overlap')

    def test_targets_cannot_be_lowered_or_a_partial_report_called_complete(self):
        ledger.update('begin', title='One package')
        self.definition['targetPercent'] = 80
        with self.assertRaises(ValueError): ledger.update('status')
        self.definition['targetPercent'] = 100
        proof = self.root / 'partial.json'
        proof.write_text(json.dumps(dict(status='TARGETS_MET', metrics={}, features=[])))
        with self.assertRaises(ValueError): ledger.update('finish', metrics=proof, outcome='TARGETS_MET')

    def test_new_defect_and_oracle_obligations_cannot_later_disappear(self):
        self.definition.update(oracleTests=['first'], defectIDs=['original'], oraclePositiveControls=[])
        ledger.update('begin', title='Review')
        self.definition['oracleTests'].append('new-control'); self.definition['defectIDs'].append('new-defect')
        ledger.update('status')
        for key, item in [('oracleTests', 'new-control'), ('defectIDs', 'new-defect')]:
            self.definition[key].remove(item)
            with self.assertRaises(ValueError): ledger.update('status')
            self.definition[key].append(item)

    def test_negative_control_cannot_be_reclassified_to_shrink_denominator(self):
        self.definition.update(oracleTests=['known-negative'], defectIDs=[], oraclePositiveControls=[])
        ledger.update('begin', title='Review')
        self.definition['oraclePositiveControls'].append('known-negative')
        with self.assertRaises(ValueError): ledger.update('status')


if __name__ == '__main__': unittest.main()
