#!/usr/bin/env python3
"""Compile or run the PDF compression regressions using the existing shared pool.

Default: generic iOS compilation (no device). --runtime: one registered iPhone,
under the foreground global lease, preserving device data. No provisioning.
"""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
POOL = Path('/Users/yanjun/.codex/simulators/pool.json')
GUARD = POOL.with_name('guard.py')
SLOT = 'ios26-phone'
OWNER = 'PaperPath/PDF compression regression'
TESTS = [
    'PaperPathTests/PDFCompressionDepthTests',
    'PaperPathTests/PDFCoreServiceRegressionTests/testCompressionEstimate_sixtyPagesSamplesThree_BitsUT',
    'PaperPathTests/PDFCoreServiceRegressionTests/testCompression_fortyPagesUsesBoundedMemory_BitsUT',
    'PaperPathTests/PDFCriticalFeatureContractTests/testModel_cancelledCompressionReleasesProcessingState_BitsUT',
    'PaperPathTests/PaperPathTests/testCompressionCreatesSeparateSmallerReadablePDF',
    'PaperPathTests/PaperPathTests/testCompressionDoesNotPublishCopyLargerThanSource',
    'PaperPathTests/PaperPathTests/testImageObjectReplacementRemovesOriginalJPEGBytes',
    'PaperPathTests/PaperPathTests/testSharedImageObjectReplacementUpdatesEveryUse',
    'PaperPathTests/PaperPathTests/testXRefStreamImageReplacementRebuildsWithoutOldBytes',
    'PaperPathTests/PaperPathTests/testEmbeddedImageExportPreservesBytesAndDeduplicatesUses',
    'PaperPathTests/PaperPathTests/testEmbeddedImageExportDecodesFlateSoftMaskInsideForm',
    'PaperPathTests/ServicePureLogicCoverageTests/testMutationXRefAndInvisibleTextUtilities_BitsUT',
    'PaperPathTests/ServicePureLogicCoverageTests/testTextReplacementGuardMatrixAndXRefStreamRoundTrip_BitsUT',
    'PaperPathUITests/PaperPathUITests/testCompressionMethodsRemainActionableWithAdvisoryEstimate',
    'PaperPathUITests/PaperPathUITests/testCompressPDFQuickJourneyKeepsAlreadySmallerOriginal',
    'PaperPathUITests/PaperPathUITests/testCompressJourneyExplainsAlreadySmallerOriginalAfterReentry',
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', action='store_true')
    parser.add_argument('--iterations', type=int, choices=range(1, 4), default=1, help='Sequential repetitions on the same registered device')
    parser.add_argument('--test', action='append', help='Run only a named XCTest identifier (repeatable)')
    parser.add_argument('--leased', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    output = (args.output or ROOT / '.artifacts' / ('compression-qa-' + datetime.now().strftime('%Y%m%d-%H%M%S'))).resolve()
    if args.runtime and not args.leased:
        # Read the registry before runtime work; guard owns admission and the
        # complete foreground child, including final shutdown.
        json.loads(POOL.read_text())['slots'][SLOT]
        subprocess.run([sys.executable, str(GUARD), 'status'], check=True)
        return subprocess.call([sys.executable, str(GUARD), 'run', '--slot', SLOT,
            '--owner', OWNER, '--', sys.executable,
            str(Path(sys.argv[0]).resolve()), '--leased', '--output', str(output), '--iterations', str(args.iterations)]
            + [item for test in (args.test or []) for item in ['--test', test]], cwd=ROOT)
    output.mkdir(parents=True, exist_ok=True)
    command = ['xcodebuild', '-project', 'PaperPath.xcodeproj', '-scheme', 'PaperPath',
        '-derivedDataPath', str(ROOT / '.artifacts' / ('compression-simulator-build' if args.leased else 'compression-build'))]
    if args.leased:
        approved = json.loads(POOL.read_text())['slots'][SLOT]['udid']
        if os.environ.get('CODEX_SIMULATOR_UDID') != approved:
            raise RuntimeError('Runtime checks require the shared lease for the assigned existing UDID')
        inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '--json'], text=True))
        selected = next(d for devices in inventory['devices'].values() for d in devices if d['udid'] == approved)
        if selected['state'] != 'Shutdown':
            raise RuntimeError('Assigned device is already booted; investigate ownership before running')
        command += ['-destination', 'platform=iOS Simulator,id=' + approved,
            '-parallel-testing-enabled', 'NO', '-maximum-concurrent-test-simulator-destinations', '1',
            '-maximum-parallel-testing-workers', '1', '-collect-test-diagnostics', 'never',
            '-resultBundlePath', str(output / 'Tests.xcresult')]
        command += ['-only-testing:' + test for test in (args.test or TESTS)]
        if args.iterations > 1:
            command += ['-test-iterations', str(args.iterations)]
        command += ['-test-timeouts-enabled', 'YES',
            '-default-test-execution-time-allowance', '240',
            '-maximum-test-execution-time-allowance', '360', 'test']
    else:
        command += ['-destination', 'generic/platform=iOS', 'CODE_SIGNING_ALLOWED=NO', 'build']
    log = output / ('tests.log' if args.leased else 'build.log')
    print('Log:', log, flush=True)
    try:
        with log.open('w') as stream:
            result = subprocess.call(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
    finally:
        if args.leased:
            subprocess.run(['xcrun', 'simctl', 'shutdown', approved], check=False, capture_output=True)
    print('Passed' if result == 0 else 'Failed', '— see', log, flush=True)
    return result


if __name__ == '__main__':
    raise SystemExit(main())
