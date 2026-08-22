# PaperPath V31: Local Office Production Queue

## Product Direction

V31 moves Office reconstruction from a document-level export command to a
library-level production system. Users can select many private PDFs, accept a
per-document route recommendation or force a shared Office format, assign
priority, and let PaperPath rebuild one job at a time under a stable memory
contract. Every retained artifact receives a SHA-256 fingerprint.

## Evidence-Based Competitive Baseline

- Adobe's official web guide, updated April 9, 2026, documents a
  select-file, choose-format, convert, and download flow for Word, Excel,
  PowerPoint, and images. PowerPoint requires an Acrobat PDF Pack
  subscription:
  <https://helpx.adobe.com/ph_en/acrobat/web/share-review-and-export/export-and-print/export-pdfs.html>
- PDF Expert's official iOS feature page confirms Word, Excel, PowerPoint,
  image, and text conversion directly on iPhone and iPad, while its individual
  guides begin by opening one PDF and entering Export:
  <https://pdfexpert.com/ios/features>
- UPDF's official iOS guide confirms Word, Excel, PowerPoint, images, OCR, and
  Security Space. Its 2026 batch guide states that batch conversion is
  currently available on Windows and Mac:
  <https://updf.com/updf-ios-user-guide/introduction/>
  <https://updf.com/convert-pdf/batch-pdf-converter/>
- PaperPath V31 targets the uncovered mobile workflow: multi-document local
  scheduling with source revision binding, serial memory control, resumable
  status, retained evidence, and per-artifact integrity fingerprints.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Gain |
|---|---|---|---|
| 1 | V30 only coordinated parts inside one PDF | Audit library-to-export ownership boundaries | Clear queue scope |
| 2 | Competitors emphasize format breadth | Preserve Word, Excel, and PowerPoint parity | No regression in coverage |
| 3 | Mobile competitor flows start from one open PDF | Add a library-level multi-PDF production entry | Fewer repeated opens |
| 4 | Desktop batch tools do not expose mobile resource contracts | Make serial execution a visible metric | Predictable device load |
| 5 | Queue work had no durable schema | Add revision-bound production jobs | Recoverable intent |
| 6 | Format choice could become stale after enqueue | Freeze the selected route per job | Deterministic output |
| 7 | Job history could grow without bounds | Preserve active work and cap terminal history at 40 | Bounded metadata |
| 8 | Relaunch could leave impossible active stages | Restore active jobs as paused | Honest recovery |
| 9 | Queue state did not have protected storage | Add an atomic file-protected queue sidecar | Local durability |
| 10 | Queue metadata was absent from storage accounting | Include the sidecar in local metadata bytes | Complete accounting |
| 11 | Parallel Office jobs could multiply visual buffers | Execute exactly one job at a time | Stable memory ceiling |
| 12 | FIFO alone ignores urgent work | Add urgent, standard, and background priority | User-controlled order |
| 13 | One scheduler needed to support small and huge PDFs | Route single files and V30 segmented jobs together | One production contract |
| 14 | Source edits could silently change queued work | Reject jobs when the content revision changes | Strong lineage |
| 15 | Cancellation inside segmented export was normalized internally | Recheck task cancellation at the queue boundary | Correct pause/cancel state |
| 16 | File-size checks cannot identify exact bytes | Stream SHA-256 while retaining each artifact | Content identity evidence |
| 17 | Batch delivery lacked cryptographic part identity | Add each retained SHA-256 to the ZIP manifest | Verifiable handoff |
| 18 | Office evidence stopped at route and runtime yield | Surface short fingerprints in receipt rows | Fast visual confirmation |
| 19 | Full evidence omitted the digest | Add integrity evidence to the inspector | Auditable artifact |
| 20 | Library users needed a direct queue entry | Add Office Queue to the command center | One-tap discovery |
| 21 | Selected PDFs could not become production jobs directly | Add Office to the multi-select action bar | Minimal scheduling path |
| 22 | A separate setup wizard would lower information density | Combine queue, setup, sources, and controls in one workbench | Parallel decision flow |
| 23 | Queue controls needed localized production language | Add Simplified Chinese states and commands | Consistent bilingual UI |
| 24 | Scheduler, storage, model, and SwiftUI changed together | Build both simulator architectures and extension | Compile integration proof |

## Delivered

- Persistent cross-document Office production queue.
- Per-job source revision, source name, page count, format, priority, receipts,
  stage, timestamps, and error detail.
- Serial execution across normal and segmented Office reconstruction.
- Urgent, standard, and background scheduling with live reprioritization.
- Pause, resume, cancel, retry, source-drift blocking, and interrupted-job
  restoration.
- SHA-256 fingerprints on newly retained Office outputs and V31 ZIP manifests.
- Receipt-level and inspector-level integrity evidence.
- High-density production center with queue metrics, searchable source
  selection, per-PDF route previews, and direct job controls.
- Entry points in the library command center and multi-select action bar.

## Competitive Gain

- Versus Acrobat web, PaperPath keeps source PDFs and queue state on device and
  exposes revision lineage before conversion starts.
- Versus PDF Expert iOS, PaperPath schedules many library documents without
  repeatedly opening each source and entering Export.
- Versus UPDF iOS, PaperPath brings batch scheduling to iPhone and iPad while
  making serial resource limits, recovery state, and artifact hashes visible.

## Remaining Shortfalls

- iOS termination pauses active production; the user resumes it after relaunch.
- Concurrency is intentionally fixed at one rather than adapting to device
  thermal state and available memory.
- SHA-256 is generated at retention time but is not recomputed on every share.
- Production queue state is deliberately local and is not synchronized through
  iCloud metadata.

## Next Precise Direction

1. Add thermal- and power-aware queue admission without increasing concurrency.
2. Add on-demand integrity revalidation before external sharing.
3. Add one queue-level delivery package spanning multiple source PDFs.
4. Add retention forecasts before a large queue is started.

## Build

`xcodebuild -project PaperPath.xcodeproj -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Result: succeeded for arm64 and x86_64 simulator architectures with the Share
Extension embedded. Unit tests, UI tests, screenshots, and release gates were
intentionally not run.
