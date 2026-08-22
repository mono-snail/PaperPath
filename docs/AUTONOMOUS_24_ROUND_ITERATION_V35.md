# PaperPath V35: Signer Trust Exchange

## Product Direction

V35 turns signed-report verification into an explicit trust workflow.
PaperPath now exposes a public signing identity card containing only the local
Key ID and public key, renders a scannable QR payload, exports the identity as
JSON, stores explicitly trusted external signers, classifies valid reports as
this device, trusted, or unknown, and supports trust revocation.

Cryptographic validity and user trust remain separate. A valid signature proves
that the payload matches the embedded public key. Trust is granted only after
the user compares the Key ID through an independent channel.

## Evidence-Based Competitive Baseline

- Adobe's export workflow does not expose a local sender-key exchange or a
  trusted-signer registry for Office delivery reports:
  <https://helpx.adobe.com/ph_en/acrobat/web/share-review-and-export/export-and-print/export-pdfs.html>
- PDF Expert's iOS feature set focuses on editing, conversion, and sharing
  rather than out-of-band signer continuity:
  <https://pdfexpert.com/ios/features>
- UPDF's batch and iOS conversion material does not describe a local signer
  trust registry linked to generated Office packages:
  <https://updf.com/convert-pdf/batch-pdf-converter/>
- Apple Core Image provides local QR generation without a network or external
  image service:
  <https://developer.apple.com/documentation/coreimage/ciqrcodefeature>

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Gain |
|---|---|---|---|
| 1 | V34 showed Key IDs but offered no exchange surface | Audit out-of-band comparison flow | Clear usability gap |
| 2 | Valid signatures were visually conflated with trusted identity | Separate cryptographic status and trust status | Honest interpretation |
| 3 | Competitors stop at share or generic signatures | Define a local signer continuity workflow | Differentiated evidence |
| 4 | Identity exchange must not expose private material | Limit cards to public key and Key ID | Secret isolation |
| 5 | Public identity needed a portable schema | Add a versioned identity-card model | Interoperable output |
| 6 | Report results needed trust context | Add this-device, trusted, unknown, invalid, and unsupported states | Bounded decisions |
| 7 | Trusted signers needed durable records | Store public key, Key ID, dates, and verification count | Local continuity |
| 8 | Valid unknown signers needed an explicit action | Add `canTrustSigner` policy | Safe command availability |
| 9 | QR content needed deterministic bytes | Encode version, Key ID, and Base64 public key | Stable scanning |
| 10 | Identity cards needed shareable files | Export protected JSON to a temporary file | Standard handoff |
| 11 | Temporary identity cards could accumulate | Delete them when the share sheet closes | Lower residue |
| 12 | Trust records must remain local | Add an independent protected signer index excluded from backup | Privacy boundary |
| 13 | Damaged trust metadata could block future use | Remove malformed index data and rebuild empty | Recoverable state |
| 14 | Short Key IDs can theoretically collide | Require the complete public key to match | Strong final comparison |
| 15 | A conflicting public key could overwrite trust | Reject Key ID collisions during registration | Registry integrity |
| 16 | Valid reports needed automatic trust lookup | Compare local key, then trusted registry, then unknown | Deterministic classification |
| 17 | Trusted signer activity should stay current | Update last-verified time and count | Useful history |
| 18 | Users needed revocation | Add remove-trusted-signer action | Complete lifecycle |
| 19 | Identity exchange needed visual scanning | Generate a high-contrast Core Image QR code | Fast out-of-band comparison |
| 20 | Copying identifiers should avoid cross-device clipboard leakage | Use local-only, five-minute pasteboard expiry | Reduced exposure |
| 21 | Identity, QR, and registry risked a fragmented wizard | Combine them in one dense signing-identity workbench | Short workflow |
| 22 | Report decisions needed an immediate action | Add Trust Signer directly in the verification band | Minimal path |
| 23 | Trust language needed bilingual precision | Add Simplified Chinese identity and trust copy | Consistent localization |
| 24 | Core Image, storage, model, verification, sharing, and SwiftUI changed together | Build both simulator architectures and extension | Compile integration proof |

## Delivered

- Versioned public signing-identity card.
- Deterministic QR payload containing Key ID and public key.
- Core Image QR generation with fixed dimensions and high contrast.
- Protected JSON identity-card sharing and automatic temporary cleanup.
- Local-only expiring Key ID pasteboard copy.
- Persistent trusted-signer registry capped at 24 entries.
- Corrupt-index recovery and full-public-key validation.
- Key ID collision rejection.
- This-device, trusted, unknown, invalid, and unsupported trust states.
- Automatic trusted-signer verification counts and last-seen dates.
- Explicit trust and revocation actions.
- High-density identity workbench with QR, public evidence, and signer history.

## Competitive Gain

- Versus Acrobat web, PaperPath supports a local sender identity exchange
  without requiring cloud accounts or certificate uploads.
- Versus PDF Expert iOS, PaperPath separates signature validity from user trust
  and remembers explicitly verified external signers.
- Versus UPDF iOS, PaperPath links mobile Office delivery, signed reports,
  QR-based Key ID comparison, and revocable local trust.

## Remaining Shortfalls

- PaperPath displays QR identity cards but does not yet scan them in-app.
- Trusted signer labels are generated from Key IDs and cannot yet be renamed.
- The trust registry is intentionally device-local.
- Verification progress remains file-count based rather than byte based.

## Next Precise Direction

1. Add in-app QR scanning and identity-card import.
2. Add trusted-signer aliases and notes.
3. Add byte-level hashing throughput and remaining-time estimates.
4. Add optional organization certificates without weakening local-only use.

## Build

`xcodebuild -project PaperPath.xcodeproj -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Result: succeeded for arm64 and x86_64 simulator architectures with the Share
Extension embedded. Unit tests, UI tests, screenshots, and release gates were
intentionally not run.
