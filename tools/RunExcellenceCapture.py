#!/usr/bin/env python3
"""Focused visual/interaction journey. Must run under the shared simulator gate."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("name")
parser.add_argument("--appearance", choices=["light", "dark"], default="light")
parser.add_argument("--large-text", action="store_true")
parser.add_argument("--chinese", action="store_true")
args = parser.parse_args()
udid = os.environ["CODEX_SIMULATOR_UDID"]
assert udid in ["2A313B9A-7363-4AE1-ADFB-2CDF0F680653", "FCC639C3-8DDF-4C6D-966E-773238C82805"]
out = ROOT / ".artifacts/excellence-20261030" / args.name
out.mkdir(parents=True, exist_ok=False)
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"]))
assert next(d for rows in devices["devices"].values() for d in rows if d["udid"] == udid)["state"] == "Shutdown"

def sim(*command):
    return subprocess.run(["xcrun", "simctl", *command], check=True)

original = None
try:
    sim("boot", udid)
    sim("bootstatus", udid, "-b")
    appearance = subprocess.check_output(["xcrun", "simctl", "ui", udid, "appearance"], text=True)
    original = re.findall(r"\b(light|dark)\b", appearance)[-1]
    sim("ui", udid, "appearance", args.appearance)
    command = ["xcodebuild", "test-without-building", "-project", "PaperPath.xcodeproj", "-scheme", "PaperPath",
               "-configuration", "Debug", "-derivedDataPath", ".artifacts/quality-15/DerivedData",
               "-destination", f"platform=iOS Simulator,id={udid}", "-parallel-testing-enabled", "NO",
               "-maximum-concurrent-test-simulator-destinations", "1", "-maximum-parallel-testing-workers", "1",
               "-disableAutomaticPackageResolution", "-collect-test-diagnostics", "never",
               "-only-testing:PaperPathUITests/PaperPathUITests/testExcellenceDocumentDeskAndToolJourney" + ("ChineseLargeText" if args.chinese else "LargeText" if args.large_text else ""),
               "-resultBundlePath", str(out / "capture.xcresult"), "CODE_SIGNING_ALLOWED=NO"]
    env = dict(os.environ)
    with (out / "test.log").open("w") as log:
        result = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(out / "capture.xcresult"),
                    "--output-path", str(out / "attachments")], check=True)
    raise SystemExit(result.returncode)
finally:
    try:
        if original:
            sim("ui", udid, "appearance", original)
    finally:
        sim("shutdown", udid)
