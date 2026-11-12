#!/usr/bin/env python3
"""Offline merge UI regressions. Reuse the registered iOS 26 iPhone and shared gate.

Default compiles only. --runtime executes programmatic XCTest, then verifies
actual UI-produced PDFs independently using pypdf. No screenshot AI or downloads.
"""
import json
import hashlib
import plistlib
from pathlib import Path
import subprocess
import sys
import RunCompressionChecks as runner

runner.OWNER = 'PaperPath/merge corpus UI regression'
runner.TESTS = [
    'PaperPathTests/PDFCoreServiceRegressionTests/testCombine_twoHundredPagesUsesBoundedMemory_BitsUT',
    'PaperPathTests/PDFCoreServiceRegressionTests/testMergePreservesNonstandardNoteRectangle',
    'PaperPathTests/PDFCoreServiceRegressionTests/testExtractionPreservesNonstandardNoteRectangle',
] + [
    'PaperPathUITests/PaperPathUITests/' + name for name in [
        'testMergeCorpusStressAndEmbeddedAttachmentPreserveActualOutput',
        'testMergeCorpusDamagedSourceFailsThenValidSelectionRecovers',
        'testMergeCorpusLockedSourceIsDisabledAndValidSourcesStillMerge',
        'testMergeCorpusSevenSequentialAddsAndClear',
        'testMergeCorpusRemoveReaddAndCancelIsolation',
        'testMergeCorpusSearchNoMatchAndAddMatching',
        'testMergeCorpusLargeTextRetainsLibraryAfterSecondAndThird',
        'testMergeCorpusMixedOutputSurvivesRelaunch',
        'testMergePDFJourneyCreatesNamedResultAfterCancelAndReentry',
    ]
]

def application_data_container(udid):
    # simctl get_app_container requires a booted device. Read its existing
    # container metadata after shutdown, without booting it again for auditing.
    inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '--json'], text=True))
    device = next(d for group in inventory['devices'].values() for d in group if d['udid'] == udid)
    applications = Path(device['dataPath']) / 'Containers/Data/Application'
    matches = []
    for path in applications.glob('*/.com.apple.mobile_container_manager.metadata.plist'):
        with path.open('rb') as stream:
            metadata = plistlib.load(stream)
        if metadata.get('MCMMetadataIdentifier') == 'com.monoware.paperpath':
            matches.append(path.parent)
    if len(matches) != 1:
        raise RuntimeError('Expected exactly one existing PaperPath data container')
    return str(matches[0])


def source_manifest():
    paths = [p for folder in ['PaperPath', 'PaperPathTests', 'PaperPathUITests', 'PaperPathShareExtension']
             for p in (runner.ROOT / folder).rglob('*')
             if p.is_file() and p.suffix in ['.swift', '.strings', '.plist', '.entitlements']]
    paths += [runner.ROOT / 'PaperPath.xcodeproj/project.pbxproj', runner.ROOT / 'project.yml']
    return {str(p.relative_to(runner.ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}


if __name__ == '__main__':
    corpus_root = runner.ROOT / 'PaperPathTests/Fixtures/RealPDFCorpus'
    entry = next(row for row in json.loads((corpus_root / 'manifest.json').read_text())['documents']
                 if row['file'] == 'ocr-jbig2.pdf')
    data = (corpus_root / entry['file']).read_bytes()
    if len(data) != entry['bytes'] or hashlib.sha256(data).hexdigest() != entry['sha256']:
        raise SystemExit('Cached merge scan missing/changed; no download or replacement performed')
    before = source_manifest() if '--leased' in sys.argv else None
    result = runner.main()
    # This branch remains inside the inherited foreground lease. The base
    # runner shuts down only this session's device before returning.
    if '--leased' in sys.argv:
        output = Path(sys.argv[sys.argv.index('--output') + 1])
        bundle = output / 'Tests.xcresult'
        summary = None
        if (bundle / 'Info.plist').exists():
            raw = subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(bundle)])
            (output / 'summary.json').write_bytes(raw)
            summary = json.loads(raw)
        audit = None
        # Focused --test selections are useful for diagnosis, but must not
        # pretend to have produced and audited the complete output journey.
        if result == 0 and ('--test' not in sys.argv or any(name in sys.argv for name in [
            'PaperPathUITests/PaperPathUITests/testMergeCorpusStressAndEmbeddedAttachmentPreserveActualOutput',
            'PaperPathUITests/PaperPathUITests/testMergeCorpusDamagedSourceFailsThenValidSelectionRecovers',
            'PaperPathUITests/PaperPathUITests/testMergeCorpusMixedOutputSurvivesRelaunch'])):
            attachments = output / 'attachments'
            subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(bundle),
                '--output-path', str(attachments)], check=True, stdout=subprocess.DEVNULL)
            container = application_data_container(json.loads(runner.POOL.read_text())['slots'][runner.SLOT]['udid'])
            python = Path.home() / '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3'
            audit = subprocess.call([str(python), str(runner.ROOT / 'tools/AuditMergeOutputs.py'),
                '--attachments', str(attachments), '--container', container,
                '--output', str(output / 'independent-merge-audit.json')])
        after = source_manifest()
        changed = sorted(key for key in before.keys() | after.keys() if before.get(key) != after.get(key))
        (output / 'source-before.json').write_text(json.dumps(before, indent=2) + '\n')
        (output / 'source-after.json').write_text(json.dumps(after, indent=2) + '\n')
        expected_count = sys.argv.count('--test') or len(runner.TESTS)
        iterations = int(sys.argv[sys.argv.index('--iterations') + 1]) if '--iterations' in sys.argv else 1
        complete = (summary is not None and summary.get('failedTests') == 0
                    and summary.get('skippedTests') == 0
                    and summary.get('passedTests') == expected_count * iterations)
        passed = result == 0 and audit in [None, 0] and not changed and complete
        (output / 'merge-report.json').write_text(json.dumps(dict(
            status='PASSED' if passed else 'FAILED', test_exit=result,
            independent_audit_exit=audit, summary=summary, source_changed_during_run=changed,
            scope='focused selection' if '--test' in sys.argv else 'memory plus note regressions, nine merge UI regressions and saved PDF audits',
            simulator_slot=runner.SLOT, network_downloads=0), indent=2) + '\n')
        result = 0 if passed else 1
    raise SystemExit(result)
