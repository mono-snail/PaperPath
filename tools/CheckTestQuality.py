#!/usr/bin/env python3
"""Report reviewed scenario coverage using current-source XCTest evidence.

Normal exit 0 means the report was produced, not that coverage is sufficient.
--gate exits 1 for unmet targets. No simulator, network or AI calls.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from swift_test_inventory import inventory

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def runtime_sources(root):
    paths = [p for folder in ['PaperPath', 'PaperPathTests', 'PaperPathUITests', 'PaperPathShareExtension']
             for p in (root / folder).rglob('*') if p.is_file()
             and p.suffix in ['.swift', '.strings', '.plist', '.entitlements']]
    paths += [root / 'PaperPath.xcodeproj/project.pbxproj', root / 'project.yml']
    return {str(p.relative_to(root)): sha(p) for p in sorted(paths)}


def test_cases(node):
    if isinstance(node, dict):
        if node.get('nodeType') == 'Test Case':
            yield node
        for child in node.get('children', node.get('testNodes', [])):
            yield from test_cases(child)
    elif isinstance(node, list):
        for child in node:
            yield from test_cases(child)


def extract_results(bundle):
    def read(kind):
        return json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results',
            kind, '--path', str(bundle)], text=True))
    return read('summary'), read('tests')


def audit_valid(report):
    outputs = report.get('outputs', [])
    if report.get('status') != 'PASSED' or not outputs:
        return False
    try:
        for output in outputs:
            if not output.get('original_sha256') or not output.get('pages'):
                return False
            if not all(all(page.get(field) is True for field in
                ['text_order', 'geometry', 'rendered_pixels_identical', 'annotations']) for page in output['pages']):
                return False
            evidence = Path(output['retained_evidence'])
            if sha(evidence / 'merged.pdf') != output['sha256']:
                return False
            sources = json.loads((evidence / 'sources.json').read_text())['sources']
            if len(sources) != len(output['original_sha256']):
                return False
            for source in sources:
                if sha(evidence / f"source-{source['number']:02d}.pdf") != output['original_sha256'][source['name']]:
                    return False
    except (OSError, KeyError, TypeError, ValueError):
        return False
    return True


def session_audit_features(report):
    if report.get('status') != 'PASSED': return {}
    verified = {}
    for case in report.get('cases', []):
        if case.get('status') != 'PASSED': continue
        files = case.get('files', [])
        checks = case.get('checks', [])
        try:
            valid_files = bool(files) and all(sha(Path(file['path'])) == file['sha256'] for file in files)
        except (OSError, KeyError):
            valid_files = False
        unchanged = lambda row: row.get('bytesUnchanged') is True and row.get('readablePages', 0) > 0
        compressed = lambda row: (row.get('strictlySmaller') is True and row.get('outputBytes', 0) < row.get('sourceBytes', 0)
            and row.get('pageCount', 0) > 0 and row.get('contentPreserved') is True and row.get('renderedPixelsIdentical') is True)
        protected = lambda row: (all(row.get(field) is True for field in ['protectionEnabled', 'wrongPasswordRejected',
            'correctPasswordAccepted', 'contentPreserved', 'renderedPixelsIdentical', 'formFieldsPreserved']) and row.get('pageCount', 0) > 0)
        extracted = lambda row: (all(row.get(field) is True for field in ['originalSourcesUnchanged', 'contentPreserved',
            'renderedPixelsIdentical', 'selectionOrderPreserved']) and row.get('pageCount', 0) == len(row.get('selectedPages', [])) > 0)
        edited = lambda row: (all(row.get(field) is True for field in ['unchangedDocumentIdentity', 'otherDocumentsUnchanged',
            'existingPageContentPreserved', 'renderedOutputVerified']) and row.get('mutationVerified') == case.get('auditKind')
            and row.get('changedItems') == 1 and row.get('pageCount', 0) > 0)
        redacted = lambda row: (all(row.get(field) is True for field in ['unchangedDocumentIdentity', 'otherDocumentsUnchanged',
            'sensitiveTermsOriginallyPresent', 'hiddenTextAbsent', 'annotationsFormsAttachmentsRemoved', 'pageImagesPresent',
            'pageGeometryPreserved']) and bool(row.get('removedTerms')) and row.get('pageCount', 0) > 0)
        form_added = lambda row: (all(row.get(field) is True for field in ['newTextFieldPresent', 'existingFieldsPreserved',
            'originalContentPreserved', 'widgetInsidePage', 'fieldTreeConnected', 'writableNewField',
            'unchangedDocumentIdentity', 'otherDocumentsUnchanged'])
            and bool(row.get('newFieldName')) and row.get('pageCount', 0) > 0)
        ocr_saved = lambda row: (all(row.get(field) is True for field in ['everyPageWordVerified', 'pinnedOriginalScan',
            'existingNativeTextPreserved', 'renderedPixelsIdentical', 'unchangedDocumentIdentity', 'otherDocumentsUnchanged'])
            and row.get('pageCount', 0) == len(row.get('expectedPageWords', [])) > 0)
        annotated = lambda row: (all(row.get(field) is True for field in ['annotationContentVerified', 'visibleRenderingVerified',
            'boundsAndStrokesValid', 'originalContentAndFieldsPreserved', 'unchangedDocumentIdentity', 'otherDocumentsUnchanged'])
            and row.get('addedCount', 0) == row.get('expectedCount', -1) > 0 and row.get('pageCount', 0) > 0)
        word_exported = lambda row: (all(row.get(field) is True for field in ['validDocxStructure', 'allNativeWordsAndNumbersPreserved',
            'originalSourcesUnchanged', 'sourceRevisionVerified', 'artifactReceiptVerified']) and row.get('sourceWordCount', 0) > 0)
        images_exported = lambda row: (all(row.get(field) is True for field in ['originalSourcesUnchanged',
            'sourceAndPresetVerified', 'everyPageImageVerified']) and row.get('pageCount', 0) == row.get('exportedCount', -1) > 0
            and 0 <= row.get('maximumRelativeError', 1) <= .12)
        shared = lambda row: (all(row.get(field) is True for field in ['pageGeometryPreserved', 'hiddenTextAbsent',
            'annotationsFormsAttachmentsRemoved', 'renderedOutputVerified', 'originalSourcesUnchanged', 'exactlyOneNewOutput'])
            and row.get('pageCount', 0) > 0 and 0 <= row.get('maximumRelativeError', 1) <= .12)
        image_created = lambda row: (all(row.get(field) is True for field in ['imageContentPresent', 'pageOrderVerified',
            'geometryVerified', 'labelInkPresent', 'originalSourcesUnchanged', 'exactlyOneNewOutput']) and row.get('pageCount') == 2)
        form_filled = lambda row: (all(row.get(field) is True for field in ['savedFieldValueVerified', 'otherFieldsPreserved',
            'originalPageContentPreserved', 'unchangedDocumentIdentity', 'otherDocumentsUnchanged']) and row.get('pageCount',0)>0)
        imported = lambda row: (all(row.get(field) is True for field in ['pinnedOriginalBytes', 'originalSourcesUnchanged',
            'exactlyOneNewOutput']) and row.get('readablePages',0)>0)
        valid_checks = bool(checks) and ((case.get('auditKind') == 'unchanged' and all(unchanged(row) for row in checks))
            or (case.get('auditKind') == 'compressionLossless' and any(compressed(row) for row in checks)
                and all(unchanged(row) or compressed(row) for row in checks))
            or (case.get('auditKind') == 'protection' and any(protected(row) for row in checks)
                and all(unchanged(row) or protected(row) for row in checks))
            or (case.get('auditKind') == 'extraction' and all(extracted(row) for row in checks))
            or (case.get('auditKind') in {'editedContent', 'editedLink'} and all(edited(row) for row in checks))
            or (case.get('auditKind') == 'redaction' and all(redacted(row) for row in checks))
            or (case.get('auditKind') == 'formAdded' and all(form_added(row) for row in checks))
            or (case.get('auditKind') == 'searchableOCR' and all(ocr_saved(row) for row in checks))
            or (case.get('auditKind') == 'addedAnnotation' and all(annotated(row) for row in checks))
            or (case.get('auditKind') == 'wordDocument' and all(word_exported(row) for row in checks))
            or (case.get('auditKind') == 'importedPDF' and all(imported(row) for row in checks))
            or (case.get('auditKind') == 'formFilled' and all(form_filled(row) for row in checks))
            or (case.get('auditKind') == 'imageCreation' and all(image_created(row) for row in checks))
            or (case.get('auditKind') == 'safeShare' and all(shared(row) for row in checks))
            or (case.get('auditKind') == 'pageImages' and all(images_exported(row) for row in checks)))
        if valid_files and valid_checks:
            verified.setdefault(case['feature'], []).append(case['testID'])
    return verified


def independent_for(run, feature, tests):
    if 'auditFeatures' in run:
        return set(tests) <= set(run['auditFeatures'].get(feature, []))
    return run.get('audit') is True and feature == 'quickTasks.mergePDFs'


def release_fingerprint():
    from RunReleaseChecks import source_fingerprint
    return source_fingerprint()


def load_release_run(directory):
    report = json.loads((directory / 'report.json').read_text())
    snapshot = report.get('runtimeSourceHashes')
    current = snapshot == runtime_sources(ROOT) if snapshot is not None else report.get('sourceFingerprint') == release_fingerprint()
    if (report.get('status') not in {'CHECKING_QUALITY', 'AUTOMATION_PASSED_MANUAL_REQUIRED', 'FAILED'}
        or report.get('sourceUnchangedDuringRun') is not True or not current):
        raise ValueError('stale or unfinished release evidence')
    stages = [stage for stage in report['stages'] if stage['name'] != 'test-quality']
    if not stages or not all(stage.get('passed') is True for stage in stages):
        raise ValueError('release prerequisites failed or incomplete')
    suites = [stage for stage in stages if 'counts' in stage]
    if not any(s['name'] == 'unit' for s in suites) or not any(s['name'].startswith('ui-iphone-') for s in suites):
        raise ValueError('release evidence is missing unit or iPhone UI execution')
    passed, observed, finish = set(), set(), 0
    for stage in suites:
        command = stage['command']
        bundle = Path(command[command.index('-resultBundlePath') + 1])
        summary, tree = extract_results(bundle)
        cases = list(test_cases(tree))
        skipped = [c for c in cases if c.get('result') == 'Skipped']
        if (not cases or summary.get('result') != 'Passed' or summary.get('failedTests') != 0
            or summary.get('expectedFailures') != 0
            or summary.get('skippedTests') != len(skipped)
            or summary.get('passedTests') != sum(c.get('result') == 'Passed' for c in cases)
            or any(c['nodeIdentifier'] != 'PaperPathTests/testStoreAppliesCompleteFileProtection()' for c in skipped)
            or any(c.get('result') not in {'Passed', 'Skipped'} for c in cases)):
            raise ValueError('release XCTest results incomplete or unexpectedly skipped')
        passed.update(c['nodeIdentifier'] for c in cases if c['result'] == 'Passed')
        observed.update(c['nodeIdentifier'] for c in cases)
        finish = max(finish, summary.get('finishTime', 0))
    return dict(path=str(directory), tests=passed, observedTests=observed, audit=False,
                valid=True, sourceCurrent=True, finishTime=finish)


def load_run(directory, current):
    run = dict(path=str(directory), tests=set(), observedTests=set(), audit=False, valid=False, sourceCurrent=False, finishTime=0)
    try:
        session = (directory / 'quality-report.json').exists()
        if not session and not (directory / 'merge-report.json').exists():
            return load_release_run(directory)
        report = json.loads((directory / ('quality-report.json' if session else 'merge-report.json')).read_text())
        before = json.loads((directory / 'source-before.json').read_text())
        after = json.loads((directory / 'source-after.json').read_text())
        if before != after or after != current:
            raise ValueError('stale or changing source snapshot')
        run['sourceCurrent'] = True
        summary, tree = extract_results(directory / 'Tests.xcresult')
        cases = list(test_cases(tree))
        identifiers = [c.get('nodeIdentifier') for c in cases]
        run.update(observedTests=set(identifiers), finishTime=summary.get('finishTime', 0))
        if not cases or len(set(identifiers)) != len(identifiers):
            raise ValueError('empty or duplicate runtime test inventory')
        if (report.get('status') != 'PASSED' or report.get('test_exit') != 0
            or summary.get('result') != 'Passed' or summary.get('failedTests') != 0
            or summary.get('skippedTests') != 0 or summary.get('expectedFailures') != 0
            or summary.get('passedTests') != len(cases)
            or any(c.get('result') != 'Passed' for c in cases)):
            raise ValueError('failed, incomplete or skipped execution')
        run.update(valid=True, tests=set(identifiers), finishTime=summary.get('finishTime', 0))
        if session:
            audit_path = directory / 'quality-audit.json'
            if audit_path.exists() and report.get('independent_audit_exit') == 0:
                run['auditFeatures'] = session_audit_features(json.loads(audit_path.read_text()))
                run['audit'] = bool(run['auditFeatures'])
            return run
        audit_path = directory / 'independent-merge-audit.json'
        if audit_path.exists():
            run['audit'] = audit_valid(json.loads(audit_path.read_text())) and report.get('independent_audit_exit') == 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        run['error'] = str(error)
    return run


def ratio(covered, required):
    return dict(verified=covered, required=required,
                percent=round(100 * covered / required, 2) if required else None,
                targetPercent=100, met=covered == required)


def evaluate(root, policy, run_paths=(), oracle_path=None, selected_features=None):
    legacy = json.loads((root / 'docs/AUTOMATION_COVERAGE.json').read_text())
    legacy_features = {f'{section}.{name}': entry for section in ['quickTasks', 'documentTools', 'workflows']
                       for name, entry in legacy[section].items()}
    if set(policy['features']) != set(legacy_features):
        raise ValueError('Quality contract must enumerate every feature in AUTOMATION_COVERAGE.json')
    unit_tests = inventory(root / 'PaperPathTests')
    ui_tests = inventory(root / 'PaperPathUITests')
    tests = {**unit_tests, **ui_tests}
    source_tests = Counter(key.split('/', 1)[1].removesuffix('()') for key in tests)
    registration = sum(all(source_tests.get(name, 0) == 1 for name in
        entry['logicTests'] + [entry['journeyTest']]) for entry in legacy_features.values())
    current = runtime_sources(root)
    # Repeating the same directory cannot fabricate three independent runs.
    paths = sorted({Path(p).resolve() for p in run_paths})
    runs = [load_run(p, current) for p in paths]
    valid_runs = [run for run in runs if run['valid']]
    verified_scenarios = set()
    scenario_status = {}
    for name, scenario in policy['scenarios'].items():
        referenced = set(scenario['tests'])
        if not referenced or not referenced <= set(tests):
            raise ValueError('Missing/ambiguous XCTest reference in scenario: ' + name)
        owners = scenario.get('features', [])
        if not owners or set(owners) - set(policy['features']):
            raise ValueError('Scenario must name existing feature owners: ' + name)
        layer = scenario.get('layer')
        if layer not in {'ui', 'service'} or not referenced <= set(ui_tests if layer == 'ui' else unit_tests):
            raise ValueError('Scenario test layer mismatch: ' + name)
        expected_paths = {str(Path(tests[t]['path']).relative_to(root)) for t in referenced}
        reviewed = scenario.get('reviewedSources', {})
        review_current = set(reviewed) == expected_paths and all(
            sha(root / p) == digest for p, digest in reviewed.items())
        executed = any(referenced <= run['tests'] for run in valid_runs)
        scenario_status[name] = 'verified' if review_current and executed else (
            'review-stale' if not review_current else 'not-executed-current-source')
        if scenario_status[name] == 'verified':
            verified_scenarios.add(name)

    def covered(claims, feature=None, layer=None):
        if any(name not in policy['scenarios'] for name in claims):
            raise ValueError('Unknown scenario claim: ' + str(claims))
        if feature and any(feature not in policy['scenarios'][name]['features'] for name in claims):
            raise ValueError('Scenario belongs to a different feature: ' + str(claims))
        if layer and any(policy['scenarios'][name]['layer'] != layer for name in claims):
            raise ValueError('UI coverage cannot be claimed by service-only tests: ' + str(claims))
        return bool(claims) and all(name in verified_scenarios for name in claims)

    rows = []
    for feature, entry in policy['features'].items():
        if selected_features and feature not in selected_features:
            continue
        minimum_states = {'primaryResult', 'cancelReentry', 'repeatBoundary', 'invalidRecovery', 'stateIsolation', 'largeText'}
        if not minimum_states <= set(entry['requiredStates']):
            raise ValueError('Required base states cannot be omitted: ' + feature)
        if entry['independentOutputRequired'] and 'persistence' not in entry['requiredStates']:
            raise ValueError('Output feature must require persistence: ' + feature)
        if not {'text', 'scan', 'multiPage'} <= set(entry['requiredMaterials']):
            raise ValueError('Required base materials cannot be omitted: ' + feature)
        if set(entry['states']) - set(entry['requiredStates']) or set(entry['materials']) - set(entry['requiredMaterials']):
            raise ValueError('Claim outside declared requirement: ' + feature)
        if set(entry['requiredStates']) - set(policy['states']) or set(entry['requiredMaterials']) - set(policy['materialKinds']):
            raise ValueError('Unknown required state/material: ' + feature)
        states = {state: covered(entry['states'].get(state, []), feature, 'ui') and entry['reviewStatus'] == 'reviewed' for state in entry['requiredStates']}
        materials = {kind: covered(entry['materials'].get(kind, []), feature, 'ui') and entry['reviewStatus'] == 'reviewed' for kind in entry['requiredMaterials']}
        independent = not entry['independentOutputRequired']
        output_claim = entry.get('independentOutput', {})
        if entry['independentOutputRequired'] and output_claim:
            if output_claim.get('audit') not in {'merge-output', 'quality-session'}:
                raise ValueError('Unsupported output oracle: ' + feature)
            scenario = output_claim['scenario']
            independent = entry['reviewStatus'] == 'reviewed' and covered([scenario], feature, 'ui') and any(independent_for(run, feature, policy['scenarios'][scenario]['tests']) and
                set(policy['scenarios'][scenario]['tests']) <= run['tests'] for run in valid_runs)
        required_scenarios = {s for claims in entry['states'].values() for s in claims}
        stable_runs = 0
        required_tests = {test for scenario in required_scenarios for test in policy['scenarios'][scenario]['tests']}
        seen_runs = set()
        if all(states.values()) and required_tests:
            for run in sorted(runs, key=lambda r: r['finishTime']):
                identity = (run['finishTime'], tuple(sorted(run['observedTests'])))
                if not run['sourceCurrent'] or identity in seen_runs:
                    continue
                seen_runs.add(identity)
                relevant = bool(required_tests & run['observedTests'])
                if relevant and not run['valid']:
                    stable_runs = 0
                elif required_tests <= run['tests']:
                    if not entry['independentOutputRequired'] or (output_claim and independent_for(run, feature, policy['scenarios'][output_claim['scenario']]['tests'])):
                        stable_runs += 1
                    else:
                        stable_runs = 0
        rows.append(dict(feature=feature, priority=entry['priority'], reviewStatus=entry['reviewStatus'],
            states=states, materials=materials, independentOutput=independent,
            independentOutputRequired=entry['independentOutputRequired'], stableRuns=stable_runs,
            stableRunsRequired=policy['policy']['stableRunsRequired'],
            missingStates=[s for s, ok in states.items() if not ok],
            missingMaterials=[k for k, ok in materials.items() if not ok]))
    if selected_features and set(selected_features) - set(policy['features']):
        raise ValueError('Unknown selected feature')
    defects = [dict(**d, verified=covered(d['scenarios'], d['feature'])) for d in policy['defects']
               if not selected_features or d['feature'] in selected_features]
    positive_controls = policy.get('oraclePositiveControls', ['MergeOutputAuditTests/test_correct_output_passes'])
    negative_controls = [test for test in policy['oracleTests'] if test not in positive_controls]
    oracle = dict(verified=False, reason='no current oracle evidence', negativeDetected=0,
                  negativeRequired=len(negative_controls))
    if oracle_path:
        proof = json.loads(Path(oracle_path).read_text())
        fingerprints = {p: sha(root / p) for p in policy['oracleSources']}
        expected = set(policy['oracleTests'])
        outcomes = proof.get('outcomes', {})
        current_controls = (proof.get('sourceHashes') == fingerprints and proof.get('sourceUnchanged') is True
                            and set(outcomes) == expected)
        positive_passed = all(outcomes.get(test) == 'Passed' for test in positive_controls)
        ok = current_controls and proof.get('status') == 'PASSED' and all(v == 'Passed' for v in outcomes.values())
        detected = sum(outcomes.get(test) == 'Passed' for test in negative_controls) if current_controls and positive_passed else 0
        oracle.update(verified=ok, reason='verified' if ok else 'incomplete/stale/failed oracle controls',
                      negativeDetected=detected, outcomes=outcomes)
    metrics = dict(featureRegistration=ratio(registration, len(legacy_features)),
        criticalStates=ratio(sum(sum(r['states'].values()) for r in rows), sum(len(r['states']) for r in rows)),
        materialKinds=ratio(sum(sum(r['materials'].values()) for r in rows), sum(len(r['materials']) for r in rows)),
        independentOutputs=ratio(sum(r['independentOutput'] for r in rows if r['independentOutputRequired']),
                                 sum(r['independentOutputRequired'] for r in rows)),
        trackedDefectRegressions=ratio(sum(d['verified'] for d in defects), len(defects)),
        stableCriticalFeatures=ratio(sum(r['stableRuns'] >= policy['policy']['stableRunsRequired'] for r in rows if r['priority'] == 'P0'),
                                     sum(r['priority'] == 'P0' for r in rows)),
        oracleFaultDetection=ratio(oracle['negativeDetected'], oracle['negativeRequired']))
    work_order = policy['policy'].get('workOrder', [])
    next_actions = []
    for row in sorted(rows, key=lambda r: (work_order.index(r['feature']) if r['feature'] in work_order else len(work_order), r['priority'], r['feature'])):
        if row['missingStates'] or row['missingMaterials'] or not row['independentOutput']:
            next_actions.append(dict(feature=row['feature'], reviewStatus=row['reviewStatus'],
                states=row['missingStates'], materials=row['missingMaterials'],
                needsIndependentOutput=not row['independentOutput']))
    met = all(metric['met'] for metric in metrics.values()) and oracle['verified']
    return dict(status='TARGETS_MET' if met else 'INCOMPLETE', metrics=metrics,
        features=rows, scenarios=scenario_status, defects=defects, oracle=oracle, nextActions=next_actions,
        evidence=[dict(**{k: v for k, v in run.items() if k not in {'tests', 'observedTests'}},
                       tests=sorted(run['tests']), observedTests=sorted(run['observedTests'])) for run in runs],
        contractSHA256=sha(root / 'docs/TEST_QUALITY_CONTRACT.json'),
        interpretation='Verified lower bound. Unreviewed does not mean untested. No aggregate score.',
        defectCatalogScope=policy['defectCatalogScope'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', action='append', type=Path, default=[])
    parser.add_argument('--oracle-evidence', type=Path)
    parser.add_argument('--feature', action='append')
    parser.add_argument('--output', type=Path, default=ROOT / '.artifacts/test-quality/current.json')
    parser.add_argument('--gate', action='store_true')
    args = parser.parse_args()
    try:
        policy = json.loads((ROOT / 'docs/TEST_QUALITY_CONTRACT.json').read_text())
        report = evaluate(ROOT, policy, args.evidence, args.oracle_evidence, args.feature)
    except (OSError, ValueError, KeyError) as error:
        print('Invalid quality contract/evidence:', error, file=sys.stderr)
        return 2
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    labels = dict(featureRegistration='功能测试归属', criticalStates='已核验关键状态',
        materialKinds='已核验素材类型', independentOutputs='独立结果校验',
        trackedDefectRegressions='登记缺陷回归', stableCriticalFeatures='已达连续三轮的 P0 功能',
        oracleFaultDetection='校验器错误检出')
    lines = ['PaperPath 自动化质量指标 v1', '整体状态：' + report['status'],
             '所有覆盖目标为 100%；P0 关键流程要求同版本连续完成 3 轮。',
             '以下是已核验的下限，待审查不等于没有测试；没有加权总分。', '']
    lines += [f"{labels[key]}：{value['verified']}/{value['required']}" for key, value in report['metrics'].items()]
    reviewed = [row for row in report['features'] if row['reviewStatus'] == 'reviewed']
    lines += ['', '已完成逐项场景审查：' + str(len(reviewed)) + '/' + str(len(report['features']))]
    for row in reviewed:
        lines += [row['feature'] + '：状态 ' + str(sum(row['states'].values())) + '/' + str(len(row['states']))
                  + '，素材 ' + str(sum(row['materials'].values())) + '/' + str(len(row['materials']))
                  + '，连续完整运行 ' + str(row['stableRuns']) + '/' + str(row['stableRunsRequired'])]
        lines += ['待补素材：' + '、'.join(policy['materialKinds'][kind] for kind in row['missingMaterials'])]
    lines += ['', '下一轮优先顺序：']
    lines += [action['feature'] + '；状态缺口 ' + str(len(action['states']))
              + '；素材缺口 ' + str(len(action['materials'])) for action in report['nextActions'][:3]]
    lines += ['', '证据目录：'] + [run['path'] + ('（有效）' if run['valid'] else '（无效/过期）') for run in report['evidence']]
    args.output.with_suffix('.txt').write_text('\n'.join(lines) + '\n')
    print(report['status'])
    for name, value in report['metrics'].items():
        print(f"{name}: {value['verified']}/{value['required']} (target 100%)")
    print('Report:', args.output)
    return 1 if args.gate and report['status'] != 'TARGETS_MET' else 0


if __name__ == '__main__':
    raise SystemExit(main())
