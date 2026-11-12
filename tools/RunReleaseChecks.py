#!/usr/bin/env python3
"""Run all release automation and preserve evidence, including failed stages.

No retries or test filters are accepted: a green result must mean the whole
suite ran. Real-device/distribution evidence remains a separate release gate.
Use --report-quality-only to report historical quality-percentage targets separately.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
from swift_test_inventory import inventory as swift_inventory

ROOT = Path(__file__).resolve().parents[1]
DEVICE_ONLY = "PaperPathTests/testStoreAppliesCompleteFileProtection()"
IPAD_ONLY = {"PaperPathUITests/testIPadDocumentToolsInspectorOpensCompression()"}
DARK_MODE_TESTS = {"ReleaseReadinessUITests/testSupportInDarkMode()"}


def source_fingerprint():
    digest = hashlib.sha256()
    paths = subprocess.check_output(
        ["git", "ls-files", "-co", "--exclude-standard", "-z"], cwd=ROOT
    ).split(b"\0")
    for raw in sorted(set(paths)):
        if not raw:
            continue
        relative = os.fsdecode(raw)
        # Design screenshots and editorial docs can change while a candidate
        # runs; only compilation, resources, tests and gate inputs invalidate it.
        relevant = relative.startswith(("PaperPath/", "PaperPathShareExtension/",
                                       "PaperPathTests/", "PaperPathUITests/", "PaperPath.xcodeproj/"))
        relevant |= relative in {"project.yml", "docs/AUTOMATION_COVERAGE.json",
                                 "tools/RunReleaseChecks.py", "tools/test_release_checks.py",
                                 "tools/CheckAutomationCoverage.mjs", "tools/CheckCodeCoverage.mjs",
                                 "tools/swift_test_inventory.py", "docs/TEST_QUALITY_CONTRACT.json",
                                 "tools/CheckTestQuality.py", "tools/RunOutputOracleChecks.py",
                                 "tools/AuditMergeOutputs.py", "tools/test_merge_output_audit.py",
                                 "tools/StageCachedUIInputs.py",
                                 "tools/test_test_quality.py"}
        relevant |= relative.endswith(".xctestplan")
        if not relevant:
            continue
        path = ROOT / relative
        if path.is_file():
            digest.update(raw + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def test_cases(tree):
    for node in tree:
        if node.get("nodeType") == "Test Case":
            yield node
        yield from test_cases(node.get("children", []))


def test_inventory(directory):
    """XCTest's source declarations, independent of a scheme's selected tests."""
    return set(swift_inventory(ROOT / directory))


def validate_results(summary, tree, *, minimum, allowed_skips=(), expected_tests=None):
    """Reject empty/partial results and unexpected skips even when xcode exits 0."""
    errors = []
    cases = list(test_cases(tree.get("testNodes", [])))
    if summary.get("result") != "Passed" or summary.get("failedTests", 0):
        errors.append("test result is not Passed")
    if summary.get("passedTests", 0) < minimum:
        errors.append(f"fewer than {minimum} required passing tests")
    if summary.get("expectedFailures", 0):
        errors.append("expected failures require review")
    skipped = {case.get("nodeIdentifier") for case in cases if case.get("result") == "Skipped"}
    unexpected = skipped - set(allowed_skips)
    if unexpected:
        errors.append(f"unexpected skipped tests: {sorted(unexpected)}")
    if summary.get("skippedTests", 0) != len(skipped):
        errors.append("skipped test counts do not match test tree")
    if not cases:
        errors.append("missing test execution tree")
    if expected_tests is not None:
        actual = {case.get("nodeIdentifier") for case in cases}
        if actual != set(expected_tests):
            errors.append(f"test inventory mismatch; missing={sorted(set(expected_tests) - actual)}, "
                          f"unexpected={sorted(actual - set(expected_tests))}")
    bad_outcomes = [case.get("nodeIdentifier") for case in cases
                    if case.get("result") not in {"Passed", "Skipped"}]
    if bad_outcomes:
        errors.append(f"test cases have nonpassing outcomes: {bad_outcomes}")
    passed_count = sum(case.get("result") == "Passed" for case in cases)
    if summary.get("passedTests", 0) != passed_count:
        errors.append("passed test counts do not match test tree")
    return errors


def partition_tests(tests, workers):
    if workers < 1:
        raise ValueError("workers must be positive")
    ordered = sorted(tests)
    return [ordered[index::workers] for index in range(workers) if ordered[index::workers]]



def simulator_test_jobs():
    """Observe active Xcode test jobs across chats before touching a device."""
    processes = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
    active = []
    for line in processes.splitlines():
        fields = line.split()
        if len(fields) < 3 or Path(fields[1]).name != "xcodebuild":
            continue
        if any(argument in {"test", "test-without-building"} for argument in fields[2:]):
            active.append(int(fields[0]))
    return active


def require_idle_simulator_tests():
    active = simulator_test_jobs()
    if active:
        raise RuntimeError(f"Simulator testing is busy (Xcode PIDs {active}); wait and reuse the recorded devices")



def registered_session(family, iphone=None, ipad=None, pool=None):
    """Select one registered slot; reject old mixed-device invocations."""
    pool = pool or json.loads((Path.home() / '.codex/simulators/pool.json').read_text())
    if family not in {'iphone', 'ipad'}: raise ValueError('Choose one device family')
    if (iphone and ipad) or (family == 'iphone' and ipad) or (family == 'ipad' and iphone):
        raise ValueError('One device family per leased foreground run; mixed-device execution is prohibited')
    slot = 'ios26-phone' if family == 'iphone' else 'ios26-ipad'
    approved = pool['slots'][slot]['udid']
    if (iphone or ipad) and (iphone or ipad) != approved:
        raise ValueError('Use the registered existing device; no fallback or provisioning')
    return slot, approved


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--family", choices=["iphone", "ipad"], default="iphone", help="One registered device family per run")
    parser.add_argument("--leased", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--iphone", help="Optional registered iPhone UDID; incompatible with --ipad")
    parser.add_argument("--ipad", help="Optional registered iPad UDID; requires --family ipad")
    parser.add_argument("--node", default=os.environ.get("NODE_BINARY") or shutil.which("node"))
    parser.add_argument("--output", type=Path, help="New evidence directory; never overwritten")
    parser.add_argument("--system-diagnostics", action="store_true",
                        help="Also collect verbose simulator sysdiagnose on failure (can take ten minutes)")
    parser.add_argument("--ui-workers", type=int, choices=[1], default=1,
                        help="One serial worker; existing simulators are reused and never created")
    parser.add_argument("--quality-evidence", type=Path, action="append", default=[],
                        help="Additional current-source specialist runs for quality coverage")
    parser.add_argument("--report-quality-only", action="store_true",
                        help="Report historical quality-percentage targets separately from test execution")
    parser.add_argument("--analysis-python", type=Path,
                        default=Path.home() / '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3',
                        help="Existing offline Python with pypdf/Pillow for validator fault controls")
    args = parser.parse_args()
    try: slot, selected_device = registered_session(args.family, args.iphone, args.ipad)
    except ValueError as error: parser.error(str(error))
    guard = Path.home() / '.codex/simulators/guard.py'
    if not args.leased:
        subprocess.run([sys.executable, str(guard), 'status'], check=True)
        return subprocess.call([sys.executable, str(guard), 'run', '--slot', slot,
            '--owner', 'PaperPath/full release checks/' + args.family, '--', sys.executable,
            str(Path(__file__).resolve()), '--leased', *sys.argv[1:]], cwd=ROOT)
    if os.environ.get('CODEX_SIMULATOR_UDID') != selected_device:
        raise RuntimeError('Release runtime requires the registered foreground simulator lease')
    if not args.node:
        parser.error("Node is required; supply --node /absolute/path/to/node")
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
    available = {d["udid"]: d for group in devices["devices"].values() for d in group}
    for udid, kind in [(selected_device, "iPhone" if args.family == "iphone" else "iPad")]:
        if udid not in available or kind not in (
            available[udid].get("deviceTypeIdentifier", "") + available[udid]["name"]
        ):
            parser.error(f"{udid} must identify an available {kind} simulator")
    if available[selected_device]["state"] != "Shutdown":
        raise RuntimeError("Assigned device is already booted; investigate ownership before running")
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = (args.output or ROOT / ".artifacts" / f"release-{stamp}").resolve()
    output.mkdir(parents=True, exist_ok=False)
    from CheckTestQuality import runtime_sources
    report = {"status": "RUNNING", "startedAt": stamp,
              "qualityTargetsRequired": not args.report_quality_only,
              "runtimeSourceHashes": runtime_sources(ROOT),
              "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "sourceFingerprint": source_fingerprint(), "stages": [],
              "manualGates": ["Physical camera capture and permission deny/allow",
                              "Physical-device file protection, biometrics and background privacy",
                              "Paid-download installation and offline tool access on a distribution build",
                              "Real-account iCloud metadata sync/delete/conflict recovery across two devices",
                              "Minimum supported iOS and current iOS on iPhone/iPad",
                              "Large scanned PDFs: memory, cancellation and OCR quality",
                              "Signed archive, external sharing, App Store metadata and privacy URLs"]}

    report_lock = threading.RLock()
    booted_by_run = set()

    def save():
        with report_lock:
            temporary = output / "report.json.tmp"
            temporary.write_text(json.dumps(report, indent=2) + "\n")
            temporary.replace(output / "report.json")

    def run(name, command):
        print(f"[{name}] running; log: {output / (name + '.log')}", flush=True)
        stage = {"name": name, "command": [str(c) for c in command]}
        with report_lock:
            report["stages"].append(stage)
            save()
        with (output / (name + ".log")).open("w") as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        with report_lock:
            stage["exitCode"] = result.returncode
            stage["passed"] = result.returncode == 0
            save()
        return stage

    def read_json(command, destination):
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=True)
        destination.write_text(result.stdout)
        return json.loads(result.stdout)

    def suite(name, scheme, udid, selection, minimum, expected_tests, allowed_skips=(), xctestrun=None):
        require_idle_simulator_tests()
        bundle = output / f"{name}.xcresult"
        invocation = (["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun)] if xctestrun else
                      ["xcodebuild", "test", "-project", "PaperPath.xcodeproj", "-scheme", scheme,
                       "-derivedDataPath", str(output / "DerivedData")])
        stage = run(name, [*invocation, "-destination", f"platform=iOS Simulator,id={udid}",
                           "-parallel-testing-enabled", "NO",
                           "-maximum-concurrent-test-simulator-destinations", "1",
                           "-maximum-parallel-testing-workers", "1", "-test-timeouts-enabled", "YES",
                           "-default-test-execution-time-allowance", "240", "-maximum-test-execution-time-allowance", "900", "-enableCodeCoverage", "YES",
                           "-collect-test-diagnostics", "on-failure" if args.system_diagnostics else "never",
                           "-resultBundlePath", str(bundle), *selection])
        try:
            summary = read_json(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)],
                                output / f"{name}-summary.json")
            tree = read_json(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)],
                             output / f"{name}-tests.json")
            with report_lock:
                stage["counts"] = {key: summary.get(key) for key in
                                   ["passedTests", "failedTests", "skippedTests", "totalTestCount"]}
                stage["validationErrors"] = validate_results(
                    summary, tree, minimum=minimum, allowed_skips=allowed_skips, expected_tests=expected_tests)
                stage["passed"] &= not stage["validationErrors"]
        except (subprocess.CalledProcessError, ValueError) as error:
            with report_lock:
                stage["passed"] = False
                stage["validationErrors"] = [str(error)]
        save()
        return bundle

    def preboot(udid, label):
        require_idle_simulator_tests()
        current = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"]))
        state = next(d["state"] for group in current["devices"].values() for d in group if d["udid"] == udid)
        if state != "Booted":
            if not run(f"boot-{label}", ["xcrun", "simctl", "boot", udid])["passed"]:
                raise RuntimeError(f"Could not boot {label}")
            booted_by_run.add(udid)
        if not run(f"ready-{label}", ["xcrun", "simctl", "bootstatus", udid, "-b"])["passed"]:
            raise RuntimeError(f"Simulator {label} did not become ready")
        # New simulators otherwise put the system's swipe-typing tutorial over
        # the first keyboard. This is host setup, not an application result.
        if not run(f"keyboard-ready-{label}", ["xcrun", "simctl", "spawn", udid, "defaults", "write",
                                               "com.apple.keyboard", "CPDidDiscover", "-bool", "true"])["passed"]:
            raise RuntimeError(f"Simulator {label} keyboard setup failed")

    save()
    try:
        run("gate-tests", [sys.executable, "-m", "unittest", "discover", "-s", "tools", "-p", "test_release_checks.py"])
        run("quality-metric-tests", [sys.executable, "-m", "unittest", "discover", "-s", "tools", "-p", "test_test_quality.py"])
        run("feature-contract", [args.node, "tools/CheckAutomationCoverage.mjs"])
        unit_tests = test_inventory("PaperPathTests")
        ui_tests = test_inventory("PaperPathUITests")
        build = run("test-build", ["xcodebuild", "build-for-testing", "-project", "PaperPath.xcodeproj",
                                   "-scheme", "PaperPath", "-destination", f"platform=iOS Simulator,id={selected_device}",
                                   "SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG PAPERPATH_REVIEW_BUILD",
                                   "-enableCodeCoverage", "YES", "-derivedDataPath", str(output / "DerivedData")])
        test_runs = list((output / "DerivedData/Build/Products").glob("PaperPath_*.xctestrun"))
        if not build["passed"] or len(test_runs) != 1:
            raise RuntimeError("Test build did not produce exactly one runnable test configuration")
        test_run = test_runs[0]
        preboot(selected_device, "unit-" + args.family)
        units = suite("unit", "PaperPath", selected_device, ["-only-testing:PaperPathTests"],
                      len(unit_tests) - 1, unit_tests, [DEVICE_ONLY], xctestrun=test_run)
        # Coverage is checked independently of test success. Neither substitutes for the other.
        try:
            read_json(["xcrun", "xccov", "view", "--report", "--json", str(units)], output / "coverage.json")
            run("coverage-contract", [args.node, "tools/CheckCodeCoverage.mjs", str(output / "coverage.json")])
        except (subprocess.CalledProcessError, ValueError) as error:
            report["stages"].append({"name": "coverage-contract", "passed": False, "error": str(error)})
        jobs = []
        for family, seed, tests in [(args.family, selected_device, ui_tests - IPAD_ONLY if args.family == "iphone" else ui_tests)]:
            for index, expected in enumerate(partition_tests(tests, args.ui_workers)):
                device = seed
                name = f"ui-{family}-{index + 1}"
                selection = [f"-only-testing:PaperPathUITests/{test.removesuffix('()')}" for test in expected]
                jobs.append((name, device, selection, expected))
        report["reusedSimulators"] = [selected_device]
        report["deviceFamily"] = args.family
        report["scope"] = "One device family only; other families require a separate deliberate run"
        save()
        for name, device, selection, expected in jobs:
            preboot(device, name)
            if not run(name + "-offline-inputs", [sys.executable, "tools/StageCachedUIInputs.py",
                    str(ROOT), str(output / (name + "-offline-inputs.json"))])["passed"]:
                raise RuntimeError("Cached offline UI inputs could not be prepared")
            dark_tests = set(expected) & DARK_MODE_TESTS
            normal_tests = set(expected) - dark_tests
            selection = [f"-only-testing:PaperPathUITests/{test.removesuffix('()')}" for test in sorted(normal_tests)]
            suite(name, "PaperPath", device, selection, len(normal_tests), normal_tests, xctestrun=test_run)
            if dark_tests:
                require_idle_simulator_tests()
                previous = subprocess.check_output(["xcrun", "simctl", "ui", device, "appearance"], text=True).strip()
                if previous not in {"light", "dark"}:
                    raise RuntimeError(f"Cannot verify dark appearance on {device}: {previous}")
                try:
                    if not run(name + "-dark-appearance", ["xcrun", "simctl", "ui", device, "appearance", "dark"])["passed"]:
                        raise RuntimeError("Could not apply dark appearance")
                    selection = [f"-only-testing:PaperPathUITests/{test.removesuffix('()')}" for test in sorted(dark_tests)]
                    suite(name + "-dark", "PaperPath", device, selection, len(dark_tests), dark_tests, xctestrun=test_run)
                finally:
                    run(name + "-restore-appearance", ["xcrun", "simctl", "ui", device, "appearance", previous])
        run("release-build", ["xcodebuild", "build", "-project", "PaperPath.xcodeproj", "-scheme", "PaperPath",
                              "-configuration", "Release", "-destination", "generic/platform=iOS", "CODE_SIGNING_ALLOWED=NO",
                              "-derivedDataPath", str(output / "DerivedData")])
        unchanged = source_fingerprint() == report["sourceFingerprint"]
        report["sourceUnchangedDuringRun"] = unchanged
        if unchanged and all(s.get("passed") for s in report["stages"]):
            report["status"] = "CHECKING_QUALITY"
            save()
            run("output-oracle-controls", [str(args.analysis_python), "tools/RunOutputOracleChecks.py",
                                          "--output", str(output / "oracle-controls.json")])
            quality = [sys.executable, "tools/CheckTestQuality.py",
                       "--evidence", str(output), "--oracle-evidence", str(output / "oracle-controls.json"),
                       "--output", str(output / "test-quality.json")]
            if not args.report_quality_only:
                quality.append("--gate")
            for evidence in args.quality_evidence:
                quality += ["--evidence", str(evidence.resolve())]
            run("test-quality", quality)
        report["status"] = ("AUTOMATION_PASSED_MANUAL_REQUIRED" if unchanged and
                            all(s.get("passed") for s in report["stages"]) else "FAILED")
    except (Exception, KeyboardInterrupt) as error:
        report["status"] = "INTERRUPTED" if isinstance(error, KeyboardInterrupt) else "FAILED"
        report["error"] = str(error)
    finally:
        # Preserve device data and all caches; shut down only devices this run booted.
        if not simulator_test_jobs():
            for udid in sorted(booted_by_run):
                subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True)
        save()
        print(f"{report['status']}: {output / 'report.json'}", flush=True)
    return 0 if report["status"] == "AUTOMATION_PASSED_MANUAL_REQUIRED" else 1


if __name__ == "__main__":
    sys.exit(main())
