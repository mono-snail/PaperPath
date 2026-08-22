# PaperPath V37: Photo QR Intake and Byte Telemetry

## Product Direction

V37 closes two concrete production gaps. Signing identities can now be
recognized from QR images selected through PhotosPicker, while Office artifact
verification reports actual byte progress, throughput, and estimated remaining
time from the existing streaming SHA-256 pass.

The photo path does not request broad photo-library access. The hashing path
does not reread artifacts for telemetry: progress is emitted from the same
bytes already consumed for SHA-256 verification.

## Evidence-Based Competitive Baseline

- Adobe's Office export workflow does not expose byte-level local artifact
  verification telemetry or signer QR intake from Photos:
  <https://helpx.adobe.com/ph_en/acrobat/web/share-review-and-export/export-and-print/export-pdfs.html>
- PDF Expert's iOS feature page does not describe signed delivery identity
  intake combined with artifact hashing throughput:
  <https://pdfexpert.com/ios/features>
- UPDF's conversion material does not present byte-level verified-output
  progress tied to retained Office artifacts:
  <https://updf.com/convert-pdf/batch-pdf-converter/>
- Apple PhotosPicker provides user-selected photo access and Vision provides
  local barcode detection:
  <https://developer.apple.com/documentation/photosui/photospicker>
  <https://developer.apple.com/documentation/vision/vndetectbarcodesrequest>

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Gain |
|---|---|---|---|
| 1 | V36 required a live camera or JSON card | Audit stored-image intake | Clear access gap |
| 2 | Full photo permission would exceed the task | Use PhotosPicker selection | Least-privilege access |
| 3 | QR parsing must stay local | Use Vision barcode detection | Private recognition |
| 4 | Existing verification progress counted only files | Audit the SHA-256 read loop | Reusable telemetry source |
| 5 | Progress needed byte fields | Add processed and total bytes | Measurable work |
| 6 | Users needed performance evidence | Add bytes-per-second throughput | Visible speed |
| 7 | Long checks lacked time context | Add estimated remaining seconds | Better planning |
| 8 | Byte data may be unavailable for legacy receipts | Preserve file-count fallback | Backward compatibility |
| 9 | A second read would double I/O | Emit progress from the hashing stream | No duplicate work |
| 10 | One-megabyte reads caused more stream calls | Increase the serial buffer to 4 MB | Higher throughput |
| 11 | Per-read UI updates could create pressure | Report every 4 MB or at EOF | Bounded updates |
| 12 | Multi-file jobs needed one progress scale | Aggregate retained receipt sizes | Batch-level fraction |
| 13 | File callbacks needed global offsets | Add completed-byte bases per receipt | Continuous progress |
| 14 | Cancelled callbacks could arrive late | Add per-run generation isolation | Stable cancellation |
| 15 | Raw image loading needed a bound | Reject selected image data over 24 MB | Memory guard |
| 16 | General barcode recognition would add noise | Restrict Vision to QR symbology | Focused parsing |
| 17 | Images may contain unrelated QR codes | Accept only PaperPath signer prefixes | Safer result |
| 18 | QR detection could block SwiftUI | Run Vision on a detached user-initiated task | Responsive UI |
| 19 | Photo and camera results could diverge | Reuse the existing identity payload parser | One trust contract |
| 20 | Photo detection must not auto-trust | Reuse candidate review and explicit trust | Preserved consent |
| 21 | Byte evidence could overflow on phones | Use ViewThatFits for horizontal and stacked metrics | Adaptive density |
| 22 | Dynamic numbers should remain stable | Use monospaced digits and numeric transitions | Lower visual jitter |
| 23 | New states needed bilingual copy | Add Simplified Chinese photo-recognition strings | Consistent localization |
| 24 | PhotosUI, Vision, CryptoKit streaming, actors, and SwiftUI changed together | Build both simulator architectures and extension | Compile integration proof |

## Delivered

- PhotosPicker identity QR intake without broad library permission.
- Twenty-four-megabyte selected-image guard.
- Vision QR-only detection on a detached task.
- PaperPath identity-prefix filtering.
- Existing candidate review and cryptographic identity validation reuse.
- Four-megabyte SHA-256 streaming buffer.
- Four-megabyte byte-progress reporting stride.
- Batch-wide processed and total byte accounting.
- Live throughput and estimated remaining time.
- Generation isolation for cancelled or completed verification runs.
- File-count fallback for receipts without byte metadata.
- Adaptive byte, throughput, and ETA evidence rail.

## Competitive Gain

- Versus Acrobat web, PaperPath exposes local verification work in actual bytes
  and keeps source artifacts on device.
- Versus PDF Expert iOS, PaperPath links photo-based signer intake directly to
  signed Office delivery trust.
- Versus UPDF iOS, PaperPath shows measured hashing throughput and ETA for
  retained Office artifacts rather than generic conversion progress.

## Remaining Shortfalls

- Selected photo data is loaded before the 24 MB in-memory limit can be checked.
- If a photo contains multiple PaperPath QR codes, the first valid payload wins.
- Throughput is a stable session average rather than a short rolling window.
- Byte telemetry currently covers verification, not Office reconstruction.

## Next Precise Direction

1. Add image downsampling and multi-code candidate selection.
2. Add rolling throughput samples with stall detection.
3. Extend byte telemetry to ZIP packaging and Office reconstruction.
4. Add trusted-signer search and recent-activity filters.

## Build

`xcodebuild -project PaperPath.xcodeproj -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Result: succeeded for arm64 and x86_64 simulator architectures with the Share
Extension embedded. Unit tests, UI tests, screenshots, and release gates were
intentionally not run.
