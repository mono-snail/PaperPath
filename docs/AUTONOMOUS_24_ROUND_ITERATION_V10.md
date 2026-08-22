# PaperPath V10: 24-Round Content Correction and Page Geometry Iteration

## Product Direction

V10 extends the precision editing grammar to selected text, permanent
redaction, and page geometry:

1. Capture a bounded source selection.
2. Show exactly which pages, lines, regions, or edges are affected.
3. Adjust content or geometry with live consequences.
4. Block ambiguous, duplicate, or unsafe requests.
5. Create a separate result while preserving the current source.

Text correction, privacy removal, and cropping must feel deliberate and
evidence-led, not like hidden context-menu utilities.

## Competitive Baseline

- PDF Expert offers fluid selection and page tools but exposes less explicit
  fit assessment and permanent-removal evidence.
- Acrobat has advanced redact and crop workflows but distributes them through
  specialized modes, property panels, and subscription-oriented tool surfaces.
- PDFgear provides common text and page utilities but gives less visibility
  into multi-box reflow, duplicate redaction areas, and exact crop geometry.
- PaperPath should combine precise geometry, local fit assessment, permanent
  result evidence, and original preservation.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Intended Gain |
|---|---|---|---|
| 1 | Text replacement opens without source scope | Add pages, regions, lines, and character metrics | Immediate scope clarity |
| 2 | Original text is compressed into one label | Add compact source/replacement evidence | Better review |
| 3 | Font and alignment consume stacked rows | Pair typography intent on wide screens | Higher density |
| 4 | Fit assessment can publish stale styles | Add generation checks for text, font, and alignment | Stable preview |
| 5 | Page previews reopen each PDF repeatedly | Reuse revision-aware editor preview metadata | Lower I/O |
| 6 | Cross-page navigation shows only ordinal position | Show source page and affected-region counts | Better orientation |
| 7 | Save cancellation leaves ambiguous state | Standardize Stop without stale routing | Predictable recovery |
| 8 | Redaction marks are appended with exact-value dedupe only | Sanitize, clamp, sort, and quantize marks | Cleaner privacy input |
| 9 | Repeated selection can create duplicate areas | Deduplicate near-identical geometry | Fewer redundant masks |
| 10 | Redaction review is one flat list | Group marked regions by page | Faster audit |
| 11 | Region rows do not expose geometry | Show area dimensions and page coverage | Better consequence awareness |
| 12 | Stop dismisses the redaction setup | Preserve marks when stopping processing | Better recovery |
| 13 | Redaction completion can route after cancellation | Add cancellation guard before result routing | Stable privacy workflow |
| 14 | Trim Margins is a hidden fixed 4% command | Introduce a dedicated crop editor | Real geometry control |
| 15 | Crop amount is uniform and opaque | Add independent top, right, bottom, and left insets | Precise page framing |
| 16 | Crop has no visual preview | Dim excluded areas over the real page | Clear consequence |
| 17 | Common crops require repeated slider work | Add None, Light, Standard, and Tight presets | Faster setup |
| 18 | Crop validity is discovered during mutation | Surface retained area and block invalid geometry | Fewer failures |
| 19 | Crop remains hidden in a context menu | Add a direct crop command on each page row | Better discoverability |
| 20 | Page geometry save cannot be stopped | Add cancellable Apply/Stop behavior | Predictable recovery |
| 21 | Crop API only supports one inset fraction | Add a four-edge normalized crop contract | Stronger capability |
| 22 | Editor preview cache lacks source point dimensions | Store page width and height with cached preview | Less duplicate parsing |
| 23 | Large selection metrics are recomputed repeatedly | Cache grouped pages and aggregate geometry | Better scaling |
| 24 | Reduced-motion behavior differs across correction tools | Respect reduced motion for page and result transitions | Consistent accessibility |

## Deliberate Non-Goals

- No OCR invention of replacement text, online AI, upload, account, advertising
  SDK, or engagement mechanics.
- No weakening of permanent-redaction semantics or source-preservation rules.
- No automated tests, screenshots, StoreKit gate, or physical-device gate in
  this cycle.

## Completion Contract

- Implement all 24 rounds as one content-and-geometry correction system.
- Preserve all existing working-tree changes.
- Keep English and Simplified Chinese UI coherent.
- Finish with one signed Debug simulator build.

## Cycle Closure

### Delivered

- Added a compact text-replacement context strip for selected characters,
  lines, flow regions, pages, and current fit state.
- Paired font intent and alignment on wide screens and kept source,
  replacement, fit detail, and live page overlays in one workflow.
- Made fit assessment generation-aware across replacement text, font style, and
  alignment so stale results cannot overwrite the current request.
- Reused the revision-aware editor preview cache for every selected page and
  extended cached previews with source page-point dimensions.
- Removed the remaining duplicate text-replacement preview and page-size PDF
  parsing.
- Added reduced-motion page transitions and consistent Stop state cleanup.
- Added `PDFRedactionMarkSanitizer` to clamp invalid geometry, discard empty
  marks, quantize near-identical selections, deduplicate, and sort by page.
- Applied redaction sanitation at selection capture and workspace accumulation.
- Rebuilt redaction review around cached page groups, per-area dimensions and
  coordinates, marked-area coverage, clear/continue actions, and persistent
  marks when processing is stopped.
- Guarded redaction result routing against cancellation.
- Replaced hidden fixed 4% margin trimming with a dedicated full-page Crop
  Editor directly available from every page row.
- Added independent top, right, bottom, and left crop controls, live excluded-
  area masks, retained width/height/area metrics, and None/Light/Standard/Tight
  presets.
- Added geometry validation before mutation and cancellable Apply/Stop state.
- Added a four-edge normalized crop contract through the model and mutation
  service while preserving the existing uniform-inset API.
- Replaced the blocking page-mutation overlay with a compact on-device progress
  strip.

### Competitive Gain

- Compared with PDF Expert, PaperPath now adds explicit multi-box fit evidence,
  duplicate-safe redaction input, and four-edge crop consequences to direct
  page manipulation.
- Compared with Acrobat, text correction, redaction review, and page geometry
  stay in one local private-copy workflow instead of separate specialist modes.
- Compared with PDFgear, affected regions, redaction geometry, retained crop
  area, cancellation state, and output consequences remain visible before
  committing.
- PaperPath now connects content correction and page geometry to its existing
  structural audit, original preservation, and verified-delivery moat.

### Remaining Shortfalls

- Batch crop, automatic margin detection, deskew, and page-size normalization
  remain separate or unavailable.
- Text replacement intentionally does not rewrite arbitrary PDF content streams
  when the selected structure cannot be safely represented.
- Redaction remains rasterized for reliable removal; searchable-redaction
  reconstruction would require a separate evidence model.
- Very large multi-page text selections and hundreds of redaction regions need
  later performance evidence before release claims.

### Next Precise Direction

1. Add batch page geometry with explicit per-page exceptions.
2. Introduce local margin detection and deskew without hiding crop evidence.
3. Unify page-size normalization and print preparation with the geometry model.
4. Keep text replacement and redaction conservative when structure cannot be
   proven safe.
