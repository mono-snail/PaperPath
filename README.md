# PaperPath: Local PDF Flow

PaperPath is an iPhone and iPad app for reviewing private details and checking
the actual PDF copy before sharing it. MonoWare develops and maintains this
product. This repository exposes its implementation and development history
for inspection. It is not an App Store approval or document certification.

## The shipping workflow

1. Open **Documents > Check before sharing**. Choose a PDF from Files or the
   library, or create a separate fictional sample.
2. Review supported sensitive-information candidates in their page context.
   Select what to remove and explicitly confirm permanent redaction.
3. For a separate image-based delivery copy, open **Deliver > Verify & Share**.
   PaperPath reopens the actual output, checks page count and page rendering,
   and records output checks and its file fingerprint in a **Delivery receipt**.
4. Inspect the output and warnings, then share the PDF or the PDF with its receipt.

Core PDF processing, OCR and privacy detection run on device without a PaperPath
account or AI-model download. Optional support and iCloud metadata sync have
separate network behavior described in the app's privacy information.

Automatic detection can miss content. Image-based output removes searchable
text, links and interactive form fields. File checks do not certify content
accuracy, signer identity or legal compliance. Export important PDFs before
deleting the app: its private library is excluded from automatic device backups.

## Source map

| Implementation | Responsibility |
| --- | --- |
| [ShareCheckStartView](PaperPath/Views/ShareCheckStartView.swift) | Direct entry, file choice and fictional sample |
| [PrivacyScanService](PaperPath/Services/PrivacyScanService.swift) | Sensitive-information candidates |
| [PrivacyScanReviewView](PaperPath/Views/PrivacyScanReviewView.swift) | Page review and explicit redaction confirmation |
| [PDFOutputService](PaperPath/Services/PDFOutputService.swift) | Output copies |
| [PDFDeliveryAuditService](PaperPath/Services/PDFDeliveryAuditService.swift) | Reopening, page checks and fingerprints |
| [DeliveryReceiptView](PaperPath/Views/DeliveryReceiptView.swift) | Receipt, warnings, output and sharing |

The app also includes reading, annotation, form filling, scanning, OCR, page
organization, merge, compression and password protection. These individual
tools are not claimed to be exclusive to PaperPath.

The current release candidate is **1.1.0 (23)**. Experimental AI assistant and
material-packet/rule interfaces retained in source are not exposed in this
release and are not claimed as shipping features.

## Build

Use an existing compatible Xcode installation (the candidate used Xcode 26 or
later) and the checked-in project. Minimum iOS target: 17.

```sh
xcodebuild -project PaperPath.xcodeproj -scheme PaperPath \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

This compiles without creating or booting a simulator. Do not automatically
download platforms, runtimes or AI assets. XcodeGen configuration is included
in `project.yml`. Distribution requires your own signing setup; no signing
credentials are included. The existing Store-bound Bundle ID is retained for
this release, not changed to evade review.

## Verification

See [build-23 validation and boundaries](docs/public/VALIDATION.txt) and the
[actual workflow screenshots](docs/public/PaperPath-23-review-evidence.pdf).
Screenshots come from build-23 simulator validation runs, not mockups.

The full declared inventory was run, followed by fixes and affected-flow retests.
Latest outcomes: iPhone 224/224 UI cases, iPad 225/225 UI cases; on each device,
434 unit cases passed and one physical-device-only file-protection case was
skipped. Original failed runs remain in local evidence. This does not replace
camera, biometric, iCloud or physical-device checks.

Tests and independent output auditors are in `PaperPathTests`,
`PaperPathUITests` and `tools`. Ownership is recorded in
`docs/AUTOMATION_COVERAGE.json`. Project runners require the developer's
registered shared simulator pool; they must not create, clone or erase devices.
Read [test instructions](docs/RELEASE_TESTING_ZH.md) before using them.

## Repository scope and third-party material

This is the iOS source repository. The separately maintained website, Android
work, generated outputs, caches and internal submission drafts are excluded
from the current source tree. Historical development commits are preserved.

Apache POI test fixtures retain their
[LICENSE](PaperPathTests/Fixtures/OfficeInteropCorpus/apache-poi/LICENSE) and
[NOTICE](PaperPathTests/Fixtures/OfficeInteropCorpus/apache-poi/NOTICE).
Downloaded PDF test inputs are excluded from this snapshot and the shipping
app; manifests and fetch tools document provenance. Public visibility does not
change third-party licenses. No new blanket license for project source is
introduced here.

Product and support: https://paperpath.monoware.app/en/
