#!/usr/bin/env python3
"""Copy whole, unedited runtime screenshots and record their source hashes."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / ".artifacts/excellence-20261030"
OUTPUT = ROOT / "design/excellence-2026-10-30"
CASES = {
    "phone-final-light-v2": "phone-light",
    "phone-final-dark": "phone-dark",
    "phone-final-dark-zh-ax": "phone-dark-zh-ax",
    "ipad-final-light": "ipad-light",
}
NAMES = {
    "Excellence document desk": "library",
    "Excellence document workspace": "reader",
    "Excellence reading appearance": "style",
    "Excellence text reader": "text",
    "Excellence unavailable favorite": "unavailable-favorite",
    "Excellence suggested tools": "tools",
    "Excellence no matching tools": "search-empty",
    "Excellence tool search": "search",
    "Excellence annotation review": "annotations",
}
results = []
for case, prefix in CASES.items():
    source = ARTIFACTS / case
    summary = json.loads(subprocess.check_output([
        "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(source / "capture.xcresult")
    ]))
    assert summary["failedTests"] == 0 and summary["passedTests"] == 1 and summary["skippedTests"] == 0, summary
    images = []
    for test in json.loads((source / "attachments/manifest.json").read_text()):
        for attachment in test["attachments"]:
            title = attachment["suggestedHumanReadableName"].split("_0_")[0]
            if title not in NAMES or not attachment["exportedFileName"].endswith(".png"):
                continue
            original = source / "attachments" / attachment["exportedFileName"]
            destination = OUTPUT / f"{prefix}-{NAMES[title]}.png"
            shutil.copy2(original, destination)
            digest = hashlib.sha256(original.read_bytes()).hexdigest()
            assert hashlib.sha256(destination.read_bytes()).hexdigest() == digest
            images.append({"title": title, "file": str(destination.relative_to(ROOT)),
                           "source": str(original.relative_to(ROOT)), "sha256": digest,
                           "udid": attachment["deviceId"]})
    results.append({"case": case, "summary": summary, "images": images})
(ARTIFACTS / "final-results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))
(OUTPUT / "screenshots-manifest.json").write_text(json.dumps(
    [{"case": r["case"], "images": r["images"]} for r in results], ensure_ascii=False, indent=2))
print(f"Verified {len(results)} passing journeys and copied {sum(len(r['images']) for r in results)} whole screenshots.")
