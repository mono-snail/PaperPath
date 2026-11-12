#!/usr/bin/env python3
"""Run the independent output validator's positive/negative controls, offline.
Use the bundled Python with pypdf/Pillow. Never installs dependencies.
"""
import argparse
import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RecordedResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.outcomes = {}

    def key(self, test):
        return f'{type(test).__name__}/{test._testMethodName}'

    def addSuccess(self, test):
        super().addSuccess(test)
        self.outcomes[self.key(test)] = 'Passed'

    def addFailure(self, test, error):
        super().addFailure(test, error)
        self.outcomes[self.key(test)] = 'Failed'

    def addError(self, test, error):
        super().addError(test, error)
        self.outcomes[self.key(test)] = 'Error'

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self.outcomes[self.key(test)] = 'Skipped'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    policy = json.loads((ROOT / 'docs/TEST_QUALITY_CONTRACT.json').read_text())
    before = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in policy['oracleSources']}
    suite = unittest.TestSuite([unittest.defaultTestLoader.discover(str(ROOT / 'tools'), pattern=pattern)
        for pattern in ['test_merge_output_audit.py', 'test_quality_session_audit.py']])
    result = unittest.TextTestRunner(resultclass=RecordedResult).run(suite)
    after = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in policy['oracleSources']}
    complete = set(result.outcomes) == set(policy['oracleTests'])
    passed = result.wasSuccessful() and not result.skipped and complete and before == after
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(status='PASSED' if passed else 'FAILED',
        outcomes=result.outcomes, sourceHashes=after, sourceUnchanged=before == after), indent=2) + '\n')
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
