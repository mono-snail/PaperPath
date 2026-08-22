# PaperPath V18: Office Visual Anchor Priority

## Product Direction

V17 made DOCX visual references bounded and auditable. V18 makes the budget
allocation smarter: visual-reference bytes are no longer treated as a flat pool.
PaperPath now prioritizes scanned pages, embedded-image pages, and table pages
differently so long documents do not spend the budget on the wrong anchors.

## Competitive Baseline

- PDF Expert keeps export simple but does not explain which pages get visual
  anchors under size pressure.
- Adobe Acrobat can convert complex layouts, but budget decisions are hidden
  behind conversion internals.
- PDFgear is broad, but users do not see whether scans, images, or tables are
  being protected first.
- PaperPath's advantage is a local, visible conversion policy: route score,
  visual budget pressure, compression ladder, anchor priority, and output
  receipt stay in one workflow.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Intended Gain |
|---|---|---|---|
| 1 | Visual budget was flat per page | Add anchor policy model | Smarter resource allocation |
| 2 | Scan pages need stronger anchors | Add scan-first policy | Better scanned DOCX output |
| 3 | Image-heavy PDFs need visible priority | Add image-first policy | Better appearance retention |
| 4 | Table pages are more valuable than decorative visuals | Add table-aware policy | Better business document output |
| 5 | Text-rich PDFs should stay editable | Add structure-first policy | Smaller, cleaner DOCX |
| 6 | UI lacked anchor vocabulary | Surface Anchor token | Faster user comprehension |
| 7 | Export receipt lost policy context | Add anchor policy to receipt | Closed post-export loop |
| 8 | DOCX service lacked page priority | Add critical/image/table priority | Better byte allocation |
| 9 | Single-page budgets could starve later pages | Reserve bytes for later candidates | More stable long exports |
| 10 | Scans deserve higher byte floor | Add critical floor | Preserved fallback visuals |
| 11 | Image pages need medium-high floor | Add image floor | Better image anchors |
| 12 | Table pages should be bounded | Add table floor | Controls package growth |
| 13 | Priority needed custom audit data | Count critical/image/table anchors | Portable DOCX evidence |
| 14 | Service/UI could drift | Share policy through model and receipt | Consistent explanation |
| 15 | Large docs need conservative policy | Structure-first reduces visual overuse | Lower output bloat |
| 16 | Low-text docs need visual fallback | Scan-first increases protection | Better practical output |
| 17 | Image pages should outrank tables | Priority classifier orders image before table | Better visual fidelity |
| 18 | Tables still need anchors | Table-aware remains explicit | Better spreadsheet-like pages |
| 19 | UI should stay dense | Add one token, no new screen | Less workflow friction |
| 20 | Metadata should remain local | Store only generated audit properties | Privacy continuity |
| 21 | Cancellation must stay responsive | Keep existing Task checks | Stable long exports |
| 22 | Existing output should remain compatible | Keep OOXML structure unchanged | Lower compatibility risk |
| 23 | Scope should stay narrow | Limit changes to model, DOCX service, export sheet | Safer iteration |
| 24 | Iteration needs closure | Document V18 and compile Debug | Auditable handoff |

## Delivered

- Added `PDFOfficeVisualAnchorPolicy`.
- Added anchor policy to `PDFOfficeVisualBudgetPlan`.
- Added anchor policy to Office export receipts.
- Added DOCX visual-reference priorities: critical, image, and table.
- Added priority-aware byte multipliers, byte floors, and reserve budgets.
- Added DOCX metrics for critical, image, and table visual anchors.
- Added OOXML custom properties for visual anchor counts.
- Added Anchor token to the Office budget strip.
- Added Anchor evidence to the post-export receipt.

## Competitive Gain

- Compared with PDF Expert, PaperPath now exposes which pages receive visual
  protection first.
- Compared with Acrobat, PaperPath makes conversion policy visible in the core
  export workflow.
- Compared with PDFgear, PaperPath ties visual priority to local DOCX audit
  metadata and a user-visible receipt.

## Remaining Shortfalls

- Anchor policy is still document-profile based before export; page-level Office
  preflight should count real table/image/fallback pages ahead of time.
- The priority classifier is conservative and does not yet inspect chart-like
  vector graphics.
- PPTX rendering still needs the same anchor/pressure vocabulary.
- Receipts are still session-local and should be persisted.

## Next Precise Direction

1. Add page-level Office preflight with real anchor counts.
2. Persist Office receipts in verified output history.
3. Apply anchor-priority policy to PPTX slide rendering.
4. Add receipt inspection that reads custom DOCX properties back into PaperPath.

## Build

`xcodebuild -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build`

Result: succeeded.
