# PaperPath V7: 24-Round Capture and Review Iteration

## Product Direction

V7 closes the workflow before and after editing. Capture, recognition, review,
protection, and source handling should read as one local document lifecycle:

1. Capture or receive source pages.
2. Correct page quality and order.
3. Recognize and review uncertain text.
4. Review annotations and embedded files.
5. Apply protection or return a verified result to Files.

Every screen must show the object, unresolved work, and next useful command
without relying on oversized titles or repeated explanatory cards.

## Competitive Baseline

- PDF Expert has fluent direct document handling but less explicit OCR review
  and source-state explanation.
- Acrobat covers scan, OCR, review, and protection but spreads them across
  product hubs, assistants, account surfaces, and cloud-oriented language.
- PDFgear exposes many utilities but gives weaker continuity between scan
  cleanup, uncertain OCR, embedded content, and final delivery.
- PaperPath should make the entire lifecycle local, reversible, and visibly
  trustworthy.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Intended Gain |
|---|---|---|---|
| 1 | Scan review dedicates most of the screen to one page | Add a compact page queue and persistent page metrics | Better multi-page awareness |
| 2 | Enhancement presets look like large unrelated cards | Convert them to a compact segmented command rail | Higher control density |
| 3 | Crop, shadow, and edge cleanup are visually disconnected | Group them as parallel cleanup switches | Faster scan correction |
| 4 | Page order actions hide in an overflow menu | Expose reorder, rotate, and remove beside the page queue | Direct manipulation |
| 5 | Scan preview work can return after a newer choice | Make preview updates revision and cancellation aware | Stable live preview |
| 6 | OCR result begins with another oversized privacy card | Replace it with pages, confidence, review, and language metrics | Faster result assessment |
| 7 | Searchable-copy creation appears before uncertainty review | Keep review status and output action in one command strip | Better sequencing |
| 8 | OCR pages are separate cards with repeated chrome | Use a flat page ledger with compact confidence state | Higher text density |
| 9 | Low-confidence correction is hidden in disclosure groups | Surface uncertain line count and direct correction rows | Faster correction |
| 10 | OCR language configuration is a generic Form | Use intent, selected language, and custom-term metrics | Clearer setup |
| 11 | Annotation review has filters but no overview | Add editable, read-only, page, and type metrics | Better review planning |
| 12 | Annotation rows use a card-like List grammar | Use a flat adaptive review ledger | Less visual fragmentation |
| 13 | Annotation export is detached from review state | Keep summary export next to review metrics | Clearer completion |
| 14 | Attachments show extraction limits only inside rows | Add extractable, blocked, page, and byte metrics | Safer attachment handling |
| 15 | Attachment progress blocks the entire screen | Use a compact local operation strip | Better continuity |
| 16 | Protection configuration is a long Form | Pair password state and permission presets in one workflow | Faster secure output |
| 17 | Permission dependencies are implicit | Add explicit permission profiles and allowed-count metrics | Fewer accidental policies |
| 18 | Protection completion has no visible destination model | State that a separate protected copy is created | Better source confidence |
| 19 | Source handling mixes Files state and iCloud metadata | Separate file provenance from optional metadata sync | Clearer privacy boundary |
| 20 | Write-back and re-import actions appear together without priority | Rank actions from safest to destructive | Lower source risk |
| 21 | Source state is expressed mainly as prose | Add source, revision, provider, and sync metrics | Faster diagnosis |
| 22 | Brief and insight repeat large decorative summaries | Reuse compact workflow metrics for document evidence | Denser technical context |
| 23 | Multiple async loaders can publish stale UI | Add generation and cancellation checks to scan, OCR, and source work | Better stability |
| 24 | Long operations use inconsistent cancellation semantics | Standardize Stop without dismissing setup state | Predictable recovery |

## Deliberate Non-Goals

- No online OCR, upload, account, AI assistant, advertising SDK, points, or
  engagement notifications.
- No weakening of PDF permissions, source conflict checks, or structural audit.
- No automated tests, screenshots, StoreKit gate, or physical-device gate in
  this cycle.

## Completion Contract

- Implement all 24 rounds as one capture-to-delivery lifecycle.
- Preserve all existing working-tree changes.
- Keep English and Simplified Chinese UI coherent.
- Finish with one signed Debug simulator build.

## Cycle Closure

### Delivered

- Rebuilt Scan Review around a compact workflow header, page queue, direct
  reorder/rotate/remove commands, edge state, and parallel cleanup controls.
- Reduced scan enhancement presets from large tiles to a compact command rail
  and made preview publication depend on the current page, revision, and exact
  processing options.
- Replaced the OCR result hero with pages, confidence, review, and custom-term
  metrics.
- Kept OCR review filtering and searchable-copy creation in one command row,
  flattened page results, and exposed the first uncertain lines directly for
  correction.
- Replaced OCR configuration Form sections with language intent, adaptive
  language selection, local vocabulary metrics, and a persistent on-device
  recognition command.
- Added annotation metrics for marks, pages, editable objects, and read-only
  appearances; replaced List cards with a flat review ledger and direct
  page/edit/remove actions.
- Added attachment metrics for total, extractable, blocked, and bytes; replaced
  the blocking progress overlay with a compact on-device operation strip and
  made cancelled extraction discard temporary copies.
- Replaced the protection Form with password state, allowed-count metrics,
  Restricted/Review/Flexible permission profiles, explicit dependency handling,
  and a persistent protected-copy command.
- Separated Files provenance from optional iCloud metadata, hid manual sync
  when metadata sync is off, ranked source actions from safe export through
  conflict-preserving import to destructive original replacement, and added
  source/provider/revision/sync metrics.
- Added generation-aware source loading and cancellation-aware source actions.
- Replaced decorative Document Brief and Document Insight summaries with
  compact evidence headers and parallel facts, steps, text, confidence, page,
  size, and recommendation metrics.

### Competitive Gain

- Compared with PDF Expert, PaperPath now exposes OCR uncertainty, source
  conflict, embedded-resource limits, and permission consequences more
  explicitly while retaining direct page manipulation.
- Compared with Acrobat, scan, recognition, review, protection, and source
  handling remain one local lifecycle without cloud prompts, account state, or
  separate product hubs.
- Compared with PDFgear, OCR correction, attachment verification, source
  provenance, and final protection are connected to the same private working
  copy and result path.
- PaperPath's differentiation now covers the entire lifecycle: local intake,
  reversible work, explainable uncertainty, structural review, controlled
  output, and safe source handling.

### Remaining Shortfalls

- Reading navigation, bookmarks, page labels, Focus Reader, technical
  inspection, and version history still have older independent compositions.
- Scan capture and Pencil behavior require physical-device evidence.
- Large OCR results and annotation sets could benefit from incremental
  section snapshots instead of deriving every filter from the full collection.
- Source write-back remains deliberately conservative and still requires
  external Files-provider behavior to be confirmed separately.

### Next Precise Direction

1. Unify reading navigation, bookmarks, page labels, Focus Reader, technical
   inspection, and version history.
2. Add incremental summaries for very large OCR and annotation collections.
3. Refine scan and Pencil controls from physical-device evidence.
4. Continue replacing explanatory prose with visible state and direct commands.
