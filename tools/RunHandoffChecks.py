#!/usr/bin/env python3
"""Foreground-only handoff checks. Invoke only inside the shared simulator gate."""
import argparse
import json
import os
import re
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--ipad", action="store_true")
    parser.add_argument("--node", default="node")
    args = parser.parse_args()
    udid = os.environ.get("CODEX_SIMULATOR_UDID")
    if not udid:
        raise SystemExit("Run through /Users/yanjun/.codex/simulators/guard.py run")
    pool = json.loads(Path("/Users/yanjun/.codex/simulators/pool.json").read_text())
    slot = "ios26-ipad" if args.ipad else "ios26-phone"
    if udid != pool["slots"][slot]["udid"]:
        raise SystemExit("The gate lease does not match the requested registered slot")
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    if (output / "Tests.xcresult").exists():
        raise SystemExit("Use a new output directory; preserve prior test results")
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"]))
    device = next(d for group in devices["devices"].values() for d in group if d["udid"] == udid)
    booted_here = device["state"] != "Booted"
    original_appearance = None
    try:
        if booted_here:
            subprocess.run(["xcrun", "simctl", "boot", udid], check=True)
        subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True)
        appearance = subprocess.check_output(["xcrun", "simctl", "ui", udid, "appearance"], text=True)
        original_appearance = re.findall(r"\b(light|dark)\b", appearance)[-1]
        subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", "light"], check=True)
        subprocess.run([args.node, "tools/CheckAutomationCoverage.mjs"], check=True)
        selections = ["PaperPathUITests/HandoffWorkflowUITests/testHandoffRulesAndPacketJourneySurvivesReentryAndExports"] if args.ipad else [
            "PaperPathTests/HandoffWorkflowTests",
            "PaperPathTests/PrivacyRedactionShareTests",
            "PaperPathUITests/HandoffWorkflowUITests/testHandoffRulesAndPacketJourneySurvivesReentryAndExports",
            "PaperPathUITests/HandoffWorkflowUITests/testDuplicatePDFIsBlockedAndRuleEditInvalidatesConfirmation",
            "PaperPathUITests/ReleaseReadinessUITests/testPaidDownloadHasNoTrialOrPurchaseFlow",
        ]
        command = [
            "xcodebuild", "test", "-project", "PaperPath.xcodeproj", "-scheme", "PaperPath",
            "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={udid}",
            "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
            "-maximum-parallel-testing-workers", "1", "-disableAutomaticPackageResolution", "-skipPackageUpdates",
            "-derivedDataPath", "output/handoff-20261104/DerivedData", "-resultBundlePath", str(output / "Tests.xcresult"),
            "CODE_SIGNING_ALLOWED=NO", "ONLY_ACTIVE_ARCH=YES", "ARCHS=arm64",
        ]
        for selection in selections:
            command += ["-only-testing:" + selection]
        (output / "command.json").write_text(json.dumps(command, indent=2))
        print(f"Testing on registered {slot}: {udid}", flush=True)
        with (output / "tests.log").open("w") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
        for line in (output / "tests.log").read_text().splitlines():
            if " error:" in line or " failed" in line or "Executed " in line or "** TEST" in line:
                print(line, flush=True)
        if result.returncode:
            raise SystemExit(result.returncode)
        if not args.ipad:
            subprocess.run([args.node, "tools/CheckAutomationCoverage.mjs"], check=True)
            subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", "dark"], check=True)
            dark = command[:]
            dark[dark.index("test")] = "test-without-building"
            dark[dark.index("-resultBundlePath") + 1] = str(output / "Dark.xcresult")
            dark = [arg for arg in dark if not arg.startswith("-only-testing:")]
            dark += ["-only-testing:PaperPathUITests/HandoffWorkflowUITests/testChineseDarkLargeTextPacketAndRuleScreens"]
            (output / "dark-command.json").write_text(json.dumps(dark, indent=2))
            with (output / "dark-tests.log").open("w") as log:
                result = subprocess.run(dark, stdout=log, stderr=subprocess.STDOUT)
            for line in (output / "dark-tests.log").read_text().splitlines():
                if " error:" in line or " failed" in line or "Executed " in line or "** TEST" in line:
                    print(line, flush=True)
            if result.returncode:
                raise SystemExit(result.returncode)
    finally:
        if original_appearance:
            subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", original_appearance], check=False)
        if booted_here:
            subprocess.run(["xcrun", "simctl", "shutdown", udid], check=False)


if __name__ == "__main__":
    main()
