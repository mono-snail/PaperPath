# PaperPath V9: 24-Round Precision Editing Iteration

## Product Direction

V9 unifies every operation that places or styles an object on a PDF page.
Signatures, ink, text markup, notes, stamps, form fields, links, and images
should share one direct editing grammar:

1. Select the object or editing intent.
2. See the exact page and affected region.
3. Position with drag or deterministic anchors.
4. Adjust size and style with compact controls.
5. Understand collisions, shared resources, and output consequences.
6. Save, stop, or continue to verified delivery.

The experience must feel like one precision editor, not a collection of modal
utilities with unrelated controls.

## Competitive Baseline

- PDF Expert has polished Pencil and signature interactions but provides less
  explicit structural consequence and verified-output continuity.
- Acrobat has broad signing, forms, and object tooling but distributes it
  across multiple modes, account prompts, and dense property surfaces.
- PDFgear exposes common annotation and signing tools but gives weaker object
  collision, shared-resource, and result evidence.
- PaperPath should combine direct manipulation, deterministic placement,
  private working copies, and explainable output consequences.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Intended Gain |
|---|---|---|---|
| 1 | Placement controls differ by editor | Introduce one five-anchor precision rail | Cross-tool muscle memory |
| 2 | Drag-only placement is imprecise | Keep direct drag plus deterministic anchors | Better novice and expert control |
| 3 | Object bounds can escape after resize | Clamp move, resize, and anchor placement | Stable page output |
| 4 | Size feedback is hidden in sliders | Show live width and height percentages | Predictable placement |
| 5 | Signature capture and placement feel like one long modal | Make capture and placement explicit stages | Clearer signing path |
| 6 | Saved signature state is secondary text | Surface local signature availability and retention state | Better privacy confidence |
| 7 | Signature placement lacks quick anchors | Apply the shared precision rail | Faster field alignment |
| 8 | Signature resize can drift outside the page | Recenter and clamp every resize | Safer signatures |
| 9 | Drawing starts without page/tool context | Add page, tool, stroke, and input metrics | Immediate orientation |
| 10 | Pencil tools use two stacked generic rows | Build one compact tool and style command deck | Higher information density |
| 11 | Shape insertion silently switches to lasso | Keep explicit shape and previous-tool state | Clearer behavior |
| 12 | Drawing save has no persistent operation state | Use Save/Stop semantics and stale-result isolation | Better stability |
| 13 | Markup colors hide inside nested menus | Expose current markup intents and semantic swatches | Faster repeated markup |
| 14 | Note and stamp flows use unrelated presentations | Align them with page/object evidence | Consistent annotations |
| 15 | Stamp picker is a long decorative list | Use an adaptive compact stamp matrix | Better iPad use |
| 16 | Form field creation relies on drag and sliders | Apply precision anchors and object metrics | Faster authoring |
| 17 | Existing-field overlap is only visual | Surface overlap state and block unsafe placement | Fewer broken forms |
| 18 | Field options and geometry compete vertically | Pair field semantics and geometry on wide screens | Better density |
| 19 | Field save can publish after dismissal | Add cancellable save generation | Stable form authoring |
| 20 | Content editor duplicates placement logic | Replace local controls with shared precision rail | Less inconsistency |
| 21 | Link editing lacks deterministic alignment | Add shared anchors and dimensions | Better link hit regions |
| 22 | Image replacement selection can publish stale scans | Add generation-aware inspection and photo loading | Better stability |
| 23 | Shared image consequences are visually secondary | Keep occurrence and scope beside the selected object | Safer replacement |
| 24 | Editing tasks use inconsistent Stop behavior | Standardize cancel without stale UI publication | Predictable recovery |

## Deliberate Non-Goals

- No online signing, certificate authority, cloud signature account, upload,
  online AI, advertising SDK, points, or engagement mechanics.
- No weakening of signature evidence, form compatibility, image-resource
  constraints, or PDF structural auditing.
- No automated tests, screenshots, StoreKit gate, or physical-device gate in
  this cycle.

## Completion Contract

- Implement all 24 rounds as one precision editing system.
- Preserve all existing working-tree changes.
- Keep English and Simplified Chinese UI coherent.
- Finish with one signed Debug simulator build.

## Cycle Closure

### Delivered

- Added one shared `PrecisionPlacementRail` with five deterministic anchors,
  live width/height percentages, consistent icon controls, and page-bound
  clamping.
- Applied the shared placement grammar to signatures, text/photo/link overlays,
  form fields, and existing link hit regions.
- Split signing into explicit Capture and Place stages, surfaced page, stage,
  saved-local state, and made every signature move/resize remain within page
  bounds.
- Added cancellable signature/drawing save operations and prevented cancelled
  results from changing the active UI.
- Replaced duplicated signature/drawing page rendering with the revision-aware
  shared editor preview cache.
- Added a compact drawing context strip for page, active tool, stroke count,
  and Touch/Pencil policy.
- Combined tool style and input controls adaptively on wide screens, retained
  undo/redo, and made shape insertion explicitly announce Lasso selection.
- Rebuilt note creation as a dedicated high-density composer with page,
  placement, and character evidence.
- Rebuilt stamp selection as an adaptive compact matrix with page and editable-
  result evidence instead of a decorative vertical list.
- Rebuilt annotation property editing around content, semantic color, line
  width, editability evidence, persistent Save/Stop, and cancellation-aware
  result handling.
- Added form-field page/type/size metrics, shared anchors, overlap highlighting,
  explicit overlap naming, unsafe-placement blocking, and cancellable save.
- Added generation-aware image inspection, replacement-photo loading, link
  preview switching, and operation cancellation.
- Kept shared-image occurrence scope beside the selected object and preserved
  the explicit all-reference confirmation.
- Removed four duplicated page-preview implementations and the obsolete local
  content-placement implementation.

### Competitive Gain

- Compared with PDF Expert, PaperPath now pairs Pencil and signature fluency
  with deterministic anchors, form collision evidence, and verified-delivery
  continuity.
- Compared with Acrobat, signing, form authoring, content placement, and object
  editing share one compact grammar instead of switching between tool modes and
  property panels.
- Compared with PDFgear, shared-image scope, field overlap, local signature
  retention, and cancellation consequences are visible before committing.
- PaperPath now combines precision editing with its existing moat: private
  working copies, original preservation, structure-aware output, and verified
  delivery.

### Remaining Shortfalls

- Text replacement, redaction mark placement, crop geometry, and page-box
  editing still use separate selection grammars.
- Signature certificates and cryptographic signing remain deliberately outside
  the handwritten-signature workflow.
- Pencil hover, squeeze, latency, palm rejection, and saved-signature ergonomics
  require physical-device evidence.
- Large drawings and highly populated form pages need later performance
  evidence before release claims.

### Next Precise Direction

1. Unify text replacement, redaction, crop, and page-box geometry with the
   precision editing grammar.
2. Add large-object collection summaries without obscuring the active page.
3. Refine Pencil and saved-signature behavior from physical-device evidence.
4. Keep handwritten signatures distinct from certificate-backed signing in
   product language and trust claims.
