# PaperPath V17: DOCX Visual Budget Backpressure

## Product Direction

V16 made Office export budgets visible. V17 makes those budgets enforceable and
auditable. DOCX visual references now run through a four-pass compression ladder,
track why a page visual was skipped, and expose budget pressure before export.

## Competitive Baseline

- PDF Expert keeps conversion simple, but it does not explain per-page visual
  budget pressure or compression fallback behavior.
- Adobe Acrobat has deep conversion infrastructure, but budget decisions remain
  mostly hidden from the normal export flow.
- PDFgear is broad, but large visual conversions can feel opaque when output
  size changes sharply.
- PaperPath's advantage is local, bounded, visible Office reconstruction: the
  user sees route quality, visual budget pressure, fallback strategy, and the
  generated-file receipt in one workflow.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Intended Gain |
|---|---|---|---|
| 1 | `maximumBytesPerPage` was hidden execution detail | Expose per-page budget in UI | Concrete file-size control |
| 2 | Budget pressure was not modeled | Add relaxed/managed/tight pressure | Faster risk reading |
| 3 | UI lacked compression strategy | Add compression ladder summary | Clear fallback behavior |
| 4 | DOCX visual references had coarse success/fail | Add accepted/skipped outcome | Better diagnostics |
| 5 | Skip reasons were collapsed | Track total budget, page budget, render failures | Actionable audit |
| 6 | Three-pass compression was too shallow | Add fourth 46% fallback pass | More successful bounded visuals |
| 7 | Compression fallback was invisible | Count fallback successes | Honest fidelity evidence |
| 8 | Accepted visual quality was unknown | Track minimum accepted quality | Output inspectability |
| 9 | Accepted visual scale was unknown | Track smallest accepted edge | Actual fidelity signal |
| 10 | Largest embedded visual was unknown | Track max accepted bytes | Better package analysis |
| 11 | DOCX metadata missed skip reasons | Add custom properties for skip categories | Portable audit trail |
| 12 | Service and UI could drift | Align model ladder with service ladder | Consistent behavior |
| 13 | Budget pressure needed visual encoding | Add pressure symbol/color in export sheet | Faster scanning |
| 14 | Single package guidance was incomplete | Keep chunk summary alongside pressure | Large doc expectation |
| 15 | Receipt missed budget pressure | Carry pressure into output receipt | Closed loop |
| 16 | Visual-heavy docs needed clearer risk | Estimate pressure from visual pages × per-page budget | Pre-export warning |
| 17 | Pure text docs should not look risky | Relaxed state for low estimated visual bytes | Less false alarm |
| 18 | Table/image pages should be prioritized | Preserve existing table/image visual-reference policy | Better appearance anchors |
| 19 | OCR fallback pages needed evidence | Keep fallback text page counts | Trust boundary |
| 20 | Compression failures should not crash export | Skip visual, keep structured blocks | Stable output |
| 21 | Cancel behavior must remain responsive | Keep cancellation check inside ladder | Fast stop |
| 22 | UI must remain dense | Use compact tokens, not explanatory cards | Less generic layout |
| 23 | Privacy must remain local | Store only local reconstruction metadata | No cloud dependency |
| 24 | Iteration needs closure | Document V17 and compile Debug | Auditable handoff |

## Delivered

- Added `PDFOfficeVisualBudgetPressure`.
- Added budget pressure and compression ladder summaries to
  `PDFOfficeVisualBudgetPlan`.
- Added pressure to `PDFOfficeExportReceipt`.
- Reworked DOCX visual-reference creation into accepted/skipped outcomes.
- Added four-pass visual compression fallback.
- Added metrics for budget skips, page-budget overflow, render failures,
  compression fallbacks, minimum accepted quality, smallest accepted edge, and
  largest accepted visual bytes.
- Added OOXML custom properties for the new DOCX visual-budget evidence.
- Updated Office export UI with per-page budget, compression ladder, pressure,
  visual estimate, and package summary.
- Updated the export receipt to retain pressure evidence after sharing.

## Competitive Gain

- Compared with PDF Expert, PaperPath now shows how visual references will be
  bounded before export.
- Compared with Acrobat, PaperPath keeps budget strategy in a compact local
  workflow instead of a separate advanced conversion path.
- Compared with PDFgear, PaperPath records why visual references were accepted
  or skipped inside the generated DOCX audit metadata.

## Remaining Shortfalls

- Budget pressure is still estimate-based before export; a page-level Office
  preflight should count actual tables, images, and fallback pages.
- Chunking is advisory; actual multi-package resumable export is still pending.
- The app does not yet read `docProps/custom.xml` back into a persistent receipt.
- PPTX export uses a separate render budget and should receive the same pressure
  model.

## Next Precise Direction

1. Add page-level Office preflight with table, image, OCR fallback, and visual
   anchor counts.
2. Persist Office receipts and make them searchable in output history.
3. Apply pressure modeling to PPTX slide rendering.
4. Add resumable multi-package export for large DOCX/PPTX jobs.

## Build

`xcodebuild -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build`

Result: succeeded.
