#!/usr/bin/env python3
"""Record an explicitly reviewed journey claim; execution is checked separately.
Never infers covered states/materials merely from a test name or generated wrapper.
"""
import argparse
import hashlib
import json
from pathlib import Path
from swift_test_inventory import inventory

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--feature', required=True)
    parser.add_argument('--assertion', required=True)
    parser.add_argument('--states', required=True)
    parser.add_argument('--materials', default='')
    parser.add_argument('--independent-output', action='store_true')
    args = parser.parse_args()
    path = ROOT / 'docs/TEST_QUALITY_CONTRACT.json'
    policy = json.loads(path.read_text())
    feature = policy['features'][args.feature]
    profile = json.loads((ROOT / 'docs/QUALITY_JOURNEYS.json').read_text())['features'][args.feature]
    states, materials = args.states.split(','), list(filter(None, args.materials.split(',')))
    if set(states) - set(feature['requiredStates']) or set(materials) - set(feature['requiredMaterials']):
        raise ValueError('Claim outside the fixed feature contract')
    if args.independent_output and profile.get('audit', 'notConfigured') == 'notConfigured':
        raise ValueError('Independent output claim needs an implemented validator')
    tests = inventory(ROOT / 'PaperPathUITests')
    ids = {}
    for suffix, method in [('standard', profile['standard']), ('large', profile['largeText'])]:
        test = 'PaperPathUITests/' + method + '()'
        source = Path(tests[test]['path'])
        key = 'journey.' + args.feature + '.' + suffix
        policy['scenarios'][key] = dict(tests=[test], assertion=args.assertion, layer='ui', features=[args.feature],
            reviewedSources={str(source.relative_to(ROOT)): hashlib.sha256(source.read_bytes()).hexdigest()})
        ids[suffix] = key
    feature['reviewStatus'] = 'reviewed'
    feature['states'].update({state: [ids['large' if state == 'largeText' else 'standard']] for state in states})
    feature['materials'].update({material: [ids['standard']] for material in materials})
    if args.independent_output: feature['independentOutput'] = dict(scenario=ids['standard'], audit='quality-session')
    path.write_text(json.dumps(policy, ensure_ascii=False, indent=2) + '\n')
    print('Recorded review; no execution credited:', args.feature)


if __name__ == '__main__': main()
