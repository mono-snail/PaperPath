import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const source = readFileSync('PaperPath/Models/DocumentModels.swift', 'utf8');
const start = source.indexOf('enum PDFDeliveryPreflightStatus:');
const end = source.indexOf('\nstruct PDFDeliveryPreflightCacheEntry:', start);
assert(start >= 0 && end > start, 'Production preflight models not found');
const result = spawnSync('xcrun', ['swift', '-'], {
  input: `
import Foundation
${source.slice(start, end)}
func assessment(_ status: PDFDeliveryPreflightStatus, _ items: [PDFDeliveryPreflightItem]) -> PDFDeliveryPreflightAssessment {
    PDFDeliveryPreflightAssessment(status: status, pageCount: 1, byteCount: 100, fixCount: 0, reviewCount: 0, items: items)
}
let passed = PDFDeliveryPreflightItem(id: "passed", title: "Passed", detail: "", status: .passed)
let repair = PDFDeliveryPreflightItem(id: "repair", title: "Repair", detail: "", status: .willFix)
let unlocated = PDFDeliveryPreflightItem(id: "unknown", title: "Incomplete", detail: "Not fully checked", status: .review)
let located = PDFDeliveryPreflightItem(id: "form", title: "Form", detail: "Unfinished", status: .review, reviewPageIndex: 0)
let blocked = PDFDeliveryPreflightItem(id: "locked", title: "Locked", detail: "Unlock first", status: .blocked)
precondition(assessment(.ready, [passed, repair]).batchAttentionItem == nil)
precondition(assessment(.review, [passed, unlocated]).batchAttentionItem == unlocated)
precondition(assessment(.review, [located, unlocated]).batchAttentionItem == located)
precondition(assessment(.review, [unlocated, located]).batchAttentionItem == unlocated)
precondition(assessment(.blocked, [unlocated, blocked]).batchAttentionItem == blocked)
precondition(assessment(.ready, [blocked]).batchAttentionItem == blocked)
precondition(assessment(.ready, [unlocated]).batchAttentionItem == unlocated)
precondition(assessment(.review, [passed]).batchAttentionItem?.status == .review)
precondition(assessment(.blocked, []).batchAttentionItem?.status == .blocked)
print("PASS: 9 production batch gate cases; unlocated and incomplete checks never pass silently")
`,
  encoding: 'utf8',
  timeout: 120_000,
});
process.stdout.write(result.stdout ?? '');
process.stderr.write(result.stderr ?? '');
if (result.error) throw result.error;
assert.equal(result.status, 0, 'Competitive workflow checks failed');
