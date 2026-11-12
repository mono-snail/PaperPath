import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const models = readFileSync('PaperPath/Models/DocumentModels.swift', 'utf8');
const view = readFileSync('PaperPath/Views/DocumentOutputSheets.swift', 'utf8');
function slice(source, start, end) {
  const a = source.indexOf(start);
  const b = source.indexOf(end, a);
  assert(a >= 0 && b > a, 'Production type boundary changed');
  return source.slice(a, b);
}
const state = slice(models, 'enum PDFCompressionBatchOutputState:', '\nenum PDFPageNumberInput {');
// Inject result counts into the actual production display properties. This
// checks failure wording without performing expensive PDF compression or UI work.
const properties = slice(view, '    private var batchOutputState:', '    private var batchResultDetail:')
  + slice(view, '    private var formattedResultOutputSize:', '    private var resultSavings:');
const result = spawnSync('xcrun', ['swift', '-'], {
  input: `
import Foundation
extension String { var localizedUI: String { self } }
enum AppLocalization {
    static func format(_ format: String, _ arguments: CVarArg...) -> String {
        String(format: format, arguments: arguments)
    }
}
${state}
struct Summary {
    let successfulCount: Int
    let alreadyOptimizedCount: Int
    let failedCount: Int
    let resultOutputBytes: Int64 = 1024
    var results: [Int] { Array(repeating: 0, count: successfulCount + alreadyOptimizedCount + failedCount) }
${properties.replaceAll('private var', 'var')}
}
let failure = Summary(successfulCount: 0, alreadyOptimizedCount: 0, failedCount: 2)
precondition(failure.batchResultTitle == "Compression failed")
precondition(failure.formattedResultOutputSize == "No compressed output")
let unchanged = Summary(successfulCount: 0, alreadyOptimizedCount: 2, failedCount: 0)
precondition(unchanged.batchResultTitle == "Originals already smaller")
precondition(unchanged.formattedResultOutputSize == "No change needed")
let partial = Summary(successfulCount: 0, alreadyOptimizedCount: 1, failedCount: 1)
precondition(partial.batchOutputState == .unavailable)
precondition(partial.formattedResultOutputSize == "No compressed output")
let success = Summary(successfulCount: 1, alreadyOptimizedCount: 1, failedCount: 1)
precondition(success.batchOutputState == .compressed)
precondition(success.formattedResultOutputSize == ByteCountFormatter.string(fromByteCount: 1024, countStyle: .file))
precondition(Summary(successfulCount: 0, alreadyOptimizedCount: 0, failedCount: 0).batchOutputState == .unavailable)
print("PASS: 9 production batch-summary checks; all failed, unchanged, mixed, successful and empty outcomes")
`, encoding: 'utf8', timeout: 120_000,
});
process.stdout.write(result.stdout ?? '');
process.stderr.write(result.stderr ?? '');
if (result.error) throw result.error;
assert.equal(result.status, 0);
