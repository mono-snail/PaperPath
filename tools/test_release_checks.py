"""The release gate must never accept empty, filtered, skipped or failed runs."""
import unittest
from RunReleaseChecks import validate_results, test_inventory, partition_tests


class ReleaseGateTests(unittest.TestCase):
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

    def test_inventory_includes_release_and_commerce_tests(self):
        self.assertIn("ReleaseExperienceLogicTests/testOutputHistoryClampsCorruptCountsAndSaturates()",
                      test_inventory("PaperPathTests"))
        self.assertIn("ReleaseReadinessUITests/testPurchasePersistsAcrossProcessRelaunchAndRefundRevokesAccess()",
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
