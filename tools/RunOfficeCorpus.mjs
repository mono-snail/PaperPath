import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const [device, application, directory] = process.argv.slice(2);
if (!device || !application || !directory) {
  throw new Error('Usage: node tools/RunOfficeCorpus.mjs UDID APP_PATH EVIDENCE_DIRECTORY');
}
const root = resolve(directory);
if (existsSync(`${root}/report.json`)) {
  throw new Error('Use a new evidence directory; existing reports are not overwritten.');
}
const simctl = (...args) => execFileSync('xcrun', ['simctl', ...args], {
  encoding: 'utf8', timeout: 120_000,
});
console.log('Installing the production Debug build');
simctl('install', device, resolve(application));
const container = simctl('get_app_container', device, 'com.monoware.paperpath', 'data').trim();
const corpus = `${container}/Documents/OfficeCorpus`;
mkdirSync(`${corpus}/inputs`, { recursive: true });
const oldRun = existsSync(`${corpus}/report.json`)
  ? JSON.parse(readFileSync(`${corpus}/report.json`, 'utf8')).runID : null;
cpSync(`${root}/reference`, `${corpus}/inputs`, { recursive: true });
cpSync(`${root}/cases.json`, `${corpus}/cases.json`);
console.log(simctl('launch', '--terminate-running-process', device,
  'com.monoware.paperpath', 'DEVICE_OFFICE_CORPUS').trim());
const deadline = Date.now() + 600_000;
while (Date.now() < deadline) {
  await new Promise(resolve => setTimeout(resolve, 5000));
  if (!existsSync(`${corpus}/report.json`)) continue;
  const report = JSON.parse(readFileSync(`${corpus}/report.json`, 'utf8'));
  if (report.runID === oldRun) continue;
  console.log(`${report.status}: ${report.results?.length ?? 0} cases; ${report.results?.at(-1)?.id ?? ''}`);
  if (report.status === 'failed') throw new Error(report.error);
  if (report.status !== 'completed') continue;
  cpSync(`${corpus}/report.json`, `${root}/report.json`);
  for (const item of report.results) {
    if (!item.output) continue;
    const destination = resolve(root, item.output);
    if (!destination.startsWith(root + '/')) throw new Error('Invalid output path');
    mkdirSync(resolve(destination, '..'), { recursive: true });
    cpSync(resolve(corpus, item.output), destination);
  }
  const failures = report.results.filter(item => item.error);
  if (failures.length) throw new Error(JSON.stringify(failures));
  console.log(`PASS: ${report.results.length} production exports saved in ${root}`);
  process.exit(0);
}
throw new Error('Corpus run timed out after 10 minutes; inspect the simulator report.');
