#!/usr/bin/env python3
"""Run only the named core paths, serially through existing shared-pool runners."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', action='store_true', help='Run the existing ios26-phone; never provision devices')
    parser.add_argument('--evidence', type=Path, action='append', default=[])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=not args.runtime)
    evidence = list(args.evidence)
    if args.runtime:
        policy = json.loads((ROOT/'docs/CORE_PATH_CONTRACT.json').read_text())
        groups = {'quality': [], 'merge': []}
        for row in policy['paths']:
            for case in row['cases']:
                ref = 'PaperPathUITests/' + case['test'].removesuffix('()')
                if ref not in groups[case['runner']]: groups[case['runner']].append(ref)
        # These two unit tests guard the form-value fix, not UI coverage.
        groups['merge'] += ['PaperPathTests/RealPDFReleaseTests/'+name for name in [
            'testCoreTextFormSavePreservesPagesAndOtherFields',
            'testCoreTextFormRejectsOversizedAndReadOnlyValuesWithoutChangingFile']]
        outcomes = {}
        for group, refs in groups.items():
            directory = output/group
            runner = 'RunQualityJourneyChecks.py' if group=='quality' else 'RunMergeChecks.py'
            command = [sys.executable,str(ROOT/'tools'/runner),'--runtime','--output',str(directory)]
            for ref in refs: command += ['--test',ref]
            outcomes[group] = subprocess.call(command,cwd=ROOT)
            evidence.append(directory)
            (output/'execution.json').write_text(json.dumps(outcomes,indent=2)+'\n')
    command = [sys.executable,str(ROOT/'tools/CheckCorePaths.py'),'--output',str(output/'core-report.json')]
    for directory in evidence: command += ['--evidence',str(directory.resolve())]
    return subprocess.call(command,cwd=ROOT)


if __name__=='__main__': raise SystemExit(main())
