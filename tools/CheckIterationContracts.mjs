import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

function extract(path, start, end) {
  const source = readFileSync(path, 'utf8');
  const first = source.indexOf(start);
  const last = source.indexOf(end, first);
  if (first < 0 || last < 0) throw new Error(`Missing source boundary: ${path}`);
  return source.slice(first, last);
}

const registry = extract(
  'PaperPath/Core/DesignSystem.swift',
  'private final class PaperPathShareLeaseRegistry:',
  '\nenum PaperPathTemporaryArtifact'
);
const sourceIdentity = extract(
  'PaperPath/Views/PDFKitViews.swift',
  'private struct PDFPreviewSource:',
  '\nactor PDFEditorPreviewLoader'
);
const numeric = extract(
  'PaperPath/Services/DOCXExportService.swift',
  '    private func numericValue(for value: String)',
  '\n    private func makePackage'
).replace('private func', 'func');

const program = `import Foundation
${registry}
${sourceIdentity}
${numeric}
private let registry = PaperPathShareLeaseRegistry.shared
let item = URL(fileURLWithPath: "/tmp/PaperPath-contract-item")
let preserved = registry.begin(items: [item], removesItemsOnCompletion: false)!
precondition(registry.end(leaseID: preserved, forcesCleanup: false).isEmpty)
let protected = registry.begin(items: [item], removesItemsOnCompletion: false)!
precondition(registry.end(leaseID: protected, forcesCleanup: true).isEmpty)
let owned = registry.begin(items: [item], removesItemsOnCompletion: false)!
precondition(registry.deferRemovalIfLeased(item: item))
precondition(registry.end(leaseID: owned, forcesCleanup: false) == [item])
let first = registry.begin(items: [item], removesItemsOnCompletion: true)!
let second = registry.begin(items: [item], removesItemsOnCompletion: true)!
precondition(registry.end(leaseID: first, forcesCleanup: false).isEmpty)
precondition(registry.end(leaseID: second, forcesCleanup: false) == [item])
precondition(registry.end(leaseID: second, forcesCleanup: false).isEmpty)
print("PASS: share cancel, protected-data release, owner cleanup, concurrent leases, idempotent end")
for value in ["00123456", "0008", "+441234567890", "1234567890123456", "=1+1", "１２３４", "٠١٢٣"] {
    precondition(numericValue(for: value) == nil, value)
}
for (input, expected) in [("240.00", "240.00"), ("-12.50", "-12.50"), ("0.50", "0.50"), ("1,234.56", "1234.56")] {
    precondition(numericValue(for: input) == expected, input)
}
print("PASS: 11 spreadsheet numeric/text classification cases")
let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: file) }
precondition(PDFPreviewSource(url: file, revision: 1) == nil)
try Data([1, 2, 3]).write(to: file)
private let before = PDFPreviewSource(url: file, revision: 1)!
precondition(before == PDFPreviewSource(url: file, revision: 1))
precondition(before != PDFPreviewSource(url: file, revision: 2))
try Data([4, 5, 6]).write(to: file, options: .atomic)
precondition(before != PDFPreviewSource(url: file, revision: 1))
try Data().write(to: file)
precondition(PDFPreviewSource(url: file, revision: 1) == nil)
print("PASS: missing, stable, revision-changed, atomic replacement and empty preview source")
`;

const result = spawnSync('xcrun', ['swift', '-'], {
  input: program,
  encoding: 'utf8',
  timeout: 120000,
});
process.stdout.write(result.stdout ?? '');
process.stderr.write(result.stderr ?? '');
if (result.error) throw result.error;
process.exit(result.status ?? 1);
