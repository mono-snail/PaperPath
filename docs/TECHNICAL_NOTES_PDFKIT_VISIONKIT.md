# PDFKit, VisionKit, and Vision Technical Notes

## PDFKit

### Reading

`PDFDocument` is the document model and `PDFView` is the UIKit renderer. The
SwiftUI layer wraps `PDFView` rather than recreating PDF rendering.

Configuration:

- `autoScales = true`
- `displayMode = .singlePageContinuous`
- `displayDirection = .vertical`
- `displaysPageBreaks = true`
- a transparent renderer background over the PaperPath workspace surface

The wrapper reloads only when the file URL or explicit refresh token changes.
SwiftUI updates must not recreate `PDFDocument` during normal scrolling.

### Inspection

Inspection reads:

- `pageCount`
- sampled `PDFPage.string` character counts
- widget annotations for form-field detection
- `isEncrypted`, `isLocked`, and document permissions
- file byte count from URL resource values

The service samples at most twelve pages. A page with fewer than 24 extracted
characters is considered image-dominant. Classification is intentionally
descriptive rather than absolute: text, scanned, mixed, form, or protected.

### Mutation

Page operations run only against the sandbox working copy:

- `PDFPage.rotation` for clockwise rotation
- `removePage(at:)` for deletion
- `exchangePage(at:withPageAt:)` for adjacent movement

After mutation, `dataRepresentation()` is written with `.atomic`. The app then
re-inspects the document and increments the PDF view refresh token.

### Limits

PDFKit does not provide Word-like paragraph reflow or high-fidelity Office
conversion. Annotation-based black boxes are not secure redaction. V1 does not
claim either capability.

## VisionKit

`VNDocumentCameraViewController` provides:

- automatic edge detection
- perspective correction
- multi-page capture
- user-controlled retakes and ordering

Its delegate returns `VNDocumentCameraScan`. The scan images are rendered into
an A4-like PDF canvas while preserving each image aspect ratio.

The document camera is unavailable in Simulator and on unsupported hardware.
The UI reports this as an environment limitation, not a capture failure.

Camera permission text is included in the generated Info.plist. PaperPath does
not request photo-library-wide access.

## Vision OCR

`VNRecognizeTextRequest` runs with:

- `.accurate` recognition
- language correction enabled
- automatic language detection
- page rendering capped to a 2,200-pixel maximum dimension

The OCR service reconstructs `PDFDocument` from file data inside a detached
task, keeping PDFKit objects out of the main actor. Results include page number,
recognized text, mean confidence, and normalized bounding boxes for every text
block.

OCR results and page-scoped indices are persisted as JSON sidecars. Native PDF
text indexing is capped at 500,000 characters per document. Page mutations
invalidate both sidecars before the document is re-inspected and analyzed.

## Composition and Searchable Output

`PDFCompositionService` copies `PDFPage` objects into a new `PDFDocument` for:

- ordered multi-document merge
- selected-page extraction in ascending source order

`SearchablePDFService` uses `CGPDFDocument` and a PDF `CGContext` to redraw each
source page, maps normalized Vision coordinates into the page box, and writes
recognized strings with Core Text using `.invisible` text drawing mode. The
result is a separate working copy; the source PDF is never rewritten.

The searchable-output test reopens the generated PDF with PDFKit and verifies
that `PDFPage.string` contains the Vision text.

## Concurrency and Memory

- File ownership and metadata writes are serialized by `DocumentStore`.
- PDF rendering is performed one page at a time.
- OCR never retains all page images simultaneously.
- Inspection samples pages rather than scanning the entire document.
- Native indices stop at a bounded character count.
- Composition and searchable-PDF generation run outside the main actor.
- UI updates occur on the main actor.

## Test Strategy

- Generate deterministic PDF fixtures with `UIGraphicsPDFRenderer`.
- Verify text/scan/form classification and evidence-backed understanding.
- Verify imports are copied and remain available after source deletion.
- Verify rotate, move, and delete preserve a readable PDF.
- Verify merge order, page extraction, sidecar persistence, and searchable OCR.
- Use a reset-and-seed launch argument for deterministic UI automation.
- Exercise search, brief, merge, and extraction on iPhone, iPad, dark mode, and
  Accessibility Extra Extra Large.
- Validate VisionKit camera behavior on a real device after simulator tests.
