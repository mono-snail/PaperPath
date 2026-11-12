#!/usr/bin/env python3
"""Run only through the shared simulator guard; preserves existing simulator data."""
import os, subprocess, shutil, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
UDID=os.environ['CODEX_SIMULATOR_UDID']
APP=Path('/tmp/PaperPathHeroBuild/Build/Products/Debug-iphonesimulator/PaperPath.app')
name='ipad' if UDID=='FCC639C3-8DDF-4C6D-966E-773238C82805' else 'phone'
assert UDID in ['FCC639C3-8DDF-4C6D-966E-773238C82805','2A313B9A-7363-4AE1-ADFB-2CDF0F680653']
OUT=ROOT/'design/hero-2026-10-28'
result=OUT/f'{name}{sys.argv[1] if len(sys.argv)>1 else ""}.xcresult'
if result.exists():raise SystemExit(f'Preserve previous result: {result}')
def run(*args,**kwargs):return subprocess.run(args,check=True,**kwargs)
try:
    run('xcrun','simctl','boot',UDID)
    run('xcrun','simctl','bootstatus',UDID,'-b')
    run('xcrun','simctl','install',UDID,str(APP))
    container=subprocess.check_output(['xcrun','simctl','get_app_container',UDID,'com.monoware.paperpath','data'],text=True).strip()
    fixtures=Path(container)/'Documents/HeroFixtures';fixtures.mkdir(parents=True,exist_ok=True)
    for f in (ROOT/'output/pdf').glob('*.pdf'):
        if f.name in ['Riverside Garden.pdf','Project Approval.pdf']:shutil.copy2(f,fixtures/f.name)
    run('xcrun','simctl','status_bar',UDID,'override','--time','9:41','--dataNetwork','wifi','--wifiMode','active','--wifiBars','3','--batteryState','charged','--batteryLevel','100')
    run('xcodebuild','test-without-building','-project',str(ROOT/'PaperPath.xcodeproj'),'-scheme','PaperPath','-configuration','Debug','-derivedDataPath','/tmp/PaperPathHeroBuild','-destination',f'platform=iOS Simulator,id={UDID}','-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1','-maximum-parallel-testing-workers','1','-only-testing:PaperPathUITests/PaperPathUITests/testMarketingHeroDocumentCapture','-resultBundlePath',str(result),'CODE_SIGNING_ALLOWED=NO')
finally:
    subprocess.run(['xcrun','simctl','status_bar',UDID,'clear'])
    subprocess.run(['xcrun','simctl','shutdown',UDID])
