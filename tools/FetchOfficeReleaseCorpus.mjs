import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { basename, resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';

const original = JSON.parse(readFileSync('PaperPathTests/Fixtures/OfficeInteropCorpus/manifest.json', 'utf8'));
const target = resolve(process.argv[2] ?? 'design/office-release-2026-09-14');
mkdirSync(`${target}/originals`, { recursive: true });
const documents = [];
for (const document of original.documents) {
  const name = basename(document.path);
  execFileSync('curl', ['-fLsS', '--max-time', '45', '--retry', '1',
    '-o', `${target}/originals/${name}`, document.source], { stdio: 'inherit' });
  const sha256 = createHash('sha256').update(readFileSync(`${target}/originals/${name}`)).digest('hex');
  if (sha256 !== document.sha256) throw new Error(`Upstream changed: ${name}; inspect before accepting`);
  documents.push({ ...document, path: `originals/${name}`, retrievedAt: new Date().toISOString() });
  console.log(`VERIFIED ${name}`);
}
writeFileSync(`${target}/source-manifest.json`, JSON.stringify({
  source: original.source, repository: original.repository, license: original.license,
  retrievedFor: 'Office -> reference PDF -> PaperPath Office -> independent PDF rendering',
  documents
}, null, 2) + '\n');
