# PaperPath V33: Office Delivery Ledger

## Product Direction

V33 turns verified Office delivery from a temporary share action into a local,
auditable asset lifecycle. Every completed cross-document ZIP now has a
retained ledger record, source-level manifest entries, independent ZIP and
report fingerprints, explicit expiry, pinning, deletion, and verified
resharing. SHA-256 revalidation exposes per-file progress and supports
cancellation.

## Evidence-Based Competitive Baseline

- Adobe's official web export flow is optimized for conversion and download,
  not a retained mobile delivery ledger:
  <https://helpx.adobe.com/ph_en/acrobat/web/share-review-and-export/export-and-print/export-pdfs.html>
- PDF Expert's official iOS page emphasizes editing, conversion, and sharing,
  without presenting source revisions, package retention, and verification
  history as one workflow:
  <https://pdfexpert.com/ios/features>
- UPDF documents desktop batch conversion and individual iOS conversion, but
  does not describe a local iPhone/iPad package ledger with companion reports:
  <https://updf.com/convert-pdf/batch-pdf-converter/>
- PaperPath V33 differentiates by making delivery itself inspectable,
  repeatable, expiring, and cryptographically revalidated.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Gain |
|---|---|---|---|
| 1 | V32 delivery disappeared after the share sheet | Audit temporary package lifecycle | Clear persistence gap |
| 2 | Competitors focus on export completion | Define delivery history as a product surface | Stronger professional position |
| 3 | A package did not own source-level metadata | Add immutable delivery entries | Durable lineage |
| 4 | Indefinite retention would silently consume storage | Define a three-day default contract | Predictable footprint |
| 5 | Aggregate verification hid current work | Add completed, total, and current-source progress | Visible execution |
| 6 | Users could not stop a long hash pass | Propagate task cancellation through streaming SHA-256 | Responsive control |
| 7 | ZIP identity alone did not describe contents | Preserve record, revision, receipt, format, bytes, and hash per entry | Inspectable package |
| 8 | A standalone report needed its own identity | Add a companion verification JSON file | Portable evidence |
| 9 | Package and report could diverge | Fingerprint ZIP and report independently | Dual integrity contract |
| 10 | Retention writes could leave half-complete assets | Copy through protected staging files | Atomic local handoff |
| 11 | Delivery assets mixed poorly with PDF records | Add an independent OfficeDeliveries directory | Clear ownership |
| 12 | Package metadata needed durable indexing | Add a protected, sorted JSON ledger | Relaunch persistence |
| 13 | Expired records could outlive files | Prune metadata and both files together | Consistent cleanup |
| 14 | History could grow without limit | Keep at most eight packages | Bounded storage |
| 15 | Important deliveries needed longer retention | Allow up to four pinned packages | Explicit exception |
| 16 | Unpinning an old package could expire immediately | Restart the three-day standard period | Predictable transition |
| 17 | Relaunch could expose missing package rows | Validate archive and report presence during load | Stable history |
| 18 | Repeat sharing might trust stale bytes | Rehash ZIP and report before every reuse | Strong reshare safety |
| 19 | Recipients may need evidence without Office files | Add Share Verification Report | Smaller audit handoff |
| 20 | Ledger management needed direct controls | Add share, report, pin, unpin, and delete actions | Complete lifecycle |
| 21 | Retained package bytes were hidden | Add Office delivery packages to Storage Center | Full accounting |
| 22 | A separate history screen would fragment the flow | Integrate the ledger below the production queue | Dense continuity |
| 23 | New lifecycle states needed bilingual clarity | Add Simplified Chinese ledger copy | Consistent localization |
| 24 | Storage, model, archive, share, and SwiftUI changed together | Build both simulator architectures and extension | Compile integration proof |

## Delivered

- Persisted Office delivery package and source-entry schemas.
- Protected OfficeDeliveries storage and sorted ledger index.
- Atomic staging for ZIP and standalone JSON report retention.
- Separate SHA-256 fingerprints for the ZIP and verification report.
- Revalidation of both files before every historical share.
- Per-file verification progress with current source and cancellation.
- Three-day standard expiry, maximum eight packages, and maximum four pinned.
- Relaunch pruning for expired, missing, or excess package records.
- High-density delivery ledger inside Office Production.
- Package sharing, report-only sharing, pinning, unpinning, and deletion.
- Storage Center accounting for retained Office delivery packages.

## Competitive Gain

- Versus Acrobat web, PaperPath preserves a local delivery history after
  conversion instead of ending at download.
- Versus PDF Expert iOS, PaperPath can revalidate and reshare a multi-source
  Office package without reopening every PDF.
- Versus UPDF iOS, PaperPath exposes package expiry, source revisions,
  companion verification reports, and independent hashes on mobile.

## Remaining Shortfalls

- Verification progress is file-count based rather than byte based.
- The JSON report is hashed but not digitally signed by an external identity.
- Delivery history remains local to the device by design.
- Production and verification pause when iOS terminates the process.

## Next Precise Direction

1. Add byte-level verification throughput and remaining-time estimates.
2. Add optional signed reports backed by a locally protected signing key.
3. Add charging-only BGProcessingTask continuation.
4. Add a recipient-side report verification workflow.

## Build

`xcodebuild -project PaperPath.xcodeproj -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Result: succeeded for arm64 and x86_64 simulator architectures with the Share
Extension embedded. Unit tests, UI tests, screenshots, and release gates were
intentionally not run.
