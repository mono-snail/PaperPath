#!/usr/bin/env python3
"""Serial review checks; run only when runtime checks are enabled by the user,
and only as the foreground command of the shared simulator guard.
Uses existing isolated XCTest document stores; never erases simulator data.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
from CheckTestQuality import runtime_sources


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True)
    parser.add_argument('--ipad', action='store_true')
    parser.add_argument('--only', action='append')
    parser.add_argument('--status-time')
    parser.add_argument('--stage-offline-inputs', action='store_true')
    args = parser.parse_args()
    pool = json.loads(Path('/Users/yanjun/.codex/simulators/pool.json').read_text())
    udid = os.environ.get('CODEX_SIMULATOR_UDID')
    slot = 'ios26-ipad' if args.ipad else 'ios26-phone'
    if udid != pool['slots'][slot]['udid']:
        raise SystemExit('Requires shared guard lease for ' + slot)
    output = Path(args.output).resolve()
    if output.exists():
        raise SystemExit('Choose a new output directory to preserve earlier evidence')
    output.mkdir(parents=True)
    root = Path(__file__).resolve().parents[1]
    source_hashes = runtime_sources(root)
    (output/'source-before.json').write_text(json.dumps(source_hashes, indent=2)+'\n')
    inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '--json']))
    device = next(d for group in inventory['devices'].values() for d in group if d['udid'] == udid)
    booted_here = device['state'] != 'Booted'
    node = '/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node'
    command = [
        'xcodebuild', 'test', '-project', 'PaperPath.xcodeproj', '-scheme', 'PaperPath',
        '-configuration', 'Debug', '-destination', f'platform=iOS Simulator,id={udid}',
        '-parallel-testing-enabled', 'NO', '-maximum-concurrent-test-simulator-destinations', '1',
        '-maximum-parallel-testing-workers', '1', '-disableAutomaticPackageResolution', '-skipPackageUpdates',
        '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '240',
        '-maximum-test-execution-time-allowance', '900', '-collect-test-diagnostics', 'never',
        '-derivedDataPath', 'output/handoff-20261104/DerivedData',
        '-resultBundlePath', str(output/'Tests.xcresult'),
        'ONLY_ACTIVE_ARCH=YES', 'ARCHS=arm64', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG PAPERPATH_REVIEW_BUILD',
        '-only-testing:PaperPathUITests/PaperPathUITests/testShareCheckJourneyCompletesFictionalSampleAfterCancelAndReentry',
        '-only-testing:PaperPathUITests/PaperPathUITests/testShareCheckEntryUsesExistingPDFAndChineseLargeTextLayout',
        '-only-testing:PaperPathTests/PrivacyRedactionShareTests',
        '-only-testing:PaperPathTests/PrivacyScanServiceTests',
        '-only-testing:PaperPathTests/PaperPathTests/testSafeShareAuditVerifiesEveryPageAndFingerprint',
        '-only-testing:PaperPathTests/PaperPathTests/testDeliveryAuditRejectsMissingOutputPage',
        '-only-testing:PaperPathTests/PaperPathTests/testStorePersistsDeliveryReceipt',
        '-only-testing:PaperPathTests/PaperPathTests/testSecureRedactionRemovesUnderlyingTextLayer',
        '-only-testing:PaperPathUITests/PaperPathUITests/testPrivacyScanJourneyCreatesManagedVerifiedCopyAfterCancelAndReentry',
        '-only-testing:PaperPathUITests/PaperPathUITests/testSafeShareQuickJourneyCreatesVerifiedCopyAfterCancelAndReentry',
        '-only-testing:PaperPathUITests/ReleaseReadinessUITests/testPaidDownloadHasNoTrialOrPurchaseFlow',
        '-only-testing:PaperPathUITests/ReleaseReadinessUITests/testSettingsPrivacyInformationAndActualVersion',
    ]
    if args.ipad:
        command = [item for item in command if not item.startswith('-only-testing:')]
        command += ['-only-testing:PaperPathUITests/PaperPathUITests/testShareCheckJourneyCompletesFictionalSampleAfterCancelAndReentry',
                    '-only-testing:PaperPathUITests/PaperPathUITests/testSafeShareQuickJourneyCreatesVerifiedCopyAfterCancelAndReentry',
                    '-only-testing:PaperPathUITests/PaperPathUITests/testShareCheckEntryUsesExistingPDFAndChineseLargeTextLayout']
    if args.only:
        command = [item for item in command if not item.startswith('-only-testing:')]
        command += ['-only-testing:' + name for name in args.only]
    (output/'command.json').write_text(json.dumps(command, indent=2)+'\n')
    set_status = False
    try:
        subprocess.run([node, 'tools/CheckAutomationCoverage.mjs'], check=True)
        if booted_here:
            subprocess.run(['xcrun', 'simctl', 'boot', udid], check=True)
        subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True)
        if args.stage_offline_inputs:
            from StageCachedUIInputs import stage
            stage(root, output/'offline-input-staging.json')
        if args.status_time:
            prior = subprocess.check_output(['xcrun', 'simctl', 'status_bar', udid, 'list'], text=True)
            (output/'status-bar-before.txt').write_text(prior)
            prior_values = '\n'.join(line for line in prior.splitlines()
                                     if line.strip() != 'Current Status Bar Overrides:'
                                     and not (line.strip() and set(line.strip()) == {'='})).strip()
            if prior_values not in ['', '{}', 'null']:
                raise SystemExit('Existing status-bar overrides found; preserve them and inspect before changing')
            subprocess.run(['xcrun', 'simctl', 'status_bar', udid, 'override', '--time', args.status_time], check=True)
            set_status = True
        with (output/'tests.log').open('w') as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
        container = subprocess.run(['xcrun', 'simctl', 'get_app_container', udid,
            'com.monoware.paperpath', 'data'], capture_output=True, text=True)
        if container.returncode == 0:
            (output/'container-path.txt').write_text(container.stdout.strip()+'\n')
        for line in (output/'tests.log').read_text().splitlines():
            if ' error:' in line or ' failed' in line or 'Executed ' in line or '** TEST' in line:
                print(line, flush=True)
        if result.returncode:
            raise SystemExit(result.returncode)
        subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(output/'Tests.xcresult'),
                        '--output-path', str(output/'attachments')], check=True)
    finally:
        after = runtime_sources(root)
        (output/'source-after.json').write_text(json.dumps(after, indent=2)+'\n')
        (output/'source-unchanged.json').write_text(json.dumps(
            {'unchanged': after == source_hashes}, indent=2)+'\n')
        if set_status:
            subprocess.run(['xcrun', 'simctl', 'status_bar', udid, 'clear'], check=False)
        if booted_here:
            subprocess.run(['xcrun', 'simctl', 'shutdown', udid], check=False)


if __name__ == '__main__':
    main()
