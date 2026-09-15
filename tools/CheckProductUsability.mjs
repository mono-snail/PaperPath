import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const models = readFileSync('PaperPath/Models/DocumentModels.swift', 'utf8');
const extract = (startMarker, endMarker) => {
  const start = models.indexOf(startMarker);
  const end = models.indexOf(endMarker, start);
  assert(start >= 0 && end > start);
  return models.slice(start, end);
};
const result = spawnSync('xcrun', ['swift', '-'], {
  input: `
import Foundation
${extract('enum DocumentTextAvailability:', '\nstruct DocumentCommandSignal:')}
${extract('enum PDFBatchSelection {', '\nstruct PDFBatchDeliveryRun:')}
precondition(DocumentTextAvailability(isLocked: true, hasRecognizedText: true, textCoverage: 1, imagePageCount: 0) == .locked)
precondition(DocumentTextAvailability(isLocked: false, hasRecognizedText: true, textCoverage: 0, imagePageCount: 3) == .recognized)
precondition(DocumentTextAvailability(isLocked: false, hasRecognizedText: false, textCoverage: 0, imagePageCount: 3) == .imageOnly)
precondition(DocumentTextAvailability(isLocked: false, hasRecognizedText: false, textCoverage: 0.8, imagePageCount: 1) == .partial)
precondition(DocumentTextAvailability(isLocked: false, hasRecognizedText: false, textCoverage: 0.3, imagePageCount: 0) == .partial)
precondition(DocumentTextAvailability(isLocked: false, hasRecognizedText: false, textCoverage: 1, imagePageCount: 0) == .available)
precondition(DocumentTextAvailability(isLocked: false, hasRecognizedText: false, textCoverage: .nan, imagePageCount: 0) == .imageOnly)
precondition(!DocumentTextAvailability.recognized.needsRecognition)
let ids = (0..<70).map { _ in UUID() }
let requested = Set([ids[1], ids[4]])
let carried = PDFBatchSelection.adding(ids.filter { requested.contains($0) }, to: [])
precondition(carried == requested)
precondition(PDFBatchSelection.adding([], to: []).isEmpty)
precondition(PDFBatchSelection.adding(ids, to: []).count == 64)
print("PASS: 8 production text-state checks and 3 explicit-selection checks")
`,
  encoding: 'utf8',
  timeout: 120_000,
});
process.stdout.write(result.stdout ?? '');
process.stderr.write(result.stderr ?? '');
if (result.error) throw result.error;
assert.equal(result.status, 0);
