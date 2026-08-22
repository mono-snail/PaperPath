# PaperPath V39: Adaptive QR Decode and Telemetry Pulse

## Product Direction

V39 makes photo identity intake memory-bounded at decode time and turns byte
telemetry into an operational signal rather than a static speed number.

Selected photo data is decoded through ImageIO thumbnails at 2048 and, when
needed, 4096 pixels before Vision runs. Office and ZIP progress retain recent
throughput samples, detect two seconds without byte movement, and render a
compact trend line across global, queue, and document-level work surfaces.

## Evidence-Based Competitive Baseline

- Adobe's export workflow does not present local rolling throughput or explicit
  byte-stall state:
  <https://helpx.adobe.com/ph_en/acrobat/web/share-review-and-export/export-and-print/export-pdfs.html>
- PDF Expert's iOS feature page does not describe bounded multi-pass QR intake
  connected to signer trust:
  <https://pdfexpert.com/ios/features>
- UPDF's conversion workflow presents task progress without local OOXML, CRC,
  and ZIP throughput histories:
  <https://updf.com/convert-pdf/batch-pdf-converter/>
- Apple ImageIO supports transformed thumbnail decoding without materializing
  full-resolution pixel buffers:
  <https://developer.apple.com/documentation/imageio/1464968-cgimagesourcecreatethumbnailatindex>
- Apple Vision performs local barcode recognition:
  <https://developer.apple.com/documentation/vision/vndetectbarcodesrequest>

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Gain |
|---|---|---|---|
| 1 | Vision decoded selected photos directly | Audit image decode path | Found pixel-memory risk |
| 2 | One small thumbnail could miss distant QR codes | Define two bounded analysis tiers | Recall and memory balance |
| 3 | Throughput stopped updating silently | Audit no-callback state | Identified stall gap |
| 4 | Background timers would add lifecycle complexity | Move time evaluation to visible SwiftUI surfaces | Lower overhead |
| 5 | Progress lacked the last byte time | Add last-byte timestamp | Measurable inactivity |
| 6 | A single rate could not reveal trend | Add 24 recent rolling-rate points | Directional evidence |
| 7 | Stage changes must not mix histories | Clear history on stage or byte-origin reset | Correct trend |
| 8 | Non-byte progress must not fake activity | Update timestamps only when bytes advance | Honest state |
| 9 | Completed work must never appear stalled | Require started, incomplete byte work | Stable completion |
| 10 | Full pixel decode was unnecessary | Create ImageIO source without image caching | Lower baseline memory |
| 11 | Common QR photos need a fast path | Decode a transformed 2048-pixel thumbnail | Fast first pass |
| 12 | Small or distant codes need more detail | Add a transformed pass capped at 4096 pixels | Better recall |
| 13 | Multiple passes could duplicate payloads | Merge and deduplicate QR results | Clean candidates |
| 14 | Image orientation could break recognition | Enable ImageIO thumbnail transforms | Correct framing |
| 15 | Intake decisions lacked decode evidence | Show source size, analysis size, and pass count | Explainable result |
| 16 | Stalls needed deterministic semantics | Mark incomplete work stalled after two seconds | Actionable status |
| 17 | A timer task per job would waste resources | Use one-second TimelineView updates only while visible | Efficient refresh |
| 18 | A chart could destabilize dense layouts | Add a fixed 68 by 20 Canvas sparkline | Stable geometry |
| 19 | Raw speeds vary by orders of magnitude | Normalize each visible sample window | Readable shape |
| 20 | Stale speeds would contradict stall state | Replace old speed with 0 B/s and hide ETA | Honest feedback |
| 21 | Color alone cannot communicate failure | Add pause symbol and explicit Stalled text | Accessible status |
| 22 | Metrics must adapt on narrow phones | Keep ViewThatFits horizontal and stacked contracts | Responsive density |
| 23 | New diagnostics and states needed bilingual copy | Add Simplified Chinese strings | Consistent localization |
| 24 | ImageIO, Vision, actors, Canvas, and TimelineView changed together | Build both simulator architectures and extension | Compile integration proof |

## Delivered

- ImageIO source creation with decode caching disabled.
- Orientation-correct 2048-pixel first-pass thumbnail.
- Optional 4096-pixel second-pass thumbnail.
- Cross-pass QR payload deduplication.
- Source dimensions, analyzed dimension, and pass-count evidence.
- Last real byte-advance timestamps.
- Twenty-four-point rolling throughput histories.
- Two-second incomplete-work stall detection.
- TimelineView refresh without persistent model timers.
- Fixed-size Canvas throughput sparkline.
- Amber stalled trend, pause symbol, explicit status, and `0 B/s`.
- Stale ETA suppression.
- Global delivery, Office queue, and document operation integration.

## Competitive Gain

- Versus Acrobat web, PaperPath distinguishes active local production from a
  byte-level stall and exposes recent throughput direction.
- Versus PDF Expert iOS, PaperPath bounds QR pixel decoding while preserving a
  higher-detail recovery pass.
- Versus UPDF iOS, PaperPath shows measured trends for OOXML, checksum, ZIP, and
  integrity stages instead of a single undifferentiated progress value.

## Remaining Shortfalls

- PhotosPicker still materializes compressed image data before ImageIO receives
  it, although decoded pixel memory is bounded.
- A legitimate stage pause longer than two seconds is displayed as stalled
  until bytes resume.
- Throughput history is session-only and intentionally not persisted.
- OOXML package bytes are still assembled in memory before atomic write.

## Next Precise Direction

1. Load selected photos through file-backed transferable representations.
2. Distinguish expected stage waits from true I/O stalls.
3. Stream OOXML package output to protected temporary files.
4. Add manual recovery actions for sustained production stalls.

## Build

`xcodebuild -project PaperPath.xcodeproj -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Result: succeeded for arm64 and x86_64 simulator architectures with the Share
Extension embedded. Unit tests, UI tests, screenshots, and release gates were
intentionally not run.
