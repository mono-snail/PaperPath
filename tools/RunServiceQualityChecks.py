#!/usr/bin/env python3
"""Record explicit service XCTest methods with current-source evidence, one pool lease.
Service assertions never substitute for UI journeys or independent output oracles.
"""
import json
from pathlib import Path
import subprocess
import sys
import RunCompressionChecks as runner
from RunMergeChecks import source_manifest
from CheckTestQuality import test_cases


if __name__ == '__main__':
    if '--test' not in sys.argv: raise SystemExit('Explicit service methods required; no implicit full suite')
    runner.OWNER = 'PaperPath/quality service regressions'
    before = source_manifest() if '--leased' in sys.argv else None
    result = runner.main()
    if '--leased' in sys.argv:
        output = Path(sys.argv[sys.argv.index('--output') + 1])
        bundle = output / 'Tests.xcresult'
        summary, tree = {}, {}
        if (bundle / 'Info.plist').exists():
            for kind, filename in [('summary', 'summary.json'), ('tests', 'test-tree.json')]:
                raw = subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path', str(bundle)])
                (output / filename).write_bytes(raw)
            summary = json.loads((output / 'summary.json').read_text())
            tree = json.loads((output / 'test-tree.json').read_text())
        after = source_manifest()
        for name, manifest in [('before', before), ('after', after)]:
            (output / f'source-{name}.json').write_text(json.dumps(manifest, indent=2) + '\n')
        expected = {sys.argv[i+1].split('/', 1)[1] + '()' for i, arg in enumerate(sys.argv) if arg == '--test'}
        cases = list(test_cases(tree))
        complete = (summary.get('result') == 'Passed' and summary.get('passedTests') == len(expected)
            and summary.get('failedTests') == 0 and summary.get('skippedTests') == 0
            and summary.get('expectedFailures') == 0 and len(cases) == len(expected)
            and {c.get('nodeIdentifier') for c in cases} == expected and all(c.get('result') == 'Passed' for c in cases))
        passed = result == 0 and complete and before == after
        (output / 'quality-report.json').write_text(json.dumps(dict(status='PASSED' if passed else 'FAILED',
            test_exit=result, summary=summary, independent_audit_exit=None, evidenceLayer='service',
            source_changed_during_run=sorted(p for p in before.keys() | after.keys() if before.get(p) != after.get(p))), indent=2) + '\n')
        result = 0 if passed else 1
    raise SystemExit(result)
