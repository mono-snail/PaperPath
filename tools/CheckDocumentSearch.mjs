import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

// Run the production, Foundation-only search types on the host. No simulator,
// PDF generation, network, or copied implementation is involved.
const source = readFileSync('PaperPath/Services/DocumentUnderstandingService.swift', 'utf8');
const models = readFileSync('PaperPath/Models/DocumentModels.swift', 'utf8');
function slice(text, start, end) {
  const from = text.indexOf(start);
  const through = text.indexOf(end, from);
  assert(from >= 0 && through > from, 'Production type boundaries changed');
  return text.slice(from, through);
}
const result = spawnSync('xcrun', ['swift', '-'], {
  input: `
import Foundation
${slice(models, 'enum IndexedTextSource:', '\nenum DocumentUnderstandingConfidence:')}
${slice(source, 'enum DocumentSearchNormalization {', '\nstruct PDFTextIndexService:')}
let original = String(repeating: "Earlier context ", count: 20)
    + "PAY\\u{00ad}MENT Café invoice co-operate"
let index = DocumentTextIndex(source: .native,
    pages: [IndexedPageText(pageIndex: 3, text: original)], indexedAt: Date())
let match = index.firstMatch(for: "payment cafe", excerptLimit: 48)!
precondition(match.pageIndex == 3)
precondition(match.excerpt.contains("PAYMENT Café"))
precondition(!match.excerpt.contains("\\u{00ad}"))
precondition(match.excerpt.count <= 50)
precondition(index.pages.first!.text == original)
precondition(index.matches(for: "pay\\u{00ad}ment").count == 1)
let containsAll = try index.containsEveryTerm(["payment", "cafe"])
precondition(containsAll)
let cancellableMatches = try index.cancellableMatches(for: "payment")
precondition(cancellableMatches.count == 1)
precondition(index.matches(for: "cooperate").isEmpty)
precondition(index.matches(for: "co-operate").count == 1)
precondition(index.matches(for: "\\u{00ad}").isEmpty)
precondition(index.matches(for: "payment", limit: 0).isEmpty)
precondition(index.matches(for: "missing").isEmpty)
precondition(DocumentSearchNormalization.terms(in: "payment pay\\u{00ad}ment") == ["payment"])
precondition(DocumentSearchNormalization.text("ＰＡＹＭＥＮＴ CAFÉ") == "payment cafe")
let phrase = DocumentPhraseSearch(query: " payment cafe ")
precondition(phrase.matches("Earlier PAY\\u{00ad}MENT Café details"))
precondition(phrase.matches("Earlier ＰＡＹＭＥＮＴ Café details"))
precondition(DocumentPhraseSearch(query: "pay\\u{00ad}ment").matches("Payment"))
precondition(!phrase.matches("cafe payment"))
precondition(!phrase.matches("payment invoice cafe"))
precondition(!phrase.matches("payment\\ncafe"))
precondition(!DocumentPhraseSearch(query: "cooperate").matches("co-operate"))
precondition(!DocumentPhraseSearch(query: "").matches("Payment café"))
precondition(!DocumentPhraseSearch(query: " \\n ").matches("Payment café"))
precondition(!DocumentPhraseSearch(query: "\\u{00ad}").matches("Payment café"))
print("PASS: 25 production search checks; index and OCR phrase normalization, source preservation, excerpt bounds, empty queries, visible hyphens and phrase semantics")
`,
  encoding: 'utf8',
  timeout: 120_000,
});
process.stdout.write(result.stdout ?? '');
process.stderr.write(result.stderr ?? '');
if (result.error) throw result.error;
assert.equal(result.status, 0);
