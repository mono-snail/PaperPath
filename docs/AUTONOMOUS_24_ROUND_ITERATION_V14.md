# PaperPath V14: 24-Round Professional Print Preflight

## Product Direction

V14 turns the V12 print-ready workflow and V13 booklet workflow into a
prepress-grade local evidence desk. The goal is not to claim PDF/X compliance;
it is to expose the physical risks that normally stay hidden in print dialogs:
trim boxes, bleed allowance, safe-area collisions, multi-signature pagination,
and saddle-stitch creep.

## Competitive Baseline

- PDF Expert stays fast for casual printing, but does not surface production
  trim, bleed, safe-area, signature, or creep evidence before output.
- Adobe Acrobat has deeper professional print tooling, but the workflow is
  fragmented across technical panels and print dialogs.
- PDFgear covers common conversion utilities, but provides less persistent
  local output evidence and weaker source-revision isolation.
- PaperPath should make production consequences visible without uploading
  files, mutating the working copy, or hiding decisions behind printer UI.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Intended Gain |
|---|---|---|---|
| 1 | Print readiness stopped at paper scaling | Add print-production page evidence | Broader output trust |
| 2 | Trim assumptions were invisible | Inspect crop, media, and trim boxes locally | Clear physical boundaries |
| 3 | Missing trim boxes create false confidence | Flag crop-box fallback as caution | Honest uncertainty |
| 4 | Bleed is often absent in office PDFs | Detect bleed allowance around trim | Faster print-risk review |
| 5 | Edge text can be cut after trimming | Measure nearest text/field distance to trim | Safer layouts |
| 6 | Preflight status was mixed with scaling status | Add dedicated risk, bleed, and safe metrics | Faster triage |
| 7 | Page review lacked risk filters | Add Preflight, Bleed, and Safe Area filters | Shorter review path |
| 8 | Risk evidence needed page-level detail | Show trim, bleed, and safe values per page | Actionable inspection |
| 9 | Large panels lower density | Use inline evidence strips instead of new pages | Less navigation |
| 10 | Booklet output assumed one signature | Add multi-signature planning | Real booklet production |
| 11 | Signature padding differs from whole-book padding | Pad each signature to a multiple of four | Correct imposition |
| 12 | Signature count was not visible | Add signature metrics and row labels | Clear pagination |
| 13 | Signature size needed fast control | Add All, 4, 8, and 12-sheet segmented presets | Efficient setup |
| 14 | Saddle stitch can drift at trim | Add creep-compensation model | Better finishing |
| 15 | Creep must remain vector-first | Shift PDF drawing destinations, not raster pages | Preserved sharpness |
| 16 | Creep decisions were hard to audit | Show max creep and per-spread creep evidence | Visible compensation |
| 17 | Spread diagrams did not reflect creep | Offset slot labels by computed creep | Immediate visual cue |
| 18 | Existing defaults must remain stable | Default to single signature and zero creep | Backward-compatible path |
| 19 | Booklet controls were becoming vertical | Parallelize signature and creep controls | Higher iPad density |
| 20 | Export choices sounded generic | Reword print and booklet commands around evidence | Better task clarity |
| 21 | Async assessment could become stale | Keep revision-bound assessment and creation checks | No stale output |
| 22 | Stop behavior must still work | Keep cancellation through assessment and rendering | Stable long jobs |
| 23 | Build risk came from expanding models | Keep new data as Hashable/Sendable value types | SwiftUI-safe diffing |
| 24 | The upgrade needed a closed release note | Document the iteration and verify Debug build | Auditable progress |

## Delivered

- Added `PDFPrintProductionRisk` and `PDFPrintProductionEvidence`.
- Added page-level trim-box, bleed-box, and safe-area evidence to print
  preparation assessment.
- Added aggregate counts for production risk, bleed review, and safe-area
  review.
- Added Preflight, Bleed, and Safe Area review filters.
- Added compact preflight evidence strip and page-row production evidence.
- Added `signatureSheetLimit` and `creepCompensationPoints` to booklet options.
- Added per-signature imposition planning with per-signature four-page padding.
- Added signature number, signature sheet count, and per-slot creep offset to
  booklet spreads.
- Applied creep as vector drawing destination offsets during booklet creation.
- Added signature and creep controls, metrics, row labels, and diagram cues.
- Updated export-entry copy to make print/booklet evidence explicit.
- Preserved existing source documents, private working copies, and verified
  output semantics.

## Competitive Gain

- Compared with PDF Expert, PaperPath now exposes prepress risks before the
  output exists.
- Compared with Acrobat, the workflow keeps production checks in one dense
  local path instead of spreading them across specialized panels.
- Compared with PDFgear, PaperPath ties production evidence to private copies,
  cancellation, source revision, and persistent verified output.

## Remaining Shortfalls

- No PDF/X, CMYK conversion, overprint, transparency flattening, or ICC profile
  compliance claim.
- Bleed detection is geometry-based; it does not inspect whether artwork truly
  continues past trim.
- Creep compensation uses a user-selected point offset, not measured stock
  thickness and fold calibration.
- Physical printer duplex alignment still requires release validation.

## Next Precise Direction

1. Add color-space and transparency-risk evidence without claiming conversion.
2. Add paper-thickness presets that convert stock thickness into creep offsets.
3. Add crop-mark, registration-mark, and slug-area generation as optional
   vector overlays.
4. Add a production receipt section that records trim, bleed, safe-area,
   signature, and creep decisions in the verified output audit.

## Build

`xcodebuild -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build`

Result: succeeded.
