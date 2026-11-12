#!/usr/bin/env python3
"""A separate, explicit core-path gate; never relax the full quality contract."""
import argparse
import hashlib
import json
from pathlib import Path
from CheckTestQuality import load_run, runtime_sources, independent_for
from swift_test_inventory import inventory

ROOT = Path(__file__).resolve().parents[1]


def evaluate(policy, runs, known):
    assert policy['targetPercent'] == 100 and policy['paths'], 'Core target must be 100%'
    rows = []
    for path in policy['paths']:
        assert path['cases'], 'Core path cannot have an empty test set'
        cases = []
        for case in path['cases']:
            assert case['test'] in known, 'Missing core UI test: ' + case['test']
            matches = [run for run in runs if run['valid'] and run.get('sourceCurrent') is True and case['test'] in run['tests']
                and (not case['requiresOutputAudit'] or independent_for(run, case['feature'], [case['test']]))]
            cases.append(dict(**case, passed=bool(matches), evidence=[run['path'] for run in matches]))
        rows.append(dict(id=path['id'], title=path['title'], passed=all(c['passed'] for c in cases), cases=cases))
    passed = sum(row['passed'] for row in rows)
    return dict(status='CORE_PATHS_PASSED' if passed == len(rows) else 'CORE_GAPS',
        passed=passed, required=len(rows), paths=rows, manualGates=policy['manualGates'],
        scope=policy['scope'], limitation='One current-source execution proves only these named paths; it is not a release or repeated-stability result.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, action='append', default=[])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    current = runtime_sources(ROOT)
    runs = [load_run(p.resolve(), current) for p in sorted(set(args.evidence))]
    report = evaluate(json.loads((ROOT/'docs/CORE_PATH_CONTRACT.json').read_text()), runs,
        inventory(ROOT/'PaperPathUITests'))
    report['contractSHA256'] = hashlib.sha256((ROOT/'docs/CORE_PATH_CONTRACT.json').read_bytes()).hexdigest()
    report['runtimeSourcesSHA256'] = hashlib.sha256(json.dumps(current,sort_keys=True).encode()).hexdigest()
    report['rejectedRuns'] = [{k:v for k,v in run.items() if k in {'path','error','sourceCurrent','valid'}}
        for run in runs if not run['valid']]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    args.output.with_suffix('.txt').write_text('\n'.join([
        f"{report['status']}: {report['passed']}/{report['required']}",
        *[f"{'PASS' if row['passed'] else 'GAP'} {row['title']}" for row in report['paths']],
        '',report['limitation'],'人工/未包含：',*report['manualGates']])+'\n')
    print(report['status'],f"{report['passed']}/{report['required']}")
    return 0 if report['status']=='CORE_PATHS_PASSED' else 1


if __name__ == '__main__': raise SystemExit(main())
