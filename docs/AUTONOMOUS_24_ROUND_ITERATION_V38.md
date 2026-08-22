# PaperPath V38: Multi-Identity Intake and Production Telemetry

## Product Direction

V38 removes three misleading shortcuts from the Office production workflow:
photo QR recognition no longer selects the first result silently, throughput is
measured from a rolling window instead of the full session, and byte telemetry
now covers OOXML construction plus CRC and ZIP delivery packaging.

All byte measurements come from the loops that already build or inspect the
output. No extra pass was added solely for progress reporting.

## Evidence-Based Competitive Baseline

- Adobe's export workflow does not expose local OOXML and ZIP byte-stage
  telemetry:
  <https://helpx.adobe.com/ph_en/acrobat/web/share-review-and-export/export-and-print/export-pdfs.html>
- PDF Expert's iOS feature set does not describe multi-identity QR selection or
  measured Office package throughput:
  <https://pdfexpert.com/ios/features>
- UPDF's conversion flow does not expose CRC, archive-write, and verified-output
  stages as separate local evidence:
  <https://updf.com/convert-pdf/batch-pdf-converter/>
- Apple Vision returns multiple barcode observations and supports local QR
  recognition:
  <https://developer.apple.com/documentation/vision/vndetectbarcodesrequest>

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Gain |
|---|---|---|---|
| 1 | Photo recognition silently used the first QR | Audit Vision result handling | Removed hidden choice |
| 2 | Session-average speed included setup and waiting | Audit rate calculation | Identified distorted metric |
| 3 | Office telemetry began only after output existed | Audit OOXML construction | Found actual byte source |
| 4 | ZIP packaging had CRC and copy phases with no visibility | Audit archive writer | Complete stage map |
| 5 | Byte activities needed shared semantics | Add reconstructing, packaging, checksum, archive, and verify stages | Unified contract |
| 6 | Services needed structured updates | Add byte, unit count, stage, and current-unit payload | Reusable telemetry |
| 7 | Existing operation progress must remain compatible | Add defaulted byte fields | Low migration cost |
| 8 | UI needed stable byte formatting | Add byte and throughput summaries | Dense evidence |
| 9 | Full-session averages reacted slowly | Add a five-second rolling window | Current speed |
| 10 | Very dense updates could make speed noisy | Cap the window at 12 samples | Stable bound |
| 11 | Stage resets could generate negative deltas | Reset samples when stage or byte origin changes | Correct rates |
| 12 | OOXML bytes were known during archive assembly | Instrument package entry generation | Rebuild telemetry |
| 13 | Thousands of Office parts could flood SwiftUI | Report every 2 MB or final entry | Bounded callbacks |
| 14 | ZIP CRC reads were invisible | Instrument CRC at 4 MB intervals | Checksum evidence |
| 15 | ZIP copies were invisible | Instrument archive writes at 4 MB intervals | Packaging evidence |
| 16 | ZIP total size was needed before writing | Precompute exact header, payload, directory, and end-record bytes | Accurate fraction |
| 17 | Normal Office export lacked byte UI | Connect OOXML updates to operation progress | Direct feedback |
| 18 | Segmented export lacked byte UI | Connect each segment and reset its rate window | Batch feedback |
| 19 | Delivery ZIP needed global feedback | Reuse the production integrity rail with stage-aware titles | One workbench |
| 20 | Multiple QR results could contain duplicates | Deduplicate payloads and Key IDs | Clean candidates |
| 21 | Invalid early payloads could hide later valid identities | Inspect up to 64 payloads and collect 12 valid cards | Resilient selection |
| 22 | Multiple valid identities needed an explicit decision | Add compact Key ID candidate rows | No silent trust target |
| 23 | New stages and candidates needed bilingual copy | Add Simplified Chinese strings | Consistent localization |
| 24 | Vision, OOXML, CRC, FileHandle, actors, and three UI surfaces changed together | Build both simulator architectures and extension | Compile integration proof |

## Delivered

- Multi-QR Vision result collection.
- Payload and Key ID deduplication.
- Up to 64 scanned payloads inspected and 12 valid identities presented.
- Explicit Key ID selection before the existing trust confirmation.
- Five-second, 12-sample rolling throughput.
- Stage-reset and monotonic callback protection.
- Shared byte progress stage and update contracts.
- Actual OOXML package construction bytes.
- Exact ZIP output byte forecasts.
- Four-megabyte CRC and archive-copy reporting.
- Two-megabyte OOXML reporting stride.
- Byte telemetry for normal Office exports, segmented exports, batch ZIP files,
  and signed delivery ZIP files.
- Stage-aware global, queue-row, and operation-panel UI.

## Competitive Gain

- Versus Acrobat web, PaperPath reveals local Office construction and delivery
  packaging as measured production stages.
- Versus PDF Expert iOS, PaperPath handles ambiguous multi-identity images
  without silently selecting a trust target.
- Versus UPDF iOS, PaperPath exposes rolling local throughput for OOXML, CRC,
  ZIP writing, and integrity verification.

## Remaining Shortfalls

- PhotosPicker still materializes selected image data before the 24 MB guard.
- Rolling speed updates only when another byte callback arrives; it does not yet
  mark a timed stall.
- OOXML packages are assembled in memory before atomic disk write.
- ZIP creation reads each source once for CRC and once for storage.

## Next Precise Direction

1. Add image downsampling before Vision analysis.
2. Add a two-second stall detector and recent-speed sparkline.
3. Stream OOXML package output directly to protected temporary files.
4. Combine ZIP checksum and write when data-descriptor compatibility is added.

## Build

`xcodebuild -project PaperPath.xcodeproj -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Result: succeeded for arm64 and x86_64 simulator architectures with the Share
Extension embedded. Unit tests, UI tests, screenshots, and release gates were
intentionally not run.
