# PaperPath V32: Verified Office Delivery

## Product Direction

V32 closes the gap between producing Office files and safely handing them off.
The Office queue now observes thermal state, Low Power Mode, and available local
capacity; forecasts working storage before admission; revalidates retained
artifacts with SHA-256 immediately before delivery; and creates one
deterministic cross-document ZIP only when every output passes.

## Evidence-Based Baseline

- Adobe's official web export flow remains centered on selecting, converting,
  and downloading individual PDF files:
  <https://helpx.adobe.com/ph_en/acrobat/web/share-review-and-export/export-and-print/export-pdfs.html>
- PDF Expert's official iOS page confirms broad on-device Office conversion,
  but does not describe a library-level, resource-aware delivery contract:
  <https://pdfexpert.com/ios/features>
- UPDF's official batch guide still describes desktop batch conversion while
  its iOS guide focuses on individual conversion capabilities:
  <https://updf.com/convert-pdf/batch-pdf-converter/>
- Apple's official APIs expose thermal state and Low Power Mode as operating
  conditions applications should respond to:
  <https://developer.apple.com/documentation/foundation/processinfo/thermalstate>
  <https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled>
- PaperPath V32 differentiates through a visible mobile production contract:
  device admission, working-space forecast, content revalidation, failure
  isolation, deterministic packaging, and local cleanup.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Gain |
|---|---|---|---|
| 1 | V31 generated hashes but did not recheck before sharing | Audit retention-to-share boundaries | Clear trust gap |
| 2 | Competitors emphasize conversion completion | Define delivery correctness as a separate gate | Stronger product position |
| 3 | Long mobile exports ignored live device pressure | Add a resource policy model | Explicit operating contract |
| 4 | Storage requirements appeared only after failure | Define output and working-space forecasts | Earlier decisions |
| 5 | Thermal states were not visible in the Office queue | Map nominal, fair, serious, and critical states | Explainable scheduling |
| 6 | Low Power Mode had no queue effect | Add a conserving execution mode | Lower energy pressure |
| 7 | Warm devices started jobs at full cadence | Add inter-job cooldown in conserving mode | Reduced sustained load |
| 8 | Critical heat could continue a long queue | Monitor resources every three seconds | Live protection |
| 9 | Less than 512 MB could still admit heavy work | Block execution and preserve queued intent | Safer local storage |
| 10 | Queue setup lacked output-size context | Estimate bytes from source, page, visual budget, and format | Actionable forecast |
| 11 | Segmented output count was hidden before enqueue | Reuse V30 batch planning in the forecast | Accurate package count |
| 12 | Temporary and retained copies need simultaneous space | Require approximately 2x output plus reserve | Better admission guard |
| 13 | File-size checks cannot prove byte identity | Recompute SHA-256 from the retained file | Content validation |
| 14 | Older retained files may lack a digest | Establish a baseline only after complete read | Backward-compatible evidence |
| 15 | Verification vanished after the action | Persist status and checked timestamp in the receipt | Durable audit state |
| 16 | Missing or changed outputs could join a package | Isolate missing, mismatch, and source-drift results | No partial-trust delivery |
| 17 | Completed jobs required separate shares | Add one cross-document ZIP command | Shorter handoff |
| 18 | Recipients lacked source-to-file mapping | Add source revision, receipt, format, bytes, and hash to manifest | Self-describing package |
| 19 | ZIP creation duplicates retained bytes temporarily | Recheck capacity before archive creation | Fewer late failures |
| 20 | Delivery archives could remain after sharing | Clean the V32 temporary directory on dismissal | Lower residue |
| 21 | Resource, queue, and trust data risked separate pages | Integrate them into the existing production center | Dense parallel workflow |
| 22 | Generic buttons would increase visual noise | Use shield and archive icons with accessibility labels | Compact command hierarchy |
| 23 | New operating states needed localized language | Add Simplified Chinese resource and integrity copy | Consistent bilingual UI |
| 24 | Model, storage, scheduler, archive, and SwiftUI changed together | Build both simulator architectures and extension | Compile integration proof |

## Delivered

- Ready, conserving, and blocked Office resource modes.
- Thermal, Low Power Mode, and available-capacity snapshots.
- Three-second live resource monitor with safe queue suspension.
- Format-aware output forecast and temporary working-space contract.
- Queue admission guard for insufficient local capacity.
- Persisted verified, missing, mismatch, and source-changed receipt states.
- On-demand SHA-256 revalidation immediately before delivery.
- Cross-document ZIP containing all verified completed outputs.
- Deterministic numbered file names and a sorted JSON delivery manifest.
- Pre-archive capacity guard and share-lifecycle temporary cleanup.
- High-density resource rail, forecast rail, integrity labels, and compact
  verify/package commands in Office Production.

## Competitive Gain

- Versus Acrobat web, PaperPath keeps the full validation and packaging path
  local and exposes device admission before conversion.
- Versus PDF Expert iOS, multiple completed documents become one verified
  delivery without reopening each source.
- Versus UPDF iOS, mobile batch delivery includes live resource policy,
  cryptographic revalidation, source revisions, and deterministic evidence.

## Remaining Shortfalls

- Production still requires the app process to remain available; iOS
  termination pauses work for explicit resume.
- Storage forecasts are conservative heuristics, not exact pre-render sizes.
- The ZIP writer uses the stored method to preserve bounded memory.
- Integrity revalidation reports aggregate completion rather than per-file
  progress.

## Next Precise Direction

1. Add cancellable per-file verification progress.
2. Add a retained delivery-package history with explicit expiry.
3. Add optional BGProcessingTask continuation only while charging.
4. Add an exportable standalone verification report for recipients.

## Build

`xcodebuild -project PaperPath.xcodeproj -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Result: succeeded for arm64 and x86_64 simulator architectures with the Share
Extension embedded. Unit tests, UI tests, screenshots, and release gates were
intentionally not run.
