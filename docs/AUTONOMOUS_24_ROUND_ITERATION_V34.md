# PaperPath V34: Signed Delivery Reports

## Product Direction

V34 upgrades Office verification reports from hashed files to signed evidence.
Each PaperPath installation owns a local Ed25519 signing identity protected by
the iOS Keychain. Delivery reports contain a structured payload, public key,
Key ID, and signature. PaperPath can import a report from Files, normalize the
payload, verify the signature offline, and distinguish this device from an
external signer.

This is deliberately a local continuity and tamper-evidence model. It does not
claim that an embedded public key is a government, enterprise, or cloud-issued
identity certificate.

## Evidence-Based Baseline

- Adobe's mobile and web export flows focus on conversion and download rather
  than offline report signing and recipient-side verification:
  <https://helpx.adobe.com/ph_en/acrobat/web/share-review-and-export/export-and-print/export-pdfs.html>
- PDF Expert's official iOS feature page documents conversion and sharing but
  not a user-visible signing identity for generated verification reports:
  <https://pdfexpert.com/ios/features>
- UPDF documents batch conversion and iOS conversion but does not present an
  offline signed delivery-report workflow:
  <https://updf.com/convert-pdf/batch-pdf-converter/>
- Apple provides Curve25519 signing through CryptoKit and device-local secret
  persistence through Keychain Services:
  <https://developer.apple.com/documentation/cryptokit/curve25519/signing>
  <https://developer.apple.com/documentation/security/keychain-services>

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Gain |
|---|---|---|---|
| 1 | V33 hashes detected file changes but did not identify a signer | Audit hash-versus-signature semantics | Clear trust boundary |
| 2 | Competitors stop at export or share | Define signed delivery evidence as a product layer | Differentiated workflow |
| 3 | Raw JSON whitespace can change without semantic change | Sign a decoded structured payload | Stable verification |
| 4 | Embedded keys can be mistaken for certified identity | Define trust-on-first-use and Key ID comparison | Honest security language |
| 5 | Report fields lacked a signed schema | Add a V34 payload containing package, dates, output count, and entries | Versioned contract |
| 6 | A signature needed explicit algorithm metadata | Add Ed25519 algorithm, public key, Key ID, and signature fields | Portable envelope |
| 7 | Verification needed bounded outcomes | Add valid, invalid, and unsupported states | Predictable UI |
| 8 | Imported reports needed useful evidence | Return package, signer, source count, output count, and date | Actionable result |
| 9 | Package history did not identify its signer | Persist the signer Key ID in the delivery ledger | Continuity evidence |
| 10 | Private keys must never enter reports or files | Generate and retain the Ed25519 private key in Keychain | Secret isolation |
| 11 | A synced key would weaken device provenance | Use `WhenUnlockedThisDeviceOnly` accessibility | Device-local identity |
| 12 | Full public keys are difficult to compare | Derive a 16-character Key ID from public-key SHA-256 | Scannable identity |
| 13 | Damaged Keychain data could block signing forever | Remove corrupt entries with a clean base query | Recoverable identity |
| 14 | Report output still needed human readability | Encode the signed envelope as sorted, pretty JSON | Inspectable evidence |
| 15 | Package and standalone report must match | Put the same signed report inside the ZIP and beside it | One evidence source |
| 16 | Recipients lacked an in-app verification path | Add Verify External Report to Office Production | Offline validation |
| 17 | Unbounded JSON imports could waste memory | Restrict verification reports to regular files under 5 MB | Safer input |
| 18 | JSON key order must not affect verification | Decode and re-encode the payload canonically before checking | Deterministic signatures |
| 19 | A forged Key ID could mislabel a valid public key | Recompute Key ID and require it to match | Envelope integrity |
| 20 | Valid signatures from another device need context | Label this-device versus external signer | Better interpretation |
| 21 | Results needed to coexist with the queue | Add a compact evidence band with signer and counts | Dense workflow |
| 22 | Success and failure needed immediate feedback | Add seal symbols, semantic color, haptics, and dismissal | Clear response |
| 23 | Signing language needed bilingual precision | Add Simplified Chinese signing and verification copy | Consistent localization |
| 24 | CryptoKit, Security, model, storage, Files, and SwiftUI changed together | Build both simulator architectures and extension | Compile integration proof |

## Delivered

- Structured V34 verification payload and signed report envelope.
- Local Ed25519 signing identity stored in iOS Keychain.
- `WhenUnlockedThisDeviceOnly` private-key accessibility.
- Public-key SHA-256 Key ID for visual comparison.
- Canonical payload encoding for signing and verification.
- Key ID recomputation and Ed25519 signature validation.
- Files-based import for external PaperPath JSON reports.
- Five-megabyte input cap and unsupported-format isolation.
- Valid, invalid, and unsupported verification outcomes.
- This-device versus external-signer interpretation.
- Signer identity in the delivery-ledger header and package rows.
- High-density result band with signer, sources, outputs, and creation date.

## Competitive Gain

- Versus Acrobat web, PaperPath can produce and validate delivery evidence
  offline without uploading source documents or verification reports.
- Versus PDF Expert iOS, PaperPath exposes a persistent signing identity and
  recipient-side report verification in the same production workbench.
- Versus UPDF iOS, PaperPath links mobile batch delivery, source revisions,
  SHA-256 artifacts, signed reports, and local verification.

## Remaining Shortfalls

- Embedded public keys establish continuity, not a third-party certified legal
  identity.
- Key IDs must be compared through a trusted channel for strong sender
  authentication.
- The signing identity cannot migrate to another device by design.
- Verification progress remains file-count based rather than byte based.

## Next Precise Direction

1. Add QR and text export for out-of-band Key ID comparison.
2. Add byte-level hashing throughput and remaining-time estimates.
3. Add optional organization certificates without weakening local-only use.
4. Add charging-only BGProcessingTask continuation.

## Build

`xcodebuild -project PaperPath.xcodeproj -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Result: succeeded for arm64 and x86_64 simulator architectures with the Share
Extension embedded. Unit tests, UI tests, screenshots, and release gates were
intentionally not run.
