import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const source = readFileSync('PaperPath/Views/PDFKitViews.swift', 'utf8');
const first = source.indexOf('enum PDFPagePreviewWindow {');
const last = source.indexOf('\nstruct PDFPageFilmstrip:', first);
assert(first >= 0 && last > first, 'Missing production preview window');
const models = readFileSync('PaperPath/Models/DocumentModels.swift', 'utf8');
const cacheFirst = models.indexOf('enum PDFDeliveryPreflightStatus:');
const cacheLast = models.indexOf('\nenum PDFBatchDeliveryStage:', cacheFirst);
assert(cacheFirst >= 0 && cacheLast > cacheFirst, 'Missing production preflight models');
const result = spawnSync('xcrun', ['swift', '-'], {
  input: `
import Foundation
${source.slice(first, last)}
var cases = 0
for count in [-1, 0, 1, 2, 8, 9, 10, 100, 10_000, Int.max] {
    for selected in [Int.min, -1, 0, 1, 4, 8, 9, 99, 9_999, Int.max] {
        let range = PDFPagePreviewWindow.indices(pageCount: count, selectedPage: selected)
        precondition(range.count <= 9)
        precondition(range.lowerBound >= 0)
        precondition(range.upperBound <= max(0, count))
        if count > 0 {
            precondition(range.contains(min(max(0, selected), count - 1)))
        } else {
            precondition(range.isEmpty)
        }
        cases += 1
    }
}
print("PASS: \\(cases) production preview-window boundary cases; at most nine pages")
${models.slice(cacheFirst, cacheLast)}
let cache = PDFDeliveryPreflightCacheEntry(
    recordID: UUID(), revisionID: UUID(), checkedAt: Date(),
    assessment: PDFDeliveryPreflightAssessment(
        status: .ready, pageCount: 1, byteCount: 20, fixCount: 0, reviewCount: 0, items: []
    )
)
let encoded = try JSONEncoder().encode(cache)
let decoded = try JSONDecoder().decode(PDFDeliveryPreflightCacheEntry.self, from: encoded)
precondition(decoded.usesCurrentRules)
var old = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
old.removeValue(forKey: "rulesVersion")
let legacyData = try JSONSerialization.data(withJSONObject: old)
let legacy = try JSONDecoder().decode(PDFDeliveryPreflightCacheEntry.self, from: legacyData)
precondition(!legacy.usesCurrentRules)
old["rulesVersion"] = 1
let staleData = try JSONSerialization.data(withJSONObject: old)
let stale = try JSONDecoder().decode(PDFDeliveryPreflightCacheEntry.self, from: staleData)
precondition(!stale.usesCurrentRules)
print("PASS: current preflight cache accepted; legacy and stale rule versions rejected")
`,
  encoding: 'utf8',
  timeout: 120_000,
});
process.stdout.write(result.stdout ?? '');
process.stderr.write(result.stderr ?? '');
if (result.error) throw result.error;
assert.equal(result.status, 0, 'Preview window checks failed');

const asset = JSON.parse(readFileSync(
  'PaperPath/Resources/Assets.xcassets/DocumentStage.colorset/Contents.json', 'utf8'
));
const backgrounds = asset.colors.map(entry => {
  const c = entry.color.components;
  return ['red', 'green', 'blue'].map(key => Number(c[key]));
});
const design = readFileSync('PaperPath/Core/DesignSystem.swift', 'utf8');
function colorPair(name) {
  const match = design.match(new RegExp(`static let ${name} = Color\\("([^"]+)"\\)`));
  assert(match, `Missing semantic color asset: ${name}`);
  const catalog = JSON.parse(readFileSync(
    `PaperPath/Resources/Assets.xcassets/${match[1]}.colorset/Contents.json`, 'utf8'
  ));
  return ['light', 'dark'].map(theme => {
    const matches = catalog.colors.filter(entry =>
      (entry.appearances?.some(a => a.appearance === 'luminosity' && a.value === 'dark') ? 'dark' : 'light') === theme
    );
    assert.equal(matches.length, 1, `${name}/${theme} requires exactly one asset variant`);
    const c = matches[0].color.components;
    assert.equal(Number(c.alpha), 1, `${name}/${theme} must be opaque`);
    return ['red', 'green', 'blue'].map(key => {
      const value = c[key].startsWith('0x') ? Number(c[key]) / 255 : Number(c[key]);
      assert(Number.isFinite(value) && value >= 0 && value <= 1, `${name}/${theme}: invalid ${key}`);
      return value;
    });
  });
}
function luminance(rgb) {
  const linear = rgb.map(c => c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
  return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722;
}
for (const name of ['textPrimary', 'textSecondary', 'accent', 'mint']) {
  colorPair(name).forEach((foreground, index) => {
    const a = luminance(foreground);
    const b = luminance(backgrounds[index]);
    const ratio = (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
    assert(ratio >= 4.5, `${name}/${index}: ${ratio} below AA`);
    console.log(`PASS: ${name} on DocumentStage (${index ? 'dark' : 'light'}) ${ratio.toFixed(2)}:1`);
  });
}
