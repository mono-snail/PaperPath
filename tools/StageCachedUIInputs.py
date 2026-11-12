"""Offline fixture staging draft; requires an existing foreground simulator lease."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys


def stage(root, output):
    pool = json.loads(Path('/Users/yanjun/.codex/simulators/pool.json').read_text())
    udid = os.environ.get('CODEX_SIMULATOR_UDID')
    if not udid or udid not in [row['udid'] for row in pool['slots'].values()]:
        raise SystemExit('Fixture staging requires the registered foreground simulator lease')
    source_root = root / 'PaperPathTests/Fixtures/RealPDFCorpus'
    manifest_bytes = (source_root / 'manifest.json').read_bytes()
    manifest = json.loads(manifest_bytes)
    for row in manifest['documents']:
        name = row['file']
        if Path(name).name != name or not name.endswith('.pdf'):
            raise SystemExit('Unsafe fixture name')
        if hashlib.sha256((source_root/name).read_bytes()).hexdigest() != row['sha256']:
            raise SystemExit('Cached fixture hash mismatch; no download performed')
    container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container',
        udid, 'com.monoware.paperpath', 'data'], text=True).strip())
    destination = container / 'Documents/QualityInputCorpus'
    if destination.is_symlink():
        raise SystemExit('Preserve unexpected fixture symlink')
    destination.mkdir(parents=True, exist_ok=True)
    staged = []
    def copy_checked(source, target):
        if target.is_symlink():
            raise SystemExit('Preserve unexpected target symlink')
        if target.exists():
            if hashlib.sha256(target.read_bytes()).digest() != hashlib.sha256(source.read_bytes()).digest():
                raise SystemExit('Preserve unexpected existing input: '+str(target))
        else:
            shutil.copyfile(source, target)
        staged.append(str(target))
    for row in manifest['documents']:
        copy_checked(source_root/row['file'], destination/row['file'])
    copy_checked(source_root/'manifest.json', destination/'manifest.json')
    inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '--json']))
    device = next(d for group in inventory['devices'].values() for d in group if d['udid'] == udid)
    providers = []
    groups = Path(device['dataPath'])/'Containers/Shared/AppGroup'
    for metadata in groups.glob('*/.com.apple.mobile_container_manager.metadata.plist'):
        with metadata.open('rb') as stream:
            if plistlib.load(stream).get('MCMMetadataIdentifier') == 'group.com.apple.FileProvider.LocalStorage':
                providers.append(metadata.parent/'File Provider Storage')
    if len(providers) != 1 or not providers[0].is_dir():
        raise SystemExit('Existing local Files provider unavailable; no fallback provisioning')
    folder = providers[0]/'PaperPath Core Inputs'
    if folder.is_symlink():
        raise SystemExit('Preserve unexpected Files input symlink')
    folder.mkdir(exist_ok=True)
    copy_checked(source_root/'ocr-jbig2.pdf', folder/'ocr-jbig2.pdf')
    output.write_text(json.dumps({'udid':udid,'offline':True,'paths':staged},indent=2)+'\n')


if __name__ == '__main__':
    stage(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
