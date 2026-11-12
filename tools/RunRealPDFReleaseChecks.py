#!/usr/bin/env python3
"""Reproducible real-PDF release gate using the registered simulator pool.

--runtime: all unit tests, including original internet PDFs.
--ui: also all functional Journey tests plus the three downloaded-PDF UI cases.
No test-time downloads. FetchRealPDFCorpus.py is a separate, bounded opt-in step.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ANALYSIS_PYTHON = Path.home() / '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3'


def source_manifest():
    paths = [p for folder in ['PaperPath', 'PaperPathTests', 'PaperPathUITests', 'PaperPathShareExtension']
             for p in (ROOT / folder).rglob('*') if p.is_file() and p.suffix in ['.swift', '.strings', '.plist', '.entitlements']]
    paths += [ROOT / 'project.yml', ROOT / 'PaperPath.xcodeproj/project.pbxproj']
    paths += [ROOT / 'tools' / name for name in ['RunRealPDFReleaseChecks.py', 'AuditRealPDFOutputs.py', 'RunCompressionChecks.py', 'FetchRealPDFCorpus.py']]
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', action='store_true')
    parser.add_argument('--ui', action='store_true')
    parser.add_argument('--ui-test', action='append', default=[], help='Additional UI method to retest with all unit tests')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--analysis-python', type=Path, default=ANALYSIS_PYTHON)
    args = parser.parse_args()
    output = (args.output or ROOT / '.artifacts' / ('real-pdf-release-' + datetime.now().strftime('%Y%m%d-%H%M%S'))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Verification reuses downloads and fails on missing/changed originals.
    manifest = json.loads((ROOT / 'PaperPathTests/Fixtures/RealPDFCorpus/manifest.json').read_text())['documents']
    for row in manifest:
        data = (ROOT / 'PaperPathTests/Fixtures/RealPDFCorpus' / row['file']).read_bytes()
        if len(data) != row['bytes'] or hashlib.sha256(data).hexdigest() != row['sha256']:
            raise RuntimeError('Missing or changed corpus file: ' + row['file'])
    before = source_manifest()
    (output / 'source-before.json').write_text(json.dumps(before, indent=2) + '\n')
    command = [sys.executable, str(ROOT / 'tools/RunCompressionChecks.py'), '--output', str(output)]
    tests = ['PaperPathTests']
    if args.ui:
        ui_source = (ROOT / 'PaperPathUITests/PaperPathUITests.swift').read_text()
        names = re.findall(r'func (test\w*Journey\w*)\s*\(', ui_source)
        names += re.findall(r'func (testMergeCorpus\w*)\s*\(', ui_source)
        names += ['testDownloadedPDFMergeAndSplit', 'testDownloadedPDFCompressionAndProtection', 'testDownloadedPDFOCR',
                  'testCompressionMethodsRemainActionableWithAdvisoryEstimate']
        tests += ['PaperPathUITests/PaperPathUITests/' + name for name in names]
    tests += ['PaperPathUITests/PaperPathUITests/' + name for name in args.ui_test]
    if args.runtime or args.ui or args.ui_test:
        command += ['--runtime']
        for test in tests:
            command += ['--test', test]
    (output / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
    result = subprocess.call(command, cwd=ROOT)
    summary = None
    audit_result = None
    if args.runtime or args.ui or args.ui_test:
        xcresult = output / 'Tests.xcresult'
        if (xcresult / 'Info.plist').exists():
            summary_raw = subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(xcresult)])
            (output / 'test-summary.json').write_bytes(summary_raw)
            summary = json.loads(summary_raw)
            with (output / 'export.log').open('w') as log:
                export_result = subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--test-id', 'RealPDFReleaseTests',
                                '--path', str(xcresult), '--output-path', str(output / 'outputs')], stdout=log, stderr=subprocess.STDOUT)
            if export_result.returncode != 0:
                audit_result = export_result.returncode
            else:
                with (output / 'independent-audit.log').open('w') as log:
                    audit_result = subprocess.call([str(args.analysis_python), str(ROOT / 'tools/AuditRealPDFOutputs.py'),
                    '--attachments', str(output / 'outputs'), '--output', str(output / 'independent-audit.json')],
                    stdout=log, stderr=subprocess.STDOUT, cwd=ROOT)
    after = source_manifest()
    (output / 'source-after.json').write_text(json.dumps(after, indent=2) + '\n')
    changed = sorted(key for key in before.keys() | after.keys() if before.get(key) != after.get(key))
    status = 'AUTOMATED_CHECKS_PASSED_PHYSICAL_CHECK_PENDING' if result == 0 and audit_result in [None, 0] and not changed else 'FAILED'
    report = dict(status=status, test_exit=result, independent_audit_exit=audit_result, selected_test_identifiers=tests,
                  source_changed_during_run=changed, summary=summary, corpus=manifest,
                  limitations=['Real camera, physical-device file protection, and TestFlight distribution are not validated by simulator tests.'])
    (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(status, '—', output / 'report.json')
    return 0 if status.startswith('AUTOMATED_CHECKS_PASSED') else 1


if __name__ == '__main__':
    raise SystemExit(main())
