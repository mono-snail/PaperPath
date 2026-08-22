# PaperPath V30: Resumable Office Production

## Product Direction

V30 turns the V29 Office batch exporter into a durable production queue. Large
PDF conversions now survive app relaunch, preserve completed parts, resume only
unfinished work, support selective segment retry, and deliver either ordered
files or one deterministic ZIP. Pinned Office outputs are governed across the
whole local library instead of being hidden inside individual documents.

## Competitive Baseline

- Adobe Acrobat has broad conversion and batch capabilities, but interrupted
  work, source revision state, retained artifacts, and delivery evidence are
  not presented as one compact local contract.
- PDF Expert keeps export approachable, but exposes less control over large
  document segmentation, selective recovery, and retained Office artifacts.
- UPDF provides many conversion targets, while partial-success recovery and
  deterministic local batch handoff remain less explicit.
- PaperPath V30 differentiates through revision-bound local recovery: completed
  work survives, unfinished work is selectable, and delivery packaging remains
  inspectable without uploading the PDF.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Gain |
|---|---|---|---|
| 1 | V29 batch state existed only in memory | Audit run, receipt, and retention boundaries | Clear persistence contract |
| 2 | Competitor batch tools hide source freshness | Keep source revision in every manifest | No mixed-version resume |
| 3 | Relaunch discarded queue context | Persist the latest batch run with the document | Durable production state |
| 4 | Active stages cannot literally continue after termination | Restore active work as paused and queued | Honest recovery semantics |
| 5 | Completed segments could be rebuilt unnecessarily | Preserve completed receipt IDs | Less repeated work |
| 6 | Progress callbacks would create excessive index writes | Checkpoint at run and segment boundaries | Lower metadata churn |
| 7 | Changed PDFs could expose a misleading resume action | Invalidate unfinished segments on revision drift | Safer output lineage |
| 8 | V29 only retried an entire batch | Add retryable segment identity sets | Granular recovery |
| 9 | Retry could erase successful work | Reset only explicitly selected segments | Partial success survives |
| 10 | Cancellation affected unrelated failed segments | Scope cancellation to the active retry set | Stable failure history |
| 11 | Failed parts were status text only | Turn retryable rows into selection controls | Direct corrective action |
| 12 | Compact eight-row summaries hid later failures | Add expand-all and collapse controls | Every segment remains reachable |
| 13 | Resume and delivery competed for hierarchy | Make resume primary and delivery a compact menu | Clear next action |
| 14 | Batch delivery required many share-sheet attachments | Add one-ZIP handoff | Simpler external delivery |
| 15 | ZIP creation could multiply memory use | Stream input and output in 256 KB windows | Bounded memory |
| 16 | Archive order could vary | Sort deterministic numbered part names | Reproducible handoff |
| 17 | ZIP recipients lacked page lineage | Add a sorted JSON batch manifest | Self-describing package |
| 18 | Temporary archives could leak | Bind cleanup to share-sheet lifecycle | Lower local residue |
| 19 | Pin quotas were only per PDF | Add a 24-output, 2 GB library contract | Predictable global storage |
| 20 | Pinned files were hard to discover | Add a dense storage-center output lane | One governance surface |
| 21 | Storage cleanup required opening each PDF | Add single-item and bulk unpin commands | Shorter maintenance flow |
| 22 | Bulk cleanup could remove expired artifacts silently | Add explicit destructive confirmation | Clear retention consequence |
| 23 | New controls needed compact localization | Add Simplified Chinese production copy | Consistent bilingual flow |
| 24 | Cross-layer changes needed integration proof | Build both simulator architectures and extension | Compile stability |

## Delivered

- Persisted, revision-bound Office batch manifests in each document record.
- Relaunch recovery that converts interrupted work into an explicit paused run.
- Segment-level retry selection while preserving completed outputs and receipts.
- Expandable high-density batch rows, resume metrics, and compact delivery menu.
- Deterministic ZIP delivery with ordered names and a JSON lineage manifest.
- A streaming stored-ZIP writer with cancellation checks and a 256 KB window.
- Global pinned-output limits of 24 artifacts and 2 GB.
- Storage Center inventory with source navigation, per-item unpin, and bulk
  unpin confirmation.

## Competitive Gain

- Versus Acrobat, PaperPath exposes source freshness, resumability, retained
  parts, and delivery packaging in one local workflow.
- Versus PDF Expert, a failed large-document conversion can restart only the
  affected page ranges.
- Versus UPDF, batch delivery is deterministic, self-describing, bounded in
  memory, and does not depend on a cloud conversion queue.

## Remaining Shortfalls

- Only the latest Office batch manifest is retained per PDF.
- ZIP uses the low-memory stored method; it prioritizes predictable memory over
  additional compression.
- Global pinned quotas are fixed product limits rather than user-configurable
  policies.
- Screenshot and accessibility visual regression remain deferred under the
  compile-only iteration constraint.

## Next Precise Direction

1. Add a cross-document Office production queue with scheduling priority.
2. Add package-level integrity hashes to the ZIP manifest.
3. Add user-selectable retention classes with explicit storage forecasts.
4. Add simulator visual regression for narrow iPhone and accessibility sizes.

## Build

`xcodebuild -project PaperPath.xcodeproj -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Result: succeeded for arm64 and x86_64 simulator architectures with the Share
Extension embedded. Unit tests, UI tests, screenshots, and release gates were
intentionally not run.
