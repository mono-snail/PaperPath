import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const source = readFileSync('PaperPath/Models/DocumentModels.swift', 'utf8');
const start = source.indexOf('enum PDFPageNumberInput {');
const end = source.indexOf('\nenum PDFPageSelection {', start);
assert(start >= 0 && end > start, 'Production page-input type boundary changed');
const view = readFileSync('PaperPath/Views/ReadingAndBookmarksView.swift', 'utf8');
function sliceView(start, end) {
  const a = view.indexOf(start);
  const b = view.indexOf(end, a);
  assert(a >= 0 && b > a, 'Production navigation method boundary changed');
  return view.slice(a, b);
}
const resolvers = sliceView('    private func matchingPageLabelIndex(', '    private func pageLabel(for index:')
  + sliceView('    private func typedPageIndex(', '    private func openTypedPage(')
  + sliceView('    private nonisolated static func normalizedPageLabel(', '    private static func indexPageLabels(');
const workspace = readFileSync('PaperPath/Views/DocumentWorkspaceView.swift', 'utf8');
const jumpStart = workspace.indexOf('    private var pageJumpIsValid:');
const jumpEnd = workspace.indexOf('    private func availableTools(', jumpStart);
assert(jumpStart >= 0 && jumpEnd > jumpStart, 'Workspace jump boundaries changed');
assert(!workspace.includes('.onChange(of: pageJumpInput)'), 'Do not rewrite a pasted page expression before validation');
const workspaceJump = workspace.slice(jumpStart, jumpEnd).replaceAll('private ', '');
const result = spawnSync('xcrun', ['swift', '-'], {
  input: `
import Foundation
${source.slice(start, end)}
struct DocumentRecord {
    struct Profile { let pageCount: Int }
    let profile: Profile
}
struct Navigation {
    let searchText: String
    let pageInput: String
    let pageIndexByNormalizedLabel: [String: Int]
${resolvers.replaceAll('private func', 'func')}
}
struct WorkspaceNavigation {
    struct Model {
        let pageCount: Int
        func record(id: Int) -> DocumentRecord? {
            DocumentRecord(profile: .init(pageCount: pageCount))
        }
    }
    let model: Model
    let recordID = 0
    var pageJumpInput: String
    var isJumpingToPage = true
    var openedPage: Int?
    mutating func showPage(_ page: Int, message: String, showsNotice: Bool) { openedPage = page }
${workspaceJump.replace('func jumpToEnteredPage()', 'mutating func jumpToEnteredPage()')}
}
for value in ["12", "１２", "١٢", "۱۲", " 12\\n"] {
    precondition(PDFPageNumberInput.pageIndex(value, pageCount: 20) == 11)
}
for value in ["", "0", "21", "1-3", "1,3", "1 3", "-3", "+3", "½", "²", "Ⅻ", "1️⃣", "1000000"] {
    precondition(PDFPageNumberInput.pageIndex(value, pageCount: 20) == nil, value)
}
precondition(PDFPageNumberInput.pageIndex("100000", pageCount: 100000) == 99999)
precondition(PDFPageNumberInput.pageIndex("000012", pageCount: 20) == 11)
precondition(PDFPageNumberInput.pageIndex("1", pageCount: 0) == nil)
precondition(PDFPageNumberInput.pageIndex("1", pageCount: -1) == nil)
let record = DocumentRecord(profile: .init(pageCount: 20))
let cases: [(String, Int?)] = [("١٢", 11), ("１２", 11), ("IV", 3), ("1-3", 7), ("21", nil), ("-3", nil)]
for (query, expected) in cases {
    let navigation = Navigation(searchText: query, pageInput: query,
        pageIndexByNormalizedLabel: ["iv": 3, "1-3": 7])
    precondition(navigation.typedPageIndex(record) == expected, query)
    precondition(navigation.matchingPageLabelIndex(record) == expected, query)
}
print("PASS: 34 production navigation checks; localized digits, typed navigation, label-search resolution, custom-label fallback and bounds")
for (input, expected) in [("12", 11), ("１２", 11), ("١٢", 11), (" 2 ", 1)] {
    var navigation = WorkspaceNavigation(model: .init(pageCount: 20), pageJumpInput: input)
    precondition(navigation.pageJumpIsValid)
    navigation.jumpToEnteredPage()
    precondition(navigation.openedPage == expected)
    precondition(navigation.pageJumpInput.isEmpty && !navigation.isJumpingToPage)
}
for input in ["1-3", "1,3", "-3", "+3", "21", "0", "1234567"] {
    var navigation = WorkspaceNavigation(model: .init(pageCount: 20), pageJumpInput: input)
    precondition(!navigation.pageJumpIsValid)
    navigation.jumpToEnteredPage()
    precondition(navigation.openedPage == nil)
    precondition(navigation.pageJumpInput == input && navigation.isJumpingToPage)
}
print("PASS: 33 production workspace-jump checks; localized input, exact zero-based destination, invalid draft preservation and no accidental navigation")
`,
  encoding: 'utf8',
  timeout: 120_000,
});
process.stdout.write(result.stdout ?? '');
process.stderr.write(result.stderr ?? '');
if (result.error) throw result.error;
assert.equal(result.status, 0);
