#!/usr/bin/env python3
"""Persistent limit for the user-authorized 20 quality iterations.
A round is one substantive gap/review package, not a tool call. Failed attempts
remain recorded; at most three simulator invocations per round. No simulator API.
"""
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
LEDGER = ROOT / 'docs/QUALITY_20_ROUNDS.json'
ARTIFACTS = ROOT / '.artifacts/quality-20-rounds'


def targets():
    policy = json.loads((ROOT / 'docs/TEST_QUALITY_CONTRACT.json').read_text())
    return dict(targetPercent=policy['policy']['targetPercent'], stableRunsRequired=policy['policy']['stableRunsRequired'],
        features={name: {key: entry[key] for key in ['priority', 'requiredStates', 'requiredMaterials', 'independentOutputRequired']}
                  for name, entry in policy['features'].items()},
        defectIDs=[row['id'] for row in policy['defects']], oracleTests=policy['oracleTests'],
        oraclePositiveControls=policy.get('oraclePositiveControls', ['MergeOutputAuditTests/test_correct_output_passes']))


def update(action, title='', evidence=(), metrics=None, outcome=None, note=''):
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    with (ARTIFACTS / 'ledger.lock').open('a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = json.loads(LEDGER.read_text()) if LEDGER.exists() else dict(
            schemaVersion=1, maximumRounds=20, maximumSimulatorAttemptsPerRound=3,
            status='ACTIVE', targets=targets(), rounds=[])
        fresh_targets = targets()
        fixed = lambda definition: {key: value for key, value in definition.items()
            if key not in {'defectIDs', 'oracleTests', 'oraclePositiveControls'}}
        known_tests = set(current['targets'].get('oracleTests', []))
        positives = lambda definition: set(definition.get('oraclePositiveControls', ['MergeOutputAuditTests/test_correct_output_passes']))
        obligations_preserved = fixed(current['targets']) == fixed(fresh_targets) and all(
            set(fresh_targets.get(key, [])) >= set(current['targets'].get(key, [])) for key in ['defectIDs', 'oracleTests']) and (
            positives(current['targets']) & known_tests == positives(fresh_targets) & known_tests)
        if current['maximumRounds'] != 20 or not obligations_preserved:
            raise ValueError('The agreed targets or 20-round ceiling changed; do not silently relax them')
        stamp = datetime.now(timezone.utc).isoformat()
        rounds = current['rounds']
        active = rounds[-1] if rounds and rounds[-1]['status'] == 'RUNNING' else None
        if action == 'begin':
            if active or len(rounds) >= 20 or current['status'] != 'ACTIVE':
                raise ValueError('An unfinished round or the iteration ceiling prevents another start')
            number = len(rounds) + 1
            folder = ARTIFACTS / f'round-{number:02d}'
            folder.mkdir(exist_ok=False)
            if metrics: shutil.copyfile(metrics, folder / 'metrics-before.json')
            rounds.append(dict(number=number, title=title, status='RUNNING', startedAt=stamp,
                simulatorAttempts=[], evidence=[], artifactDirectory=str(folder)))
        elif action == 'attempt':
            if not active or len(active['simulatorAttempts']) >= 3:
                raise ValueError('No active round or the three-attempt simulator ceiling was reached')
            active['simulatorAttempts'].append(dict(at=stamp, command=note))
        elif action == 'finish':
            if not active or outcome not in {'VERIFIED_WITH_GAPS', 'FAILED', 'TARGETS_MET'}:
                raise ValueError('A round must have an explicit outcome')
            if metrics:
                report = json.loads(Path(metrics).read_text())
                shutil.copyfile(metrics, Path(active['artifactDirectory']) / 'metrics-after.json')
                active['metrics'] = report['metrics']
                if outcome == 'TARGETS_MET' and (report['status'] != 'TARGETS_MET' or
                    {row['feature'] for row in report.get('features', [])} != set(current['targets']['features'])):
                    raise ValueError('Cannot declare target achievement from incomplete metrics')
            elif outcome == 'TARGETS_MET':
                raise ValueError('Target achievement requires a current quality report')
            active.update(status=outcome, finishedAt=stamp, evidence=list(evidence), note=note)
            if outcome == 'TARGETS_MET': current['status'] = 'TARGETS_MET'
            elif len(rounds) == 20: current['status'] = 'LIMIT_REACHED_USER_VERIFICATION'
        elif action != 'status':
            raise ValueError('Unknown ledger action')
        # Newly discovered defects and new controls become permanent obligations,
        # rather than being compared only against the first round's smaller list.
        current['targets'] = fresh_targets
        current['updatedAt'] = stamp
        temporary = LEDGER.with_suffix('.json.tmp')
        temporary.write_text(json.dumps(current, ensure_ascii=False, indent=2) + '\n')
        temporary.replace(LEDGER)
        return dict(status=current['status'], started=len(rounds), completed=sum(r['status'] != 'RUNNING' for r in rounds),
                    remaining=20-len(rounds), active=rounds[-1] if rounds else None)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['begin', 'attempt', 'finish', 'status'])
    parser.add_argument('--title', default='')
    parser.add_argument('--metrics', type=Path)
    parser.add_argument('--evidence', action='append', default=[])
    parser.add_argument('--outcome', choices=['VERIFIED_WITH_GAPS', 'FAILED', 'TARGETS_MET'])
    parser.add_argument('--note', default='')
    args = parser.parse_args()
    print(json.dumps(update(args.action, args.title, args.evidence, args.metrics, args.outcome, args.note), ensure_ascii=False, indent=2))
