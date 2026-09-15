import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const source = readFileSync('PaperPath/Models/DocumentModels.swift', 'utf8');
const start = source.indexOf('enum PDFBatchSelection {');
const end = source.indexOf('\nstruct PDFBatchDeliveryRun:', start);
assert(start >= 0 && end > start);
const result = spawnSync('xcrun', ['swift', '-'], {
  input: `
import Foundation
${source.slice(start, end)}
let ids = (0..<100).map { _ in UUID() }
let outside = Set(ids.prefix(3))
let matches = Array(ids[10..<80])
let added = PDFBatchSelection.adding(matches, to: outside)
precondition(added.count == 64)
precondition(outside.isSubset(of: added))
precondition(added.subtracting(matches) == outside)
precondition(PDFBatchSelection.adding([], to: outside) == outside)
precondition(PDFBatchSelection.adding([ids[0], ids[0]], to: outside) == outside)
precondition(PDFBatchSelection.adding(matches, to: outside, limit: 0) == outside)
precondition(PDFBatchSelection.adding(matches, to: outside, limit: -1) == outside)
precondition(PDFBatchSelection.adding(matches, to: added) == added)
precondition(PDFBatchSelection.adding(Array(ids[10..<15]), to: outside).count == 8)
precondition(PDFBatchSelection.adding([ids[0], ids[3]], to: outside, limit: 4).count == 4)
print("PASS: 10 production selection checks; matching additions preserve outside selection and capacity")
`,
  encoding: 'utf8',
  timeout: 120_000,
});
process.stdout.write(result.stdout ?? '');
process.stderr.write(result.stderr ?? '');
if (result.error) throw result.error;
assert.equal(result.status, 0, 'Recovery workflow checks failed');
