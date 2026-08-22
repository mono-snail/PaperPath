# PaperPath V12: 24-Round Print Preparation and Page Standardization

## Product Direction

V12 turns printing from a blind system action into an evidence-led local
workflow. A user should be able to normalize mixed page sizes, understand
scaling and clipping before export, and create a separate print-ready PDF
without altering the private working copy or Files original.

## Competitive Baseline

- PDF Expert reaches the system print sheet quickly, but exposes little
  document-wide evidence for mixed physical page sizes.
- Adobe Acrobat has mature print-production controls, but distributes them
  across dense specialist panels with a high learning cost.
- PDFgear covers common print and conversion actions, but provides less
  explicit per-page consequence reporting and persistent output evidence.
- PaperPath should combine direct setup, per-page transparency, local-only
  processing, source-revision safety, and a verified output receipt.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Intended Gain |
|---|---|---|---|
| 1 | System Print begins without document normalization | Add a dedicated Print Preparation workflow | Fewer failed prints |
| 2 | Mixed page sizes remain hidden | Inspect every visible page size | Better preflight |
| 3 | A4 and Letter require separate manual conversion | Add A4, Letter, Legal, and Original targets | Faster regional output |
| 4 | Target orientation is implicit | Add Auto, Portrait, and Landscape policies | Predictable sheets |
| 5 | Scaling consequences are opaque | Add Fit, Fill, and Actual Size strategies | Explicit intent |
| 6 | Printer-safe whitespace is guessed | Add a numeric printable margin control | Safer physical output |
| 7 | One document-level label hides page exceptions | Calculate scale and clipping per page | Honest evidence |
| 8 | Fill can silently remove content | Count and identify clipped pages before creation | Prevent surprises |
| 9 | Fit can make small content unreadable | Show scale percentages and padded pages | Better decisions |
| 10 | Original-size pages can exceed the target | Expose Actual Size overflow before export | No hidden crop |
| 11 | Repeated page cards lower information density | Use compact evidence rows with a page diagram | Faster scanning |
| 12 | iPad wastes horizontal space | Use parallel controls and two-column page evidence | Better wide layouts |
| 13 | Long page lists obscure risky pages | Add All, Clipped, and Scaled review modes | Focused review |
| 14 | Dynamic metrics shift layout | Use monospaced dimensions, scale, and counts | Calmer interface |
| 15 | Existing annotations may print inconsistently | Bake annotation appearances into the print copy | Stable appearance |
| 16 | Standardization can destroy the working copy | Always create a separate output document | Original protection |
| 17 | Raster conversion sacrifices quality | Draw source PDF vectors into target media boxes | Sharper output |
| 18 | Full-bleed and margin content need clipping rules | Clip only to the declared printable rectangle | Consistent geometry |
| 19 | A cancelled export can leave stale UI state | Propagate cancellation into page rendering | Reliable Stop |
| 20 | Source edits can invalidate a running plan | Bind plans and results to the source revision | No stale output |
| 21 | Partial PDFs can survive interruption | Render to a temporary destination and remove failures | Clean local storage |
| 22 | A generated file can be structurally wrong | Reopen and verify page count, dimensions, and annotations | Stronger output |
| 23 | Geometry changes currently fail generic audits | Add an explicit print-prepared audit operation | Correct receipts |
| 24 | Print setup and export use different visual grammar | Reuse workflow evidence and bottom commands | Coherent product |

## Deliberate Non-Goals

- No cloud print service, account, advertising, or remote conversion.
- No color-profile or PDF/X compliance claim.
- No automatic deskew claim without measured-angle evidence.
- No mutation of the private working copy or Files original.
- No tests, screenshots, UI automation, StoreKit gate, or physical printer
  validation in this rapid iteration.

## Completion Contract

- Implement all 24 rounds as one print-preparation system.
- Preserve all existing working-tree changes.
- Keep Simplified Chinese and English UI coherent.
- Finish with one signed Debug simulator build only.

## Cycle Closure

### Delivered

- Added a direct Print-Ready PDF command to the existing output workflow.
- Added Original, A4, Letter, and Legal output targets.
- Added Auto, Portrait, and Landscape target orientation policies.
- Added Fit, Fill Page, and Actual Size placement strategies.
- Added an adjustable 0-72 point printable margin.
- Added revision-bound local assessment of source dimensions, target
  dimensions, scale, visible fraction, clipping, padding, and annotation count.
- Added explicit All, Clipped, and Scaled review modes.
- Added compact physical-page diagrams that show the target sheet, printable
  rectangle, rendered content, and clipped overflow.
- Added adaptive parallel controls and two-column page evidence on iPad while
  retaining one-column Dynamic Type layouts.
- Added a fixed bottom command that states the output contract before creation.
- Added vector-first PDF drawing into declared target media boxes rather than
  page-image conversion.
- Added PDF annotation appearance baking so print results do not depend on
  interactive annotation support.
- Added temporary-destination creation, task cancellation, failed-output
  cleanup, source-revision isolation, and a 1 GB output bound.
- Added post-render reopening, page-count verification, per-page physical-size
  verification, and zero-editable-annotation verification.
- Added `printPrepared` to the persistent delivery receipt model.
- Updated delivery audit semantics so intentional page geometry changes pass as
  print standardization rather than failing as unexpected mutation.
- Added SHA-256, visible change, blank page, page rendering, annotation, and
  output-size evidence through the existing verified-output pipeline.
- Added Simplified Chinese coverage for the complete workflow.

### Competitive Gain

- Compared with PDF Expert, PaperPath exposes document-wide physical page
  consequences before the system print sheet.
- Compared with Acrobat, common page standardization is understandable in one
  focused workflow without specialist prepress terminology.
- Compared with PDFgear, risky pages are individually visible and the result
  receives a persistent receipt tied to the source revision.
- PaperPath uniquely keeps print preparation local, preserves both the Files
  original and private working copy, and creates a separate audited result.

### Remaining Shortfalls

- Color profiles, CMYK conversion, spot colors, overprint, transparency
  flattening, bleed, trim boxes, and PDF/X compliance are not claimed.
- Duplex spread consistency and booklet imposition are not implemented.
- Deskew still requires a measured-angle model and visual evidence.
- Physical printer margins and real printer driver behavior remain release
  validation work.

### Next Precise Direction

1. Add a local print inspector for trim, bleed, safe area, and color-space
   evidence without claiming PDF/X compliance.
2. Add duplex spread pairing and blank-page insertion with explicit pagination
   consequences.
3. Add booklet imposition as a separate reversible output workflow.
4. Add measured deskew only after angle confidence and vector-safe transforms
   are available.
