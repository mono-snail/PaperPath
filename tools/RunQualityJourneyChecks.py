#!/usr/bin/env python3
"""Run registered quality wrappers on the existing gated iPhone, then read files.
--feature selects standard+large-text cases. No network, phone, provisioning or AI.
"""
import argparse
import json
import hashlib
import os
import shutil
from pathlib import Path
import subprocess
import sys
import RunMergeChecks as evidence
import RunCompressionChecks as runner

if __name__ == '__main__':
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--feature')
    parser.add_argument('--reviewed-group', choices=['documents', 'quick'],
                        help='Replay reviewed quality UI scenarios from the fixed contract')
    selection, remaining = parser.parse_known_args()
    profiles = runner.ROOT / 'docs/QUALITY_JOURNEYS.json'
    if selection.reviewed_group:
        if selection.feature or '--test' in remaining:
            raise SystemExit('Choose a reviewed group, a feature, or explicit tests')
        policy = json.loads((runner.ROOT / 'docs/TEST_QUALITY_CONTRACT.json').read_text())
        references = {test for row in policy['scenarios'].values() if row.get('layer') == 'ui'
                      for test in row['tests'] if '/testQuality' in test}
        for test in sorted(references):
            document = 'testQualityDocument' in test or 'ProtectedPasswordFailure' in test
            if document == (selection.reviewed_group == 'documents'):
                remaining += ['--test', 'PaperPathUITests/' + test.removesuffix('()')]
    if selection.feature and '--test' not in remaining:
        profile = json.loads(profiles.read_text())['features'][selection.feature]
        for method in dict.fromkeys(filter(None, [profile['standard'], profile['largeText']])):
            remaining += ['--test', 'PaperPathUITests/PaperPathUITests/' + method]
    sys.argv = [sys.argv[0]] + remaining
    runner.OWNER = 'PaperPath/quality journey iteration'
    runner.TESTS = []
    if '--test' not in remaining:
        raise SystemExit('Choose --feature or explicit --test; no implicit full matrix')
    if '--leased' in sys.argv:
        approved = json.loads(runner.POOL.read_text())['slots'][runner.SLOT]['udid']
        if os.environ.get('CODEX_SIMULATOR_UDID') != approved:
            raise SystemExit('Offline input staging requires the assigned simulator lease')
        source_root = runner.ROOT / 'PaperPathTests/Fixtures/RealPDFCorpus'
        manifest = json.loads((source_root / 'manifest.json').read_text())
        destination = Path(evidence.application_data_container(approved)) / 'Documents/QualityInputCorpus'
        destination.mkdir(parents=True, exist_ok=True)
        for row in manifest['documents']:
            source = source_root / row['file']
            if hashlib.sha256(source.read_bytes()).hexdigest() != row['sha256']:
                raise SystemExit('Cached corpus hash mismatch; no download performed')
            target = destination / row['file']
            if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() != row['sha256']:
                raise SystemExit('Staged input differs; preserve it and investigate')
            if not target.exists(): shutil.copyfile(source, target)
        shutil.copyfile(source_root / 'manifest.json', destination / 'manifest.json')
    if '--leased' in sys.argv and any('testCoreImportPDFFromFiles' in arg for arg in sys.argv):
        import plistlib
        inventory = json.loads(subprocess.check_output(['xcrun','simctl','list','devices','--json'],text=True))
        device = next(d for group in inventory['devices'].values() for d in group if d['udid'] == approved)
        groups = Path(device['dataPath']) / 'Containers/Shared/AppGroup'
        providers = []
        for metadata in groups.glob('*/.com.apple.mobile_container_manager.metadata.plist'):
            with metadata.open('rb') as stream: identity = plistlib.load(stream).get('MCMMetadataIdentifier')
            if identity == 'group.com.apple.FileProvider.LocalStorage': providers.append(metadata.parent / 'File Provider Storage')
        if len(providers) != 1 or not providers[0].is_dir():
            raise SystemExit('Existing local Files provider is unavailable; no new device or fallback was created')
        folder = providers[0] / 'PaperPath Core Inputs'
        if folder.is_symlink(): raise SystemExit('External input folder is a symlink')
        folder.mkdir(exist_ok=True)
        row = next(row for row in manifest['documents'] if row['file']=='ocr-jbig2.pdf')
        source = source_root / row['file']; target = folder / row['file']
        if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest()!=row['sha256']:
            raise SystemExit('Preserve unexpected Files input; do not overwrite')
        if not target.exists(): shutil.copyfile(source,target)
        output = Path(sys.argv[sys.argv.index('--output')+1]); output.mkdir(parents=True,exist_ok=True)
        (output/'external-input-staging.json').write_text(json.dumps(dict(path=str(target),sha256=row['sha256']),indent=2)+'\n')
    before = evidence.source_manifest() if '--leased' in sys.argv else None
    result = runner.main()
    if '--leased' in sys.argv:
        output = Path(sys.argv[sys.argv.index('--output') + 1])
        bundle = output / 'Tests.xcresult'
        summary, tree = None, None
        if (bundle / 'Info.plist').exists():
            for kind, filename in [('summary', 'summary.json'), ('tests', 'test-tree.json')]:
                raw = subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path', str(bundle)])
                (output / filename).write_bytes(raw)
            summary = json.loads((output / 'summary.json').read_text())
            tree = json.loads((output / 'test-tree.json').read_text())
        audit_exit = None
        if result == 0:
            container = evidence.application_data_container(json.loads(runner.POOL.read_text())['slots'][runner.SLOT]['udid'])
            python = Path.home() / '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3'
            audit_exit = subprocess.call([str(python), str(runner.ROOT / 'tools/AuditQualitySession.py'),
                '--container', container, '--run', str(output), '--profiles', str(profiles)])
        external_unchanged = True
        staged = output / 'external-input-staging.json'
        if staged.exists():
            info = json.loads(staged.read_text())
            source = Path(info['path'])
            external_unchanged = source.exists() and hashlib.sha256(source.read_bytes()).hexdigest() == info['sha256']
        after = evidence.source_manifest()
        (output / 'source-before.json').write_text(json.dumps(before, indent=2) + '\n')
        (output / 'source-after.json').write_text(json.dumps(after, indent=2) + '\n')
        expected = sys.argv.count('--test')
        complete = summary and summary.get('result') == 'Passed' and summary.get('passedTests') == expected and summary.get('failedTests') == 0 and summary.get('skippedTests') == 0
        passed = result == 0 and audit_exit == 0 and complete and before == after and external_unchanged
        (output / 'quality-report.json').write_text(json.dumps(dict(status='PASSED' if passed else 'FAILED',
            test_exit=result, independent_audit_exit=audit_exit, summary=summary, external_input_unchanged=external_unchanged,
            source_changed_during_run=sorted(p for p in before.keys() | after.keys() if before.get(p) != after.get(p))), indent=2) + '\n')
        result = 0 if passed else 1
    raise SystemExit(result)
