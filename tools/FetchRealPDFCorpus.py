#!/usr/bin/env python3
"""Fetch only the eight hash-pinned release PDFs, with an 8 MiB/file budget.

No simulator, runtime or model downloads. Existing matching files are reused.
Use --direct only when the shell's proxy is unavailable; no system settings change.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / 'PaperPathTests/Fixtures/RealPDFCorpus'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--direct', action='store_true')
    args = parser.parse_args()
    rows = json.loads((CORPUS / 'manifest.json').read_text())['documents']
    assert sum(row['bytes'] for row in rows) <= 8 * 1024 * 1024
    for row in rows:
        destination = CORPUS / row['file']
        def valid(path):
            return path.exists() and path.stat().st_size == row['bytes'] and hashlib.sha256(path.read_bytes()).hexdigest() == row['sha256']
        if valid(destination):
            print('Cached:', row['file'])
            continue
        with tempfile.TemporaryDirectory(prefix='paperpath-pdf-fetch-') as temporary:
            staging = Path(temporary) / row['file']
            command = ['curl', '-fsSL', '--connect-timeout', '10', '--max-time', '60', '--max-filesize', str(8 * 1024 * 1024)]
            if args.direct:
                command += ['--noproxy', '*']
            subprocess.run(command + [row['url'], '-o', str(staging)], check=True)
            if not valid(staging):
                raise RuntimeError(f"Hash or size mismatch for {row['file']}; review source changes explicitly")
            destination.write_bytes(staging.read_bytes())
            print('Verified:', row['file'])
    print(f'{len(rows)} original PDFs, {sum(r["bytes"] for r in rows):,} bytes. No network used by XCTest.')


if __name__ == '__main__':
    main()
