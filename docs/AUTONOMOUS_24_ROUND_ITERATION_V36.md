# PaperPath V36: Signer Intake Workbench

## Product Direction

V36 completes the signing-identity intake loop. PaperPath can now scan another
device's public identity QR code with VisionKit, import a JSON identity card
from Files, validate both through one cryptographic parser, show a candidate
before trust is granted, and maintain local aliases and notes for trusted
signers.

Scanning never creates trust automatically. A detected identity must pass
schema, Ed25519 public-key, and Key ID validation, then receive a second
explicit trust action.

## Evidence-Based Competitive Baseline

- Adobe's export workflow does not provide a local QR signer intake and
  revocable trust-registry workflow:
  <https://helpx.adobe.com/ph_en/acrobat/web/share-review-and-export/export-and-print/export-pdfs.html>
- PDF Expert's iOS features do not describe recipient-side identity QR intake
  connected to generated Office packages:
  <https://pdfexpert.com/ios/features>
- UPDF's conversion workflow does not expose a local signer directory with
  aliases and trust notes:
  <https://updf.com/convert-pdf/batch-pdf-converter/>
- Apple VisionKit provides a proven barcode-recognition engine through
  `DataScannerViewController`:
  <https://developer.apple.com/documentation/visionkit/datascannerviewcontroller>

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Gain |
|---|---|---|---|
| 1 | V35 displayed QR identities but could not read them | Audit the receiver-side path | Clear workflow gap |
| 2 | File sharing alone was slow for in-person comparison | Add camera-based public identity intake | Faster exchange |
| 3 | Hand-written QR recognition would add risk | Use VisionKit DataScannerViewController | Proven scanner |
| 4 | Camera use needed to coexist with document scanning | Reuse and broaden the existing permission contract | Consistent privacy prompt |
| 5 | Trusted records lacked human context | Add optional notes to the signer schema | Better recall |
| 6 | QR parsing needed strict framing | Require `paperpath-signer:v1` and exactly four components | Bounded input |
| 7 | Imported JSON could be oversized | Limit identity cards to regular files under 64 KB | Safer reads |
| 8 | Claimed Key IDs could be forged | Rebuild the Ed25519 public key and recompute Key ID | Cryptographic validation |
| 9 | Users could accidentally trust their own card | Reject local Key ID during intake | Cleaner registry |
| 10 | Camera could recognize unrelated content | Restrict VisionKit to QR barcodes | Lower noise |
| 11 | Repeated frame updates could duplicate a signer | Accept only the first matching payload per scan | Stable result |
| 12 | Scanning directly into trust would be unsafe | Add an intermediate candidate state | Explicit consent |
| 13 | Offline files remained a valid exchange route | Add JSON identity-card import from Files | Complete intake |
| 14 | QR and JSON paths could drift | Route both through the same card validator | One security contract |
| 15 | Existing Key IDs might carry different keys | Preserve full-key collision rejection | Registry integrity |
| 16 | Generated signer labels were hard to recognize | Add editable 64-character display names | Practical identity |
| 17 | Teams need contextual memory | Add 240-character local notes | Better operations |
| 18 | Metadata edits must not weaken trust | Keep Key ID and public key immutable | Safe customization |
| 19 | Signer rows hid useful context | Show alias, Key ID, count, note, and last verification | Dense evidence |
| 20 | Camera support and authorization vary | Handle unsupported, unavailable, denied, and restricted states | Robust entry |
| 21 | Candidate evidence could overflow on phones | Use ViewThatFits for horizontal and vertical contracts | Adaptive layout |
| 22 | Scan and edit actions needed compact commands | Use QR, folder, pencil, trust, and remove icons | Lower visual noise |
| 23 | New states needed bilingual precision | Add Simplified Chinese intake and profile copy | Consistent localization |
| 24 | VisionKit, AVFoundation, storage, model, Files, and SwiftUI changed together | Build both simulator architectures and extension | Compile integration proof |

## Delivered

- VisionKit QR-only signing identity scanner.
- Camera support, availability, and authorization handling.
- One-shot detection for matching PaperPath identity payloads.
- JSON identity-card import with a 64 KB size cap.
- Shared schema, public-key, and Key ID validation for QR and Files.
- Explicit candidate review before trust.
- Local-identity rejection and full-public-key collision protection.
- Trusted signer aliases and notes.
- Immutable trusted public keys and Key IDs.
- High-density profile editor and enriched trusted signer rows.
- Adaptive candidate layout for narrow phones and Dynamic Type.
- Updated camera-purpose language covering document and identity scanning.

## Competitive Gain

- Versus Acrobat web, PaperPath completes local identity exchange without cloud
  accounts, server verification, or certificate upload.
- Versus PDF Expert iOS, PaperPath links in-person QR trust establishment to
  signed Office delivery reports.
- Versus UPDF iOS, PaperPath adds a local, editable, revocable signer directory
  with cryptographic intake validation.

## Remaining Shortfalls

- QR scanning requires supported camera hardware and is unavailable in the
  simulator.
- QR codes stored in Photos are not yet recognized.
- Identity cards establish user-approved continuity, not legal certification.
- Verification progress remains file-count based rather than byte based.

## Next Precise Direction

1. Add QR recognition from Photos and shared images.
2. Add trusted-signer search and recent-activity filters.
3. Add byte-level hashing throughput and remaining-time estimates.
4. Add optional organization certificates without weakening local-only use.

## Build

`xcodebuild -project PaperPath.xcodeproj -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Result: succeeded for arm64 and x86_64 simulator architectures with the Share
Extension embedded. Unit tests, UI tests, screenshots, and release gates were
intentionally not run.
