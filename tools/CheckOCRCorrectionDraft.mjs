import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const source = readFileSync('PaperPath/Views/RecognizedTextView.swift', 'utf8');
const a = source.indexOf('private struct OCRTextCorrectionSheet: View {');
const b = source.indexOf('\nstruct OCRConfigurationSheet:', a);
assert(a >= 0 && b > a);
const editor = source.slice(a, b);
function slice(start, end) {
  const from = editor.indexOf(start);
  const to = editor.indexOf(end, from);
  assert(from >= 0 && to > from, 'Production correction source boundary changed');
  return editor.slice(from + start.length, to);
}
const changed = slice('.onChange(of: text) {', '\n            .task {');
const pasteStart = editor.indexOf('PasteButton(');
const pasteBody = editor.indexOf(') {', pasteStart);
const pasteEnd = editor.indexOf('\n                        .labelStyle', pasteBody);
assert(pasteStart >= 0 && pasteBody > pasteStart && pasteEnd > pasteBody);
const paste = editor.slice(pasteBody + ') {'.length, pasteEnd);
const properties = 'var correctionValue: String {' + slice('private var correctionValue: String {', '    private func requestCorrectionDismissal()')
  .replaceAll('private var', 'var');
const result = spawnSync('xcrun', ['swift', '-'], {
  input: `
import Foundation
var text = "Original"
let committedText = "Original"
var saveErrorMessage: String? = "Old error"
var saveStatusMessage: String? = "Saved"
${properties}
let paste: ([String]) -> Void = { ${paste}
let changed: (String, String) -> Void = { ${changed}
paste([])
precondition(text == "Original")
let longDraft = String(repeating: "n", count: 501) + "TAIL-KEPT"
paste([longDraft])
precondition(text == longDraft)
precondition(hasCorrectionChanges)
precondition(correctionValue.count > 500)
changed("Original", longDraft)
precondition(text == longDraft)
precondition(saveErrorMessage == nil)
precondition(saveStatusMessage == nil)
text = String(repeating: "n", count: 500)
changed(longDraft, text)
precondition(correctionValue.count == 500)
precondition(hasCorrectionChanges)
text = " Original \\n"
precondition(correctionValue == "Original")
precondition(!hasCorrectionChanges)
print("PASS: 11 production OCR correction draft checks; complete paste, edit retention, limit boundary, status reset and existing whitespace semantics")
`, encoding: 'utf8', timeout: 120_000,
});
process.stdout.write(result.stdout ?? '');
process.stderr.write(result.stderr ?? '');
if (result.error) throw result.error;
assert.equal(result.status, 0);
