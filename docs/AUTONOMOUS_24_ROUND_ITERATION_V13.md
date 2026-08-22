# PaperPath V13: 24-Round Booklet Imposition and Duplex Evidence

## Product Direction

V13 extends print preparation into a dedicated local booklet workflow. It
should turn a normal PDF into a two-up, duplex-ready booklet while exposing
every imposed side, inserted blank, binding decision, and folding instruction
before a separate verified output is created.

## Competitive Baseline

- PDF Expert reaches printing quickly but does not provide a document-level
  booklet imposition desk with persistent evidence.
- Adobe Acrobat supports booklet printing, but the page-order consequences are
  mostly hidden inside a printer-oriented dialog.
- PDFgear covers broad PDF utilities, but offers less transparent local
  imposition evidence and no PaperPath-style persistent output receipt.
- PaperPath should make professional page order understandable without using
  specialist prepress language or uploading the document.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Intended Gain |
|---|---|---|---|
| 1 | Normal page order cannot be folded into a booklet | Add deterministic booklet imposition | Correct pagination |
| 2 | Booklets require groups of four pages | Add explicit blank-page padding | Honest page count |
| 3 | Inserted blanks are easy to miss | Count and label every blank slot | Fewer print surprises |
| 4 | Left and right binding need mirrored order | Add binding-edge control | Wider language support |
| 5 | Booklet sheets need known physical sizes | Add A4, Letter, and Legal targets | Regional output |
| 6 | Content can crowd sheet edges | Add numeric outer margin | Safer trimming |
| 7 | Folded content can crowd the spine | Add independent gutter control | Better readability |
| 8 | Folding position is otherwise implicit | Add optional vector fold marks | Easier finishing |
| 9 | Page order is hard to verify from numbers alone | Add visual front/back spread diagrams | Faster review |
| 10 | Source and blank slots look too similar | Give blanks explicit visual treatment | Lower error risk |
| 11 | Front and back sides are mixed in long lists | Add All, Front, and Back filters | Focused review |
| 12 | Users need physical sheet relationships | Group each side by sheet number | Better mental model |
| 13 | Duplex orientation is printer-dependent | Show short-edge flip instruction | Correct reverse side |
| 14 | Stack and folding order is unclear | Add concise print, stack, fold workflow | Lower learning cost |
| 15 | Settings consume wide-screen space inefficiently | Parallelize paper/binding and margin/gutter controls | Denser iPad UI |
| 16 | Repeated cards create an assembled look | Use compact ledger rows and hairline evidence | More native rhythm |
| 17 | Raster imposition harms text and linework | Draw source PDF vectors into each half-sheet | Sharper output |
| 18 | Interactive annotations can print differently | Bake annotation appearance into imposed slots | Stable appearance |
| 19 | Generic audit rejects intentional page-count changes | Add booklet-aware page-count evidence | Correct verification |
| 20 | Generic visual comparison assumes page alignment | Add booklet-specific imposition evidence | No false failure |
| 21 | Long output can be interrupted | Propagate cancellation through every sheet side | Reliable Stop |
| 22 | Source edits can invalidate imposed order | Bind assessment and creation to source revision | No stale output |
| 23 | Partial output should never enter the library | Use temporary output, reopen checks, and cleanup | Clean local state |
| 24 | Imposition should remain part of trusted delivery | Issue a persistent SHA-256 receipt | Differentiated trust |

## Deliberate Non-Goals

- No cloud conversion, account, ads, or remote print service.
- No multi-signature splitting or saddle-stitch creep compensation in this
  cycle.
- No printer-driver control; PaperPath provides an explicit short-edge flip
  instruction.
- No color-profile, PDF/X, trim, or bleed compliance claim.
- No automated tests, screenshots, UI automation, StoreKit gate, or physical
  printer validation.

## Completion Contract

- Implement all 24 rounds as one booklet-imposition system.
- Preserve every existing working-tree change.
- Keep English and Simplified Chinese UI coherent.
- Finish with one signed Debug simulator build only.

## Cycle Closure

### Delivered

- Added a direct Booklet PDF command beside existing PDF and print-ready
  outputs.
- Added deterministic saddle-fold imposition with front and back sides for
  every physical sheet.
- Added automatic blank insertion to the next multiple of four, with inserted
  blanks counted and visibly labeled before export.
- Added A4, Letter, and Legal sheet targets with region-aware defaults.
- Added left and right binding with mirrored imposed page order.
- Added independent outer-margin and gutter controls.
- Added optional vector fold marks at the top and bottom sheet center.
- Added explicit short-edge duplex, stack-order, and center-fold instructions.
- Added All, Front Side, and Back Side review modes.
- Added compact spread diagrams showing left/right page slots, fold position,
  blank slots, sheet number, side, page order, and per-slot scale.
- Added responsive one-column and two-column spread ledgers for iPhone, Dynamic
  Type, and iPad.
- Added vector-first two-up drawing with source crop-box transforms.
- Added PDF annotation appearance baking into each imposed slot.
- Added temporary destination handling, cancellation propagation, revision
  isolation, failed-output cleanup, and a 1 GB output bound.
- Added post-render verification of imposed side count, physical sheet size,
  output reopening, rendering, editable annotation removal, and SHA-256.
- Added a persistent `bookletPrepared` delivery operation.
- Updated receipt verification so the expected output is
  `ceil(source pages / 4) × 2` imposed sides.
- Added booklet-specific page-count and imposition checks so intentional page
  reordering no longer fails generic aligned-page comparison.
- Added complete Simplified Chinese coverage for booklet creation and receipt
  evidence.

### Competitive Gain

- Compared with PDF Expert, PaperPath exposes the complete imposed front/back
  order before printing.
- Compared with Acrobat, booklet creation is understandable without hiding
  pagination inside a printer dialog.
- Compared with PDFgear, inserted blanks, binding mirrors, source revision, and
  the final fingerprint remain explicit and persistent.
- PaperPath uniquely connects local booklet imposition to private work copies,
  original preservation, cancellation isolation, and verified delivery.

### Remaining Shortfalls

- Multi-signature booklet splitting is not implemented.
- Paper-thickness creep compensation is not implemented.
- Cut-and-stack, perfect binding, and n-up layouts beyond two-up are not
  implemented.
- Physical duplex alignment and printer-driver interpretation remain release
  validation work.

### Next Precise Direction

1. Add multi-signature splitting with explicit signature boundaries.
2. Add measured creep compensation using paper thickness and sheet count.
3. Add cut-and-stack and four-up layouts as separate evidence-led workflows.
4. Add local trim, bleed, and safe-area inspection without claiming PDF/X
   compliance.
