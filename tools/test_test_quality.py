"""Quality indicators must fail closed on invented, stale or partial evidence."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import CheckTestQuality as quality
from swift_test_inventory import inventory

ROOT = Path(__file__).resolve().parents[1]


class TestQualityTests(unittest.TestCase):
    def setUp(self):
        self.policy = json.loads((ROOT / 'docs/TEST_QUALITY_CONTRACT.json').read_text())
        # Algorithm fixtures must be independent of the editorial review date.
        for scenario in self.policy['scenarios'].values():
            scenario['reviewedSources'] = {
                path: quality.sha(ROOT / path)
                for path in scenario['reviewedSources']
            }
        self.tests = {test for scenario in self.policy['scenarios'].values() for test in scenario['tests']}

    def run_proof(self, finish, valid=True, tests=None, audit=True):
        selected = self.tests if tests is None else tests
        return dict(path=str(finish), tests=set(selected) if valid else set(),
            observedTests=set(selected), valid=valid, sourceCurrent=True, audit=audit,
            finishTime=finish)

    def evaluate(self, runs=(), policy=None, oracle_path=None):
        mapping = {Path('/evidence/' + str(index)): row for index, row in enumerate(runs)}
        with patch.object(quality, 'load_run', side_effect=lambda path, current: deepcopy(mapping[path])), \
             patch.object(quality, 'runtime_sources', return_value={}):
            return quality.evaluate(ROOT, policy or self.policy, mapping, oracle_path)

    def merge(self, report):
        return next(row for row in report['features'] if row['feature'] == 'quickTasks.mergePDFs')

    def test_names_without_execution_are_not_verified(self):
        report = self.evaluate()
        self.assertEqual(report['metrics']['featureRegistration']['verified'], len(self.policy['features']))
        self.assertEqual(report['metrics']['criticalStates']['verified'], 0)
        self.assertEqual(report['status'], 'INCOMPLETE')

    def test_complete_merge_evidence_covers_all_declared_merge_materials(self):
        row = self.merge(self.evaluate([self.run_proof(1)]))
        self.assertTrue(all(row['states'].values()))
        self.assertEqual(set(row['missingMaterials']), set())
        self.assertEqual(row['stableRuns'], 1)
        self.assertTrue(row['independentOutput'])

    def test_merge_scenario_cannot_be_reused_to_claim_another_feature(self):
        policy = deepcopy(self.policy)
        policy['features']['quickTasks.compressPDF']['states']['primaryResult'] = ['merge.result']
        with self.assertRaisesRegex(ValueError, 'different feature'):
            self.evaluate(policy=policy)

    def test_service_test_cannot_substitute_for_ui_state_coverage(self):
        policy = deepcopy(self.policy)
        policy['features']['quickTasks.mergePDFs']['states']['primaryResult'] = ['merge.noteBounds']
        with self.assertRaisesRegex(ValueError, 'service-only'):
            self.evaluate(policy=policy)

    def test_unknown_or_deleted_test_cannot_be_claimed(self):
        policy = deepcopy(self.policy)
        policy['scenarios']['merge.result']['tests'] = ['PaperPathUITests/testMissing()']
        with self.assertRaisesRegex(ValueError, 'XCTest reference'):
            self.evaluate(policy=policy)

    def test_changed_reviewed_test_requires_review(self):
        policy = deepcopy(self.policy)
        for scenario in policy['scenarios'].values():
            scenario['reviewedSources'] = {path: 'outdated' for path in scenario['reviewedSources']}
        report = self.evaluate([self.run_proof(1)], policy)
        self.assertEqual(report['metrics']['criticalStates']['verified'], 0)
        self.assertEqual(set(report['scenarios'].values()), {'review-stale'})

    def test_copied_results_do_not_fabricate_stability(self):
        row = self.merge(self.evaluate([self.run_proof(1), self.run_proof(1), self.run_proof(1)]))
        self.assertEqual(row['stableRuns'], 1)

    def test_failure_between_passes_resets_consecutive_streak(self):
        runs = [self.run_proof(1), self.run_proof(2, valid=False), self.run_proof(3), self.run_proof(4)]
        self.assertEqual(self.merge(self.evaluate(runs))['stableRuns'], 2)

    def test_failed_focused_case_also_resets_stability(self):
        runs = [self.run_proof(1), self.run_proof(2, valid=False,
            tests=self.policy['scenarios']['merge.locked']['tests']), self.run_proof(3)]
        self.assertEqual(self.merge(self.evaluate(runs))['stableRuns'], 1)

    def test_focused_passes_cannot_be_assembled_as_three_complete_runs(self):
        runs = [self.run_proof(i + 1, tests=s['tests']) for i, s in enumerate(self.policy['scenarios'].values())]
        self.assertEqual(self.merge(self.evaluate(runs))['stableRuns'], 0)

    def test_missing_independent_output_cannot_pass_output_or_stability(self):
        row = self.merge(self.evaluate([self.run_proof(1, audit=False)]))
        self.assertFalse(row['independentOutput'])
        self.assertEqual(row['stableRuns'], 0)

    def test_three_distinct_complete_passes_do_not_hide_other_feature_gaps(self):
        report = self.evaluate([self.run_proof(1), self.run_proof(2), self.run_proof(3)])
        self.assertEqual(self.merge(report)['stableRuns'], 3)
        self.assertEqual(report['status'], 'INCOMPLETE')

    def test_denominator_cannot_silently_drop_base_state(self):
        policy = deepcopy(self.policy)
        entry = policy['features']['quickTasks.mergePDFs']
        entry['requiredStates'].remove('repeatBoundary')
        del entry['states']['repeatBoundary']
        with self.assertRaisesRegex(ValueError, 'base states'):
            self.evaluate(policy=policy)

    def test_oracle_claim_requires_all_controls_and_current_source(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'controls.json'
            proof = dict(status='PASSED', sourceUnchanged=True, outcomes={t: 'Passed' for t in self.policy['oracleTests']},
                sourceHashes={p: quality.sha(ROOT / p) for p in self.policy['oracleSources']})
            path.write_text(json.dumps(proof))
            self.assertTrue(self.evaluate(oracle_path=path)['oracle']['verified'])
            proof['status'] = 'FAILED'
            proof['outcomes']['MergeOutputAuditTests/test_wrong_page_order_is_rejected'] = 'Failed'
            path.write_text(json.dumps(proof))
            self.assertEqual(self.evaluate(oracle_path=path)['oracle']['negativeDetected'], len(self.policy['oracleTests']) - len(self.policy.get('oraclePositiveControls', ['MergeOutputAuditTests/test_correct_output_passes'])) - 1)
            proof['status'] = 'PASSED'
            proof['outcomes']['MergeOutputAuditTests/test_wrong_page_order_is_rejected'] = 'Passed'
            proof['outcomes'].pop(self.policy['oracleTests'][-1])
            path.write_text(json.dumps(proof))
            self.assertFalse(self.evaluate(oracle_path=path)['oracle']['verified'])
            proof['outcomes'] = {t: 'Passed' for t in self.policy['oracleTests']}
            proof['sourceHashes'][self.policy['oracleSources'][0]] = 'old'
            path.write_text(json.dumps(proof))
            self.assertFalse(self.evaluate(oracle_path=path)['oracle']['verified'])

    def test_empty_audit_or_pass_label_alone_is_not_output_evidence(self):
        self.assertFalse(quality.audit_valid(dict(status='PASSED', outputs=[])))
        self.assertFalse(quality.audit_valid(dict(status='PASSED', outputs=[dict(pages=[])])))

    def test_release_quality_failure_can_be_reassessed_but_failed_runtime_cannot(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = dict(status='FAILED', sourceFingerprint='same', sourceUnchangedDuringRun=True,
                stages=[dict(name='unit', passed=True, counts={}, command=['-resultBundlePath', 'unit.xcresult']),
                        dict(name='ui-iphone-1', passed=True, counts={}, command=['-resultBundlePath', 'ui.xcresult']),
                        dict(name='release-build', passed=True), dict(name='test-quality', passed=False)])
            (root / 'report.json').write_text(json.dumps(report))
            summary = dict(result='Passed', passedTests=1, failedTests=0, expectedFailures=0,
                           skippedTests=0, finishTime=1)
            tree = dict(testNodes=[dict(nodeType='Test Case', nodeIdentifier='A/testOne()', result='Passed')])
            with patch.object(quality, 'release_fingerprint', return_value='same'), \
                 patch.object(quality, 'extract_results', return_value=(summary, tree)):
                self.assertTrue(quality.load_release_run(root)['valid'])
                report['stages'][0]['passed'] = False
                (root / 'report.json').write_text(json.dumps(report))
                with self.assertRaisesRegex(ValueError, 'prerequisites'):
                    quality.load_release_run(root)

    def test_release_without_unit_and_ui_evidence_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'report.json').write_text(json.dumps(dict(status='CHECKING_QUALITY',
                sourceFingerprint='same', sourceUnchangedDuringRun=True,
                stages=[dict(name='release-build', passed=True)])))
            with patch.object(quality, 'release_fingerprint', return_value='same'):
                with self.assertRaisesRegex(ValueError, 'missing unit or iPhone'):
                    quality.load_release_run(root)

    def test_independent_audit_is_bound_to_retained_file_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'merged.pdf').write_bytes(b'output')
            (root / 'source-01.pdf').write_bytes(b'original')
            (root / 'sources.json').write_text(json.dumps(dict(sources=[dict(number=1, name='Original')])))
            report = dict(status='PASSED', outputs=[dict(retained_evidence=str(root),
                sha256=quality.sha(root / 'merged.pdf'),
                original_sha256={'Original': quality.sha(root / 'source-01.pdf')},
                pages=[dict(text_order=True, geometry=True, rendered_pixels_identical=True, annotations=True)])])
            self.assertTrue(quality.audit_valid(report))
            (root / 'merged.pdf').write_bytes(b'changed after audit')
            self.assertFalse(quality.audit_valid(report))

    def test_source_change_or_skipped_runtime_result_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'merge-report.json').write_text(json.dumps(dict(status='PASSED', test_exit=0)))
            for name in ['source-before.json', 'source-after.json']:
                (root / name).write_text(json.dumps({'source.swift': 'before'}))
            self.assertFalse(quality.load_run(root, {'source.swift': 'after'})['valid'])
            summary = dict(result='Passed', failedTests=0, expectedFailures=0, skippedTests=1, passedTests=1)
            tree = dict(testNodes=[dict(nodeType='Test Case', nodeIdentifier='A/testOne()', result='Skipped')])
            with patch.object(quality, 'extract_results', return_value=(summary, tree)):
                self.assertFalse(quality.load_run(root, {'source.swift': 'before'})['valid'])


class SwiftTestInventoryTests(unittest.TestCase):
    def test_extensions_retain_correct_class_and_ignore_literals_comments_nested_helpers(self):
        source = '''
final class First: XCTestCase {
    func testFirst() { let text = "func testFake() { }" }
    let raw = #"func testRawFake() { }"#
    // func testCommentFake() { }
    /* nested /* func testNestedComment() {} */ comment */
    struct Helper { func testNotXCTestMethod() {} }
}
final class Second: XCTestCase { func testSecond() {} }
extension First { func testFromExtension() {} }
'''
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'Tests.swift').write_text(source)
            self.assertEqual(set(inventory(directory)), {'First/testFirst()', 'Second/testSecond()', 'First/testFromExtension()'})

    def test_duplicate_declaration_is_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'Tests.swift').write_text('class A: XCTestCase { func testOne() {} }\nextension A { func testOne() {} }')
            with self.assertRaisesRegex(ValueError, 'Duplicate'):
                inventory(directory)

    def test_real_note_regressions_are_not_assigned_to_the_previous_class(self):
        tests = inventory(ROOT / 'PaperPathTests')
        self.assertIn('PDFCoreServiceRegressionTests/testMergePreservesNonstandardNoteRectangle()', tests)
        self.assertNotIn('PDFDocumentLifecycleTests/testMergePreservesNonstandardNoteRectangle()', tests)


if __name__ == '__main__':
    unittest.main()
