# PaperPath V15: Office Reconstruction Evidence Desk

## Product Direction

V15 upgrades PDF-to-Office from a passive format list into a local reconstruction
evidence desk. PaperPath now tells users which Office route is strongest before
export, records DOCX reconstruction metrics inside the generated package, and
keeps visual references within a bounded on-device budget.

## Competitive Baseline

- PDF Expert provides convenient export paths, but users get little evidence
  about whether Word, Excel, or PowerPoint is the right target for a specific
  PDF.
- Adobe Acrobat has stronger conversion infrastructure, but the workflow is
  heavy and often hides quality tradeoffs behind conversion dialogs.
- PDFgear is broad and approachable, but it does not make local reconstruction
  quality, visual-reference budgets, and package-level audit metadata a clear
  product surface.
- PaperPath's advantage is explicit local evidence: private copy in, bounded
  Office package out, with no cloud dependency or silent source mutation.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Intended Gain |
|---|---|---|---|
| 1 | Office export looked like a generic list | Add Office portfolio scoring | Faster target choice |
| 2 | Users could not compare DOCX/XLSX/PPTX | Add per-format readiness plans | Clear tradeoffs |
| 3 | Text coverage was underused | Convert profile data into route evidence | Better conversion fit |
| 4 | Image-heavy PDFs need visual routes | Recommend PPTX or visual DOCX references | Fewer bad exports |
| 5 | Excel conversion is risky for prose | Score editability separately from appearance | Honest table workflow |
| 6 | PPTX is high fidelity but larger | Score appearance and size independently | Better file-size control |
| 7 | Protected PDFs need explicit limits | Mark locked/copy-restricted sources limited | Less failed exporting |
| 8 | The Office section lacked density | Add BEST/TEXT/IMAGE/FORMS metric strip | Better scanning |
| 9 | Scores needed compact visualization | Add E/A/S bars for edit, appearance, size | Parallel comparison |
| 10 | Format buttons repeated generic copy | Replace with plan-specific preferred use | More precise action |
| 11 | Risk details were hidden | Add inline route-risk summaries | Fewer surprises |
| 12 | DOCX had no reconstruction receipt | Add DOCX reconstruction metrics | Auditable output |
| 13 | DOCX metadata only named the app | Add OOXML custom properties | Evidence travels with file |
| 14 | Paragraph/table counts were not tracked | Count reconstructed blocks and characters | Quality diagnostics |
| 15 | Fallback OCR/text-index usage was invisible | Count fallback text pages | Better trust boundary |
| 16 | Visual references could bloat large files | Add visual budget modes | Stable large exports |
| 17 | Pure text pages wasted image budget | Lower budget for structured text pages | Smaller DOCX output |
| 18 | Table/image pages need visual anchors | Prioritize references for tables/images | Higher reconstruction fidelity |
| 19 | Scanned pages need page images | Prioritize references when structure is empty | Usable fallback |
| 20 | Skipped references lacked trace | Count skipped visual references | Transparent budget exhaustion |
| 21 | OOXML validity must remain strict | Declare custom property content type and rel | Openable Word packages |
| 22 | Conversion should remain private | Keep all metrics generated locally | Privacy consistency |
| 23 | UX should avoid full-screen detours | Keep evidence inside export sheet rows | Shorter flow |
| 24 | The release needs closure | Document V15 and compile Debug | Auditable iteration |

## Delivered

- Added `PDFOfficeExportReadiness`, `PDFOfficeExportFormatPlan`, and
  `PDFOfficeExportPortfolio`.
- Added Word/Excel/PowerPoint route scoring for editability, appearance, and
  size.
- Added dense Office export metrics: recommended route, text coverage, image
  pages, and form fields.
- Added compact E/A/S score rows for Office targets.
- Added plan-specific preferred-use and risk copy per Office export button.
- Added DOCX reconstruction metrics for pages, paragraphs, tables, characters,
  fallback text pages, visual references, skipped visual references, and visual
  byte count.
- Added adaptive DOCX visual-reference byte budgets.
- Added `docProps/custom.xml` with PaperPath reconstruction evidence.
- Added root OOXML custom-properties relationship and content type declaration.
- Kept the DOCX body content free of visible audit clutter.

## Competitive Gain

- Compared with PDF Expert, PaperPath now makes target-format choice explicit
  before export.
- Compared with Acrobat, PaperPath keeps the decision surface compact and local
  instead of burying it in conversion settings.
- Compared with PDFgear, PaperPath exposes reconstruction evidence in both UI
  and the generated DOCX package.

## Remaining Shortfalls

- DOCX reconstruction is still heuristic; it does not preserve every complex
  PDF layout object as editable Word shapes.
- Excel table inference still depends on line spacing and column gaps.
- PPTX remains the best fidelity route for image-heavy pages, but large deck
  output still needs deeper chunking and compression controls.
- DOCX custom properties are machine-readable evidence; a future receipt view
  should surface them in PaperPath after export.

## Next Precise Direction

1. Add a dedicated Office preflight sheet with page-level table/paragraph/image
   evidence before export.
2. Add chunked Office export for very large PDFs with resumable temporary
   package assembly.
3. Add DOCX visual-reference placement controls: inline, page-end, or metadata
   only.
4. Add generated Office receipt preview inside PaperPath so users can inspect
   reconstruction metrics without opening Word.

## Build

`xcodebuild -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build`

Result: succeeded.
