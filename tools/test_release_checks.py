"""The release gate must never accept empty, filtered, skipped or failed runs."""
import unittest
from unittest.mock import patch
from RunReleaseChecks import validate_results, test_inventory, partition_tests, simulator_test_jobs, require_idle_simulator_tests, registered_session


class ReleaseGateTests(unittest.TestCase):
    def test_release_uses_one_registered_slot(self):
        pool = {'slots': {'ios26-phone': {'udid': 'phone'}, 'ios26-ipad': {'udid': 'pad'}}}
        self.assertEqual(registered_session('iphone', pool=pool), ('ios26-phone', 'phone'))
        self.assertEqual(registered_session('ipad', ipad='pad', pool=pool), ('ios26-ipad', 'pad'))
        for kwargs in [dict(iphone='new-device'), dict(iphone='phone', ipad='pad'), dict(ipad='pad')]:
            with self.assertRaises(ValueError): registered_session('iphone', pool=pool, **kwargs)
        with self.assertRaises(ValueError): registered_session('ipad', iphone='phone', pool=pool)

    def test_detects_other_xcode_test_jobs_and_ignores_builds(self):
        processes = "101 /Applications/Xcode.app/usr/bin/xcodebuild test -destination one\n102 /Applications/Xcode.app/usr/bin/xcodebuild -project P test-without-building\n103 /Applications/Xcode.app/usr/bin/xcodebuild build\n104 /bin/zsh -c xcodebuild test\n"
        with patch("RunReleaseChecks.subprocess.check_output", return_value=processes):
            self.assertEqual(simulator_test_jobs(), [101, 102])
            with self.assertRaisesRegex(RuntimeError, "busy"):
                require_idle_simulator_tests()

    def test_allows_idle_host_without_provisioning_a_device(self):
        with patch("RunReleaseChecks.subprocess.check_output", return_value="103 xcodebuild build\n"):
            self.assertEqual(simulator_test_jobs(), [])
            self.assertIsNone(require_idle_simulator_tests())

    def test_partition_runs_every_case_once(self):
        expected = {f"A/test{index}()" for index in range(89)}
        shards = partition_tests(expected, 2)
        flattened = [test for shard in shards for test in shard]
        self.assertEqual(set(flattened), expected)
        self.assertEqual(len(flattened), len(expected))
        self.assertEqual(partition_tests(expected, 2), shards)

    def test_partition_handles_small_inventory_without_empty_runs(self):
        self.assertEqual(partition_tests({"A/testOne()"}, 2), [["A/testOne()"]])
        with self.assertRaises(ValueError):
            partition_tests({"A/testOne()"}, 0)

    def validate(self, result="Passed", skipped=0, cases=None, **changes):
        summary = dict(result=result, passedTests=1, failedTests=0,
                       skippedTests=skipped, expectedFailures=0)
        summary.update(changes)
        tree = {"testNodes": cases if cases is not None else [
            {"nodeType": "Test Case", "nodeIdentifier": "A/testWorks()", "result": "Passed"}]}
        return validate_results(summary, tree, minimum=1, expected_tests={"A/testWorks()"})

    def test_accepts_complete_success(self):
        self.assertEqual(self.validate(), [])

    def test_rejects_xcode_success_with_no_tests(self):
        self.assertTrue(self.validate(cases=[], passedTests=0))

    def test_rejects_failed_and_expected_failure_runs(self):
        self.assertTrue(self.validate(result="Failed", failedTests=1))
        self.assertTrue(self.validate(expectedFailures=1))

    def test_rejects_unexpected_skips(self):
        self.assertTrue(self.validate(skipped=1, cases=[
            {"nodeType": "Test Case", "nodeIdentifier": "A/testWorks()", "result": "Skipped"}]))

    def test_rejects_summary_tree_mismatch(self):
        self.assertTrue(self.validate(skipped=1))
        self.assertTrue(self.validate(passedTests=2))

    def test_rejects_unexecuted_or_failed_case_with_green_summary(self):
        for outcome in ["Not Run", "Failed", "Expected Failure"]:
            self.assertTrue(self.validate(cases=[
                {"nodeType": "Test Case", "nodeIdentifier": "A/testWorks()", "result": outcome}]))

    def test_rejects_partial_execution_despite_passing_count(self):
        self.assertTrue(self.validate(cases=[
            {"nodeType": "Test Case", "nodeIdentifier": "A/testOther()", "result": "Passed"}]))

    def test_inventory_includes_release_and_paid_download_tests(self):
        self.assertIn("ReleaseExperienceLogicTests/testOutputHistoryClampsCorruptCountsAndSaturates()",
                      test_inventory("PaperPathTests"))
        self.assertIn("ReleaseReadinessUITests/testPaidDownloadHasNoTrialOrPurchaseFlow()",
                      test_inventory("PaperPathUITests"))

    def test_only_declared_device_skip_is_allowed(self):
        summary = dict(result="Passed", passedTests=1, skippedTests=1)
        tree = {"testNodes": [
            {"nodeType": "Test Case", "nodeIdentifier": "A/testDevice()", "result": "Skipped"},
            {"nodeType": "Test Case", "nodeIdentifier": "A/testWorks()", "result": "Passed"}]}
        self.assertEqual(validate_results(summary, tree, minimum=1,
                         allowed_skips={"A/testDevice()"},
                         expected_tests={"A/testDevice()", "A/testWorks()"}), [])


if __name__ == "__main__":
    unittest.main()
