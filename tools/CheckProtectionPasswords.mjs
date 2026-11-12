import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const models = readFileSync('PaperPath/Models/DocumentModels.swift', 'utf8');
const view = readFileSync('PaperPath/Views/DocumentOutputSheets.swift', 'utf8');
function slice(source, start, end) {
  const a = source.indexOf(start);
  const b = source.indexOf(end, a);
  assert(a >= 0 && b > a, 'Production validation type boundary changed');
  return source.slice(a, b);
}
const validation = slice(models, 'enum PDFProtectionPasswordValidation {', '\nenum PDFCompressionBatchOutputState:');
const properties = slice(view, '    private var validationMessage:', '    var body: some View {')
  .replaceAll('private var', 'var');
const workspace = readFileSync('PaperPath/Views/DocumentWorkspaceView.swift', 'utf8');
function closureBody(start, end) {
  const closure = slice(workspace, start, end);
  return closure.slice(closure.indexOf('\n') + 1, closure.lastIndexOf('}'));
}
const unlockChange = closureBody('.onChange(of: unlockInput) {', '                .onChange(\n                    of: model.record');
const unlockPaste = closureBody('PasteButton(payloadType: String.self) { values in', '        .frame(minWidth: 44, minHeight: 44)');
const result = spawnSync('xcrun', ['swift', '-'], {
  input: `
import Foundation
${validation}
struct Form {
    enum PasswordField { case password, confirmation }
    let password: String
    let confirmation: String
    let focusedPasswordField: PasswordField?
${properties}
}
struct UnlockDraft {
    var unlockInput: String
    var unlockErrorMessage: String? = "Wrong password"
    mutating func changed() {
${unlockChange}
    }
    mutating func pasted(_ values: [String]) {
${unlockPaste}
    }
}
let prefix = String(repeating: "p", count: 128)
func form(_ password: String, _ confirmation: String, _ focus: Form.PasswordField? = nil) -> Form {
    Form(password: password, confirmation: confirmation, focusedPasswordField: focus)
}
precondition(form("", "").validationMessage == nil)
precondition(form("12345678", "12345678").validationMessage == nil)
precondition(form(prefix, prefix).validationMessage == nil)
precondition(form("1234567", "1234567").validationMessage != nil)
precondition(form(prefix + "A", prefix + "B").validationMessage != nil)
precondition(form(prefix + "A", prefix + "A").validationMessage != nil)
precondition(form(prefix, prefix + "A").validationMessage != nil)
precondition(form(" password", "password").validationMessage != nil)
precondition(form(prefix + "A", "", .password).visibleValidationMessage != nil)
precondition(form(prefix, prefix + "A", .confirmation).visibleValidationMessage != nil)
precondition(form("12345678", "").visibleValidationMessage == nil)
precondition(form("12345678", "1234", .confirmation).visibleValidationMessage == nil)
print("PASS: 12 production password/form checks; length, mismatch, shared prefixes, whitespace and focused-field error visibility")
for input in ["", prefix, prefix + "A", prefix + "B", String(repeating: "密", count: 150), " password "] {
    var draft = UnlockDraft(unlockInput: input)
    draft.changed()
    precondition(draft.unlockInput == input)
    precondition(draft.unlockErrorMessage == nil)
    draft.pasted([input])
    precondition(draft.unlockInput == input)
}
var unchanged = UnlockDraft(unlockInput: "retained")
unchanged.pasted([])
precondition(unchanged.unlockInput == "retained")
print("PASS: 19 production unlock-draft checks; full typed and pasted passwords, Unicode, spaces, error reset and empty paste")
`, encoding: 'utf8', timeout: 120_000,
});
process.stdout.write(result.stdout ?? '');
process.stderr.write(result.stderr ?? '');
if (result.error) throw result.error;
assert.equal(result.status, 0);
