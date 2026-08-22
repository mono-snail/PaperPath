# PaperPath V8: 24-Round Reading and Version Evidence Iteration

## Product Direction

V8 completes the document lifecycle after capture and editing. Reading,
navigation, technical inspection, comparison, and recovery should form one
evidence-aware experience:

1. Choose a comfortable, document-accurate reading mode.
2. Move by page, label, bookmark, or outline without losing context.
3. Reflow and read text aloud when the page view is not the right surface.
4. Inspect structural and permission evidence before delivery.
5. Compare or restore a protected local version with clear consequences.

The interface must remain compact, native, and information-rich. It should not
look like a sequence of unrelated settings forms and decorative report cards.

## Competitive Baseline

- PDF Expert has excellent page navigation and reading fluency, but technical
  evidence and local recovery are less central to the reading flow.
- Acrobat has broad inspection and comparison capability, but often routes
  reading, tools, cloud files, and version concepts through separate product
  surfaces.
- PDFgear exposes reading and conversion tools but gives less continuity
  between page labels, OCR text, technical structure, and recovery history.
- PaperPath should connect reading position, document semantics, structure,
  comparison, and recovery around one private working copy.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Intended Gain |
|---|---|---|---|
| 1 | Reading settings use a generic Form | Introduce a compact reading command header | Faster configuration |
| 2 | Theme choices consume a tall inline picker | Use an adaptive visual theme rail | Higher density |
| 3 | Layout and navigation direction are separated | Present page layout and direction as one intent | Clearer behavior |
| 4 | Bookmarks, outline, labels, and page jump are mixed | Introduce navigation modes with shared context | Lower scanning cost |
| 5 | Current page context is hidden inside controls | Add current label, page, bookmark, and outline metrics | Better orientation |
| 6 | Page jump only accepts numeric pages | Accept explicit page labels as well as numbers | Better long-document navigation |
| 7 | Bookmark actions are split across sections and menus | Use compact bookmark rows with rename/remove commands | Faster management |
| 8 | Outline depth is shown only through indentation | Add level-aware symbols and compact page targets | Better hierarchy |
| 9 | Page label editing is a long Form | Use a range ledger with inline preview metrics | More predictable numbering |
| 10 | Label range validation appears late | Surface range count and conflict state persistently | Fewer failed creations |
| 11 | Focus Reader opens without reading context | Add source, page, progress, and speech metrics | Immediate orientation |
| 12 | Reader settings live in one long menu | Expose type, width, size, and flow as a compact rail | Faster tuning |
| 13 | Continuous reading renders every page similarly | Emphasize the active page without decorative cards | Better visual tracking |
| 14 | Read-aloud status is represented only by one button | Show speaking, paused, sleep, and rate state | Better control confidence |
| 15 | Speech queue stores every full page string | Queue page indices and resolve text on demand | Lower memory pressure |
| 16 | Technical Inspector repeats a large hero | Replace it with structure, lock, source, and identity metrics | Faster risk assessment |
| 17 | Technical sections remain one long column on iPad | Pair structure/security and source/identity on wide screens | Better wide-screen use |
| 18 | Inspector loading blocks the whole report | Keep a compact local inspection strip | Better continuity |
| 19 | Version History repeats another decorative hero | Use protected count, storage, current revision, and age metrics | Denser recovery context |
| 20 | Version rows emphasize the timeline over consequences | Surface page/size/revision differences beside restore | Safer recovery |
| 21 | Restore progress blocks navigation without a Stop path | Use cancellation-aware Stop while preserving the screen | Predictable recovery |
| 22 | Compare setup is a stacked card | Present base/revised evidence in parallel on iPad | Faster comparison setup |
| 23 | Comparison results use another framed metric card | Reuse flat workflow metrics and direct changed-page rows | Consistent evidence language |
| 24 | Async outline, inspection, history, and comparison can publish stale state | Add generation and cancellation checks | Better stability |

## Deliberate Non-Goals

- No cloud reading sync, account, online AI, upload, advertising SDK, points,
  streaks, or promotional notifications.
- No weakening of technical inspection, version preservation, or restore
  safeguards.
- No automated tests, screenshots, StoreKit gate, or physical-device gate in
  this cycle.

## Completion Contract

- Implement all 24 rounds as one reading-to-recovery evidence system.
- Preserve all existing working-tree changes.
- Keep English and Simplified Chinese UI coherent.
- Finish with one signed Debug simulator build.

## Cycle Closure

### Delivered

- Replaced the generic Reading Form with a compact command header, visual
  surround choices, segmented layout intent, and direction dependency handling.
- Rebuilt navigation around Bookmarks, Outline, and Labels modes while keeping
  current label, bookmark count, outline count, and page-label count visible.
- Added direct page-label lookup as well as numeric page jump.
- Flattened bookmark management into direct open, rename, and remove commands;
  outline rows now expose hierarchy and explicit label targets.
- Replaced Page Labels Form sections with a range ledger, live label previews,
  page/range/conflict metrics, and a persistent create/stop command.
- Added Focus Reader metrics for text page, progress, source, and speech state.
- Exposed typeface, measure, continuous/single-page flow, and text size in a
  compact reader rail; the active or spoken page has a restrained evidence bar.
- Cached the filtered readable-page collection and changed read-aloud to queue
  page indices, resolving reflowed text only when a page is spoken.
- Replaced the Technical Inspector hero with page, access, object, and revision
  evidence; paired structure/security and source/identity on iPad.
- Replaced blocking inspector loading with a compact on-device progress strip
  and added generation-aware inspection publication.
- Replaced the Version History hero with version count, local storage, current
  revision, and latest-version metrics.
- Added a Stop path for restore, cancellation-aware result handling, and
  generation-aware history loading.
- Rebuilt Compare Versions with parallel base/revised evidence on iPad,
  candidate and changed-page metrics, a flat result summary, and generation-
  isolated comparison cancellation.

### Competitive Gain

- Compared with PDF Expert, PaperPath now connects fluent reading navigation to
  explicit page-label semantics, structural evidence, and local recovery.
- Compared with Acrobat, reading, inspection, comparison, and restore remain
  one local workflow without account, cloud-file, or separate tool-hub detours.
- Compared with PDFgear, Focus Reader source evidence, technical structure,
  explicit labels, and protected version consequences remain connected to the
  same private working copy.
- PaperPath's moat now extends from capture through reading and recovery:
  original preservation, visible uncertainty, document semantics, structural
  inspection, change evidence, and reversible local history.

### Remaining Shortfalls

- Signature creation/placement, freehand markup, form-field authoring, and
  image annotation still have separate control grammars.
- Very large outlines and version histories could use incremental snapshots and
  explicit section indexing.
- Read-aloud voice selection and audio-session behavior require physical-device
  evidence before further product claims.
- Restore and comparison remain deliberately local and need large-document
  performance evidence in a later verification phase.

### Next Precise Direction

1. Unify signature, freehand markup, form-field authoring, and image annotation
   around one precision editing grammar.
2. Add incremental outline/version snapshots for very large documents.
3. Refine read-aloud and Pencil behavior from physical-device evidence.
4. Continue reducing duplicated control surfaces while preserving direct
   manipulation and accessibility.
