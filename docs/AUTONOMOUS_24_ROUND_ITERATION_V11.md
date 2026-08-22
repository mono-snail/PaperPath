# PaperPath V11: 24-Round Page Preparation and Office Delivery Iteration

## Product Direction

V11 closes the gap between precise single-page editing and trustworthy
multi-page delivery:

1. Inspect visible page geometry locally.
2. Explain which pages can safely lose empty margins.
3. Let users keep explicit page exceptions.
4. Apply selected geometry in one recoverable mutation.
5. Explain what each Office format preserves before export.
6. Bound local rendering and package memory without hiding consequences.

The experience should behave like a prepress desk inside the private working
copy, not a collection of unrelated crop and conversion buttons.

## Competitive Baseline

- PDF Expert makes page manipulation direct, but batch margin cleanup and
  export-format consequences are less explicit.
- Adobe Acrobat exposes sophisticated crop and preflight tools, but spreads
  them across specialist modes and subscription-oriented panels.
- PDFgear offers convenient conversion and page utilities, but provides less
  evidence about crop confidence, page exceptions, editable structure, and
  local package budgets.
- PaperPath should combine local inspection, reversible batch preparation,
  visible format contracts, original preservation, and cancellable work.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Intended Gain |
|---|---|---|---|
| 1 | Page rows expose order but not physical geometry | Add visible point size, orientation, and paper class | Faster page audit |
| 2 | Mixed page sizes are discovered after export | Group geometry variants before mutation | Fewer output surprises |
| 3 | Single-page crop requires repeated manual setup | Add local automatic margin detection | Faster cleanup |
| 4 | Automatic crop can feel opaque | Show detected retention and confidence per page | Explainable automation |
| 5 | Edge detection can trim close content | Add adjustable safety padding | Conservative control |
| 6 | Blank or uncertain pages invite unsafe changes | Keep low-evidence pages unchanged | Safer defaults |
| 7 | Batch tools assume every page is equivalent | Add explicit per-page include and keep exceptions | Better mixed documents |
| 8 | Large documents require scanning every row | Add Changes and All review modes | Higher review density |
| 9 | Selection is reset when changing review mode | Preserve page decisions independently of filters | Stable intent |
| 10 | Crop requests are written page by page | Validate and apply all geometry in one mutation | Less I/O |
| 11 | Sequential mutations create many undo points | Create one recovery snapshot for the batch | Predictable undo |
| 12 | Rotated-page visual edges do not match PDF box edges | Map display insets through page rotation | Correct geometry |
| 13 | Batch work has no clear cancellation state | Add Stop and cancellation propagation | Reliable recovery |
| 14 | A cancelled scan can publish old results | Add generation and revision guards | No stale evidence |
| 15 | Wide layouts waste room in long page lists | Use two-column preparation rows on iPad | Better parallel review |
| 16 | Page preparation is hidden behind individual crop icons | Add a direct Prepare Pages command | Better discoverability |
| 17 | Office rows expose formats but not tradeoffs | Add editability, appearance, and size contracts | Better target choice |
| 18 | Word and PowerPoint sound equally editable | Distinguish structured editing from visual fidelity | Honest expectations |
| 19 | Image-heavy Office output can grow without early bounds | Add per-document visual-reference budgets | Lower memory risk |
| 20 | DOCX visual references use one fixed resolution | Adapt image edge and quality to page volume | Better scaling |
| 21 | Office export completion can race sheet dismissal | Keep task ownership and Stop behavior explicit | Stable routing |
| 22 | Output context omits text coverage | Show local text readiness beside pages and source size | Better preflight |
| 23 | Dynamic numbers can shift row layout | Use monospaced geometry and budget metrics | Calmer scanning |
| 24 | Preparation and export use different visual grammar | Reuse compact evidence headers and bottom commands | Coherent workflow |

## Deliberate Non-Goals

- No online conversion, AI crop service, account, ad SDK, engagement loop, or
  cloud document upload.
- No automatic deskew claim without a separate measured-angle evidence model.
- No destructive rewrite of Files originals.
- No automated tests, screenshots, StoreKit gate, or physical-device gate in
  this cycle.

## Completion Contract

- Implement the 24 rounds as one page-preparation and Office-delivery system.
- Preserve every existing working-tree change.
- Keep English and Simplified Chinese UI coherent.
- Finish with one signed Debug simulator build only.

## Cycle Closure

### Delivered

- Added local page-geometry inspection with visible point dimensions,
  orientation, A4/Letter/Legal/Square/Custom classification, ink coverage, and
  crop confidence.
- Added conservative content-bound detection with adjustable safety padding;
  blank, weak, and low-confidence pages stay unchanged by default.
- Added a dedicated Page Preparation workspace directly inside Organize Pages.
- Added Changes/All review modes, suggested selection, Keep All, per-page
  inclusion, stable numeric evidence, and compact page previews.
- Added adaptive one-column and two-column layouts for iPhone, Dynamic Type,
  and iPad review.
- Added direct preparation for the current selection from the existing page
  action bar.
- Added display-edge to PDF-box rotation mapping so top/right/bottom/left
  remain correct on 90-, 180-, and 270-degree pages.
- Added one-pass batch crop validation and mutation instead of reopening and
  writing the working copy for every page.
- Preserved one recovery snapshot and one undo point for each batch update.
- Added source-revision guards, cancellation propagation, stale progress
  suppression, and explicit Stop behavior for inspection, mutation, and Office
  export.
- Expanded Office targets with visible editability, appearance, size, and best-
  use contracts before export.
- Added text-coverage and local-conversion evidence to the output header.
- Added adaptive DOCX visual-reference resolution, quality, per-page limits, a
  72 MB aggregate visual budget, source limits, and a 1,000-page ceiling.
- Added page-count-aware PPTX render resolution and reduced the retained image
  budget from 240 MB to 180 MB.
- Preserved existing OOXML package validation and complete local file
  protection.
- Added Simplified Chinese coverage for the complete page-preparation and
  Office-contract workflow.

### Competitive Gain

- Compared with PDF Expert, PaperPath now combines direct page handling with
  visible crop confidence, safety padding, page exceptions, and one-step undo.
- Compared with Acrobat, batch margin preparation stays in one local,
  comprehensible workspace instead of a specialist preflight panel.
- Compared with PDFgear, Office targets explain editable structure, visual
  fidelity, and size intent before work begins, while package growth is
  explicitly bounded.
- PaperPath uniquely connects margin evidence and Office conversion to private
  work copies, source-revision protection, cancellation isolation, and original
  preservation.

### Remaining Shortfalls

- Deskew is intentionally not claimed because measured angle evidence and a
  vector-safe transform model are not yet implemented.
- Page preparation classifies physical formats but does not yet pad or scale
  content onto a normalized A4/Letter media box.
- Automatic content bounds are conservative and need later evidence across
  dark scans, full-bleed artwork, engineering drawings, and very large files.
- Microsoft Office and Apple iWork real-application opening remain separate
  release validation work.

### Next Precise Direction

1. Add measured deskew with angle confidence and visible before/after geometry.
2. Add vector-preserving A4/Letter normalization with explicit fit, fill, and
   padding consequences.
3. Add print preparation for bleed, safe area, color intent, and duplex page
   consistency.
4. Extend batch preparation with saved local presets without introducing
   accounts, cloud synchronization, or opaque automation.
