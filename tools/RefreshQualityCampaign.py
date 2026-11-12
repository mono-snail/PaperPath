#!/usr/bin/env python3
"""Recompute current-source coverage from every retained campaign attempt, offline."""
import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--round', type=int, choices=range(1, 21), required=True)
    args = parser.parse_args()
    campaign = ROOT / '.artifacts/quality-20-rounds'
    output = campaign / f'round-{args.round:02d}'
    command = [sys.executable, str(ROOT / 'tools/CheckTestQuality.py'), '--output', str(output / 'metrics.json')]
    reports = {p.parent for name in ['quality-report.json', 'merge-report.json']
               for p in campaign.glob('round-*/runtime-*/' + name)}
    for directory in sorted(reports): command += ['--evidence', str(directory)]
    controls = output / 'oracle-controls.json'
    if controls.exists(): command += ['--oracle-evidence', str(controls)]
    return subprocess.call(command, cwd=ROOT)


if __name__ == '__main__':
    raise SystemExit(main())
