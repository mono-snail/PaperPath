# PaperPath: Secure PDF Studio

**Private PDFs. Verified output.**

PaperPath privately completes important PDFs, preserves the original, and
reopens the finished copy to check it before sharing. Instead of presenting a
grid of unrelated tools, it inspects each PDF on device and surfaces the
shortest useful next actions.

## Product Promise

- Relevant: recommendations come from the current document.
- Private: PDF inspection and OCR run on device.
- Reversible: operations affect a sandbox working copy, not the import source.

## PDF Workflows

- Files-based PDF import
- VisionKit multi-page document scanning
- PDFKit reading and interactive form display
- Text, scan, mixed, form, and protected-document inspection
- Contextual action recommendations
- Persistent native-text and OCR indexing
- Local document classification, fact extraction, and evidence-backed briefs
- Inbox, Reviewing, Ready, and Archived workflow states
- Cross-document full-text search with stage and type filters
- Multi-file PDF import
- Ordered on-device PDF merge
- Page selection and extraction into a new PDF
- Local Vision OCR with confidence reporting
- Searchable PDF copies with an invisible OCR text layer
- Page move, rotate, and delete operations
- Page insertion, append, crop, drag reorder, split, and extraction
- Atomic cross-PDF Bates numbering and removal receipts with portable signed byte-match reports, plus page numbering and editable watermarks
- Searchable annotation review with verified batch removal and local undo
- Highlight, underline, strikethrough, notes, Pencil/touch ink, and PDF stamps
- Interactive form review and reusable local signatures
- Permanent redaction, compression, password protection, and flattened output
- Local PDF export to DOCX, XLSX, searchable PPTX, images, RTF, Markdown, and text
- Verified copies with page checks, metadata removal, SHA-256 receipts, and portable signed delivery-match reports
- Signed delivery packages with on-device recipient verification, protected exact-PDF preview, and system sharing
- Rename, tag, pin, share, and remove private copies
- Unified document/tool search, customizable quick tools, and contextual next actions
- Adaptive iPhone and iPad layouts
- Light, dark, Dynamic Type, VoiceOver, and Reduce Motion support

## Build

Requirements:

- Xcode 26 or newer
- XcodeGen
- iOS 17 or newer

```bash
xcodegen generate
xcodebuild \
  -project PaperPath.xcodeproj \
  -scheme PaperPath \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

## Test

For the complete release automation (unit tests, coverage gates, full iPhone and
iPad UI suites, StoreKit purchase/refund, and a Release build), see
[发布测试与一键运行](docs/RELEASE_TESTING_ZH.md). The runner preserves failures and
rejects unexpected skipped or missing tests; automation success still requires
the documented physical-device and distribution checks before release.

Run the coverage contract before every test pass. It fails when a quick task
or document tool is added without both logic and UI ownership:

```bash
node tools/CheckAutomationCoverage.mjs
```

The machine-readable ownership matrix is
`docs/AUTOMATION_COVERAGE.json`.

```bash
xcodebuild test \
  -project PaperPath.xcodeproj \
  -scheme PaperPath \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

`UITEST_SEED_DEMO` creates deterministic local PDFs when the test library is
empty. `UITEST_RESET_DEMO` removes earlier test copies first, which keeps
end-to-end runs and screenshots reproducible. Neither argument is used during a
normal launch.

## Documentation

- [Signature refinement: 50-round UI and interaction results](docs/APP_SIGNATURE_50_2026_09_27_ZH.md)
- [Latest iPhone/iPad light and dark screenshots](design/app-signature-50-2026-09-27/README.md)
- [Launch closure: 50-round audit and release evidence](docs/LAUNCH_CLOSURE_50_2026_09_27_ZH.md)
- [Current competitor gaps and product boundaries](docs/LAUNCH_COMPETITIVE_GAPS_2026_09_27_ZH.md)
- [App Store submission checklist](docs/APP_STORE_SUBMISSION_CHECK_2026_09_27_ZH.md)
- `docs/PRODUCT_ARCHITECTURE_V1.md`
- `docs/FEATURE_PRIORITIES_V1.md`
- `docs/TECHNICAL_NOTES_PDFKIT_VISIONKIT.md`
- `docs/RELEASE_20_2026_09_26_ZH.md`
- `docs/APP_STORE_METADATA.md`
- `docs/APP_REVIEW_NOTES_2026_09_26.md`
- `docs/PRIVACY_POLICY_DRAFT.md`

## Remaining Device Validation

The signature-refinement report contains the latest visual and interaction
validation. It retains the launch-closure release boundaries: purchase
verification, distribution signing, public support/privacy details, and
device or OS checks that have not passed.

The VisionKit document camera is unavailable in Simulator. Multi-page camera
capture, permission copy, retake behavior, low-light and orientation handling,
OCR accuracy, and high-resolution memory behavior still require a
physical-device pass before release.
