#!/usr/bin/env python3
"""Run all release automation and preserve evidence, including failed stages.

No retries or test filters are accepted: a green result must mean the whole
suite ran. Real-device/distribution evidence remains a separate release gate.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
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

ROOT = Path(__file__).resolve().parents[1]
COMMERCE_TESTS = [
    "testPendingPurchaseSurvivesRecheckAndReopenThenApproves",
    "testRestoreWithoutPurchaseShowsRecoverableFailure",
    "testPurchasePersistsAcrossProcessRelaunchAndRefundRevokesAccess",
]
DEVICE_ONLY = "PaperPathTests/testStoreAppliesCompleteFileProtection()"
IPAD_ONLY = {"PaperPathUITests/testIPadDocumentToolsInspectorOpensCompression()"}


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
                                 "tools/CheckAutomationCoverage.mjs", "tools/CheckCodeCoverage.mjs"}
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
    identifiers = set()
    for path in (ROOT / directory).glob("*.swift"):
        current_class = None
        for line in path.read_text().splitlines():
            match = re.match(r"(?:final )?class (\w+): XCTestCase", line)
            if match:
                current_class = match[1]
            match = re.match(r"    func (test\w+)\(", line)
            if match and current_class:
                identifiers.add(f"{current_class}/{match[1]}()")
    return identifiers


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iphone", required=True, help="Available iPhone simulator UDID")
    parser.add_argument("--ipad", required=True, help="Available iPad simulator UDID")
    parser.add_argument("--node", default=os.environ.get("NODE_BINARY") or shutil.which("node"))
    parser.add_argument("--output", type=Path, help="New evidence directory; never overwritten")
    parser.add_argument("--system-diagnostics", action="store_true",
                        help="Also collect verbose simulator sysdiagnose on failure (can take ten minutes)")
    parser.add_argument("--ui-workers", type=int, choices=[1, 2], default=2,
                        help="Isolated workers per device family (default: 2; use 1 to reduce resource use)")
    args = parser.parse_args()
    if not args.node:
        parser.error("Node is required; supply --node /absolute/path/to/node")
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
    available = {d["udid"]: d for group in devices["devices"].values() for d in group}
    runtimes = {d["udid"]: runtime for runtime, group in devices["devices"].items() for d in group}
    for udid, kind in [(args.iphone, "iPhone"), (args.ipad, "iPad")]:
        if udid not in available or kind not in (
            available[udid].get("deviceTypeIdentifier", "") + available[udid]["name"]
        ):
            parser.error(f"{udid} must identify an available {kind} simulator")
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = (args.output or ROOT / ".artifacts" / f"release-{stamp}").resolve()
    output.mkdir(parents=True, exist_ok=False)
    report = {"status": "RUNNING", "startedAt": stamp,
              "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "sourceFingerprint": source_fingerprint(), "stages": [],
              "manualGates": ["Physical camera capture and permission deny/allow",
                              "Physical-device file protection, biometrics and background privacy",
                              "Sandbox purchase/restore/refund on a distribution build",
                              "Real-account iCloud metadata sync/delete/conflict recovery across two devices",
                              "Minimum supported iOS and current iOS on iPhone/iPad",
                              "Large scanned PDFs: memory, cancellation and OCR quality",
                              "Signed archive, external sharing, App Store metadata and privacy URLs"]}

    report_lock = threading.RLock()
    owned_simulators = []

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
        bundle = output / f"{name}.xcresult"
        invocation = (["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun)] if xctestrun else
                      ["xcodebuild", "test", "-project", "PaperPath.xcodeproj", "-scheme", scheme,
                       "-derivedDataPath", str(output / "DerivedData")])
        stage = run(name, [*invocation, "-destination", f"platform=iOS Simulator,id={udid}",
                           "-parallel-testing-enabled", "NO", "-enableCodeCoverage", "YES",
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
        current = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"]))
        state = next(d["state"] for group in current["devices"].values() for d in group if d["udid"] == udid)
        if state != "Booted":
            if not run(f"boot-{label}", ["xcrun", "simctl", "boot", udid])["passed"]:
                raise RuntimeError(f"Could not boot {label}")
        if not run(f"ready-{label}", ["xcrun", "simctl", "bootstatus", udid, "-b"])["passed"]:
            raise RuntimeError(f"Simulator {label} did not become ready")

    save()
    try:
        run("gate-tests", [sys.executable, "-m", "unittest", "discover", "-s", "tools", "-p", "test_release_checks.py"])
        run("feature-contract", [args.node, "tools/CheckAutomationCoverage.mjs"])
        unit_tests = test_inventory("PaperPathTests")
        commerce_tests = {f"ReleaseReadinessUITests/{test}()" for test in COMMERCE_TESTS}
        ui_tests = test_inventory("PaperPathUITests") - commerce_tests
        build = run("test-build", ["xcodebuild", "build-for-testing", "-project", "PaperPath.xcodeproj",
                                   "-scheme", "PaperPath", "-destination", f"platform=iOS Simulator,id={args.iphone}",
                                   "-enableCodeCoverage", "YES", "-derivedDataPath", str(output / "DerivedData")])
        test_runs = list((output / "DerivedData/Build/Products").glob("PaperPath_*.xctestrun"))
        if not build["passed"] or len(test_runs) != 1:
            raise RuntimeError("Test build did not produce exactly one runnable test configuration")
        test_run = test_runs[0]
        preboot(args.iphone, "unit-iphone")
        units = suite("unit", "PaperPath", args.iphone, ["-only-testing:PaperPathTests"],
                      len(unit_tests) - 1, unit_tests, [DEVICE_ONLY], xctestrun=test_run)
        # Coverage is checked independently of test success. Neither substitutes for the other.
        try:
            read_json(["xcrun", "xccov", "view", "--report", "--json", str(units)], output / "coverage.json")
            run("coverage-contract", [args.node, "tools/CheckCodeCoverage.mjs", str(output / "coverage.json")])
        except (subprocess.CalledProcessError, ValueError) as error:
            report["stages"].append({"name": "coverage-contract", "passed": False, "error": str(error)})
        jobs = []
        for family, seed, tests in [("iphone", args.iphone, ui_tests - IPAD_ONLY), ("ipad", args.ipad, ui_tests)]:
            for index, expected in enumerate(partition_tests(tests, args.ui_workers)):
                device = seed
                if index:
                    device = subprocess.check_output(
                        ["xcrun", "simctl", "create", f"PaperPath Release {family} {stamp}-{index}",
                         available[seed]["deviceTypeIdentifier"], runtimes[seed]], text=True).strip()
                    owned_simulators.append(device)
                name = f"ui-{family}-{index + 1}"
                # Finish each boot before beginning the next one. Simultaneous
                # first boots can stall simulator application launches.
                preboot(device, name)
                selection = [f"-only-testing:PaperPathUITests/{test.removesuffix('()')}" for test in expected]
                jobs.append((name, device, selection, expected))
        report["temporarySimulators"] = owned_simulators[:]
        save()
        with ThreadPoolExecutor(max_workers=args.ui_workers * 2) as pool:
            futures = [pool.submit(suite, name, "PaperPath", device, selection, len(expected), expected,
                                   xctestrun=test_run) for name, device, selection, expected in jobs]
            for future in futures:
                future.result()
        suite("commerce", "PaperPathCommerce", args.iphone, [], len(commerce_tests), commerce_tests)
        run("release-build", ["xcodebuild", "build", "-project", "PaperPath.xcodeproj", "-scheme", "PaperPath",
                              "-configuration", "Release", "-destination", f"platform=iOS Simulator,id={args.iphone}",
                              "-derivedDataPath", str(output / "DerivedData")])
        unchanged = source_fingerprint() == report["sourceFingerprint"]
        report["sourceUnchangedDuringRun"] = unchanged
        report["status"] = ("AUTOMATION_PASSED_MANUAL_REQUIRED" if unchanged and
                            all(s.get("passed") for s in report["stages"]) else "FAILED")
    except (Exception, KeyboardInterrupt) as error:
        report["status"] = "INTERRUPTED" if isinstance(error, KeyboardInterrupt) else "FAILED"
        report["error"] = str(error)
    finally:
        for device in owned_simulators:
            subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True)
            subprocess.run(["xcrun", "simctl", "delete", device], capture_output=True)
        save()
        print(f"{report['status']}: {output / 'report.json'}", flush=True)
    return 0 if report["status"] == "AUTOMATION_PASSED_MANUAL_REQUIRED" else 1


if __name__ == "__main__":
    sys.exit(main())
