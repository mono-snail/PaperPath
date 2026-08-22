# PaperPath V6: 24-Round Deep Workflow Iteration

## Product Direction

V5 made the library and document workspace coherent. V6 extends that language
into the advanced tools. A user should not feel that Organize, Merge, Compress,
Forms, Content, Office Export, and Verified Delivery are separate mini-apps.

Every deep workflow now follows one sequence:

1. Understand the working copy and current constraints.
2. Choose objects or an output intent.
3. Preview the consequence before committing.
4. Create a separate result.
5. Continue directly to the result or verified delivery.

## Competitive Baseline

- PDF Expert provides excellent direct manipulation but exposes fewer
  explainable batch and delivery states.
- Acrobat covers advanced workflows but distributes them across tool hubs,
  modal assistants, cloud prompts, and subscription surfaces.
- PDFgear makes many conversions discoverable but treats format choice as a
  generic list and gives limited help about structural fit.
- PaperPath should combine direct manipulation, local execution, explicit
  compatibility, result continuity, and verified output.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Intended Gain |
|---|---|---|---|
| 1 | Advanced tools use unrelated headers | Introduce one compact workflow command header | Immediate cross-tool familiarity |
| 2 | Counts and constraints hide in sentences | Add parallel workflow metrics | Faster pre-action comprehension |
| 3 | Deep screens repeat large rounded cards | Use flat grouped surfaces and separators | Less assembled-card appearance |
| 4 | Primary actions move between form rows and footers | Standardize persistent command footers | Predictable completion |
| 5 | Result screens feel disconnected from setup | Keep source, output, and continuation in one workflow | Better momentum |
| 6 | iPad advanced tools stay narrow | Expand reading and selection widths with parallel columns | Better use of wide screens |
| 7 | Long explanatory copy wraps frequently | Convert prose into state, metrics, and short labels | Higher information density |
| 8 | Busy states obscure whether work is local | Use one compact on-device progress language | Stronger trust |
| 9 | Page Organizer is a long card list | Use adaptive page rows, compact actions, and selection metrics | Faster page manipulation |
| 10 | Page range and destination choices feel generic | Align selection sheets with document context | Fewer modal context switches |
| 11 | Merge separates order, source, and naming vertically | Present order and available sources in parallel on iPad | Shorter merge setup |
| 12 | Merge result is a separate decorative state | Turn it into a direct result ledger row | Immediate continuation |
| 13 | Batch compression quality and sources compete vertically | Pair output intent with source selection on wide screens | Faster batch setup |
| 14 | Compression results only report success | Surface total input, output, and savings | Clear outcome value |
| 15 | Single compression uses a generic Form | Replace it with an intent-led estimate and quality workflow | Better decision support |
| 16 | Form review mixes compatibility, logic, and fields | Add completion metrics and field-state filtering | Faster form triage |
| 17 | Form continuation is buried in summary copy | Keep the next required field or Verify action persistent | Shorter completion path |
| 18 | Content placement relies on drag and pinch alone | Add deterministic placement commands | Better novice control |
| 19 | Link and image editors duplicate preview work | Introduce one revision-aware editor preview cache | Lower memory and CPU work |
| 20 | Image replacement does not summarize scope clearly | Surface occurrence and replacement scope before commit | Safer object editing |
| 21 | Office and text formats appear as one flat list | Separate editable Office outputs from portable text | Clearer format intent |
| 22 | Export choice lacks document-fit guidance | Add document metrics and recommended target cues | Fewer wrong-format exports |
| 23 | Page image output and embedded extraction are mixed | Separate rendered pages from original embedded assets | Better mental model |
| 24 | Cancellation and stale async results can race UI state | Make preview and operation updates cancellation-aware | Better stability |

## Deliberate Non-Goals

- No online conversion, account, AI assistant, upload, ad SDK, or engagement
  mechanics.
- No claim that DOCX, XLSX, or PPTX reproduces every third-party viewer.
- No automated tests, screenshot pass, StoreKit gate, or physical-device gate
  in this cycle.
- PDF structure preservation and delivery-audit constraints remain unchanged.

## Completion Contract

- Implement all 24 rounds as one deep-workflow system.
- Preserve existing working-tree changes.
- Keep English and Simplified Chinese UI coherent.
- Finish with one signed Debug simulator build.

## Cycle Closure

### Delivered

- Added a shared compact workflow command header with semantic iconography,
  short state copy, parallel metrics, and a consistent local-processing cue.
- Rebuilt Page Organizer around adaptive one/two-column page rows, compact page
  actions, selection counts, undo state, and a persistent extraction footer.
- Rebuilt Merge so order, naming, and available sources run in parallel on
  iPad; source count, page count, input size, output size, and result continuity
  remain visible throughout.
- Rebuilt batch compression so quality intent and source selection run in
  parallel on wide screens, with aggregate input, output, and saved-size
  metrics in the result.
- Replaced the single-compression Form with a dedicated estimate-led workflow,
  segmented quality choice, local progress, and persistent creation command.
- Rebuilt redaction review with page/area/text-layer metrics and a flat marked
  area ledger.
- Added form completion metrics and All, Required, Incomplete, and Complete
  field filters while keeping the next required field or Verify action at the
  top.
- Added deterministic placement controls to content editing and clamped drag
  and resize operations to page bounds.
- Added image-object scope summaries before replacement, including replaceable
  and shared-resource visibility.
- Added one revision-aware, byte-bounded editor preview cache shared by content,
  link, image, and form-field editors.
- Split PDF conversion into Editable Office and Portable Text, with visible
  extensions and compact custom format rows.
- Split rendered page images from embedded source assets and added a document
  context header explaining the output tradeoff.
- Replaced the oversized batch-delivery hero and document fan with selected,
  verified, and attention metrics.

### Competitive Gain

- Compared with PDF Expert, direct manipulation now has more deterministic
  placement, explicit source/result continuity, and stronger batch feedback.
- Compared with Acrobat, advanced operations keep one local workflow grammar
  instead of sending users through separate tool hubs and cloud-oriented
  assistants.
- Compared with PDFgear, conversion formats explain their structural purpose
  and distinguish editable Office output, portable text, rendered pages, and
  original assets.
- PaperPath now carries its private-copy and verified-delivery differentiation
  through setup, processing, result, and continuation rather than only at the
  final share step.

### Remaining Shortfalls

- Protection, annotation review, OCR language selection, and scan review still
  use older screen-specific Form/List compositions.
- Office exports still require external Office/iWork evidence before any
  compatibility claim can be strengthened.
- Very large page collections could benefit from viewport-aware page organizer
  selection summaries and chunked batch result rendering.
- Physical camera, Pencil, locked-device, and sustained large-PDF behavior
  remain outside this compile-only cycle.

### Next Precise Direction

1. Apply the workflow command system to protection, OCR, scanning, annotation
   review, and source write-back.
2. Add viewport-aware page selection and batch-result chunking for very large
   documents.
3. Use external Office/iWork evidence to refine format guidance without
   overstating fidelity.
4. Consolidate remaining duplicated preview utilities behind the shared editor
   preview service.
