# PaperPath V1 Product Architecture

## Product Reason

Most PDF apps present a catalog of tools and ask users to understand the
document before they can choose one. PaperPath reverses that relationship:

> PaperPath understands the document on device, then shows the shortest
> private path to finishing it.

The product promise has three parts:

1. **Relevant**: inspect the current PDF and prioritize only useful actions.
2. **Private**: import, inspection, OCR, and page operations run on device.
3. **Reversible**: preserve the original file and export an explicit copy.

This is not a generic security claim. The interface exposes verifiable facts:
no PaperPath account, no app-managed PDF sync, a private app copy, and an
unchanged source document. Bounded state such as reading position, bookmarks,
tags, workflow, and receipts can merge through the user's iCloud KVS; PDF
bytes, names, OCR text, and extracted content are excluded.

## V1 User Journey

1. Import one or more PDFs, or scan paper with the system document camera.
2. Copy every source into the app sandbox before processing.
3. Inspect and index text, forms, protection state, and document structure.
4. Create a local brief with category, facts, and evidence-backed next steps.
5. Find work through the attention queue, full-text search, tags, and workflow.
6. OCR a scan, merge documents, extract or organize pages, and share an explicit
   output copy.
7. Keep, archive, or remove working copies without touching their sources.

## Architecture

### Presentation

- SwiftUI adaptive navigation for iPhone and iPad.
- `PDFView` wrapped with `UIViewRepresentable`.
- VisionKit document camera wrapped with `UIViewControllerRepresentable`.
- Contextual sheets for the document brief, OCR, merge, and page organization.
- A repeat-use document desk with search, filters, attention, and workflow state.

### Application State

- `PaperPathModel` is the main-actor source of truth.
- Long-running storage and inspection work is asynchronous.
- UI state contains document records, restored text/OCR indices, and transient
  presentation state.

### Domain

- `DocumentRecord`: durable metadata for the app-owned working copy.
- `DocumentProfile`: current inspection result derived from the PDF.
- `DocumentAction`: a small closed set of actions the UI can recommend.
- `DocumentKind`: text, scan, mixed, form, or protected.
- `DocumentTextIndex`: bounded page-scoped native or OCR text.
- `DocumentBrief`: category, summary, detected facts, and suggested steps.
- `DocumentWorkflowStatus`: Inbox, Reviewing, Ready, or Archived.
- `DocumentTaskCheckpoint`: local-only Fill / Sign / Verify stage, page, field,
  and bounded signature placement used to resume interrupted work.

### Services

- `DocumentStore`: actor responsible for sandbox copies and metadata.
- `PDFInspectionService`: read-only PDFKit inspection and recommendations.
- `PDFMutationService`: page rotation, deletion, and ordering using atomic writes.
- `VisionOCRService`: local text recognition using Vision.
- `ScanPDFRenderer`: converts VisionKit scans into a PDF working copy.
- `PDFTextIndexService`: native PDF text extraction and OCR result indexing.
- `DocumentUnderstandingService`: deterministic local classification and fact
  extraction.
- `PDFCompositionService`: ordered merge and selected-page extraction.
- `SearchablePDFService`: visually preserves scans while writing an invisible
  local OCR text layer.

## Data Safety Rules

- Security-scoped imports are copied immediately, then access is released.
- The imported source URL is never mutated.
- Page operations write an atomic replacement of the app-owned copy.
- Metadata is derived again after every mutation.
- Text and OCR sidecars are invalidated after page mutations.
- Deleting a record removes only its app-owned PDF and sidecars.
- Task checkpoints stay in the protected local library index and are excluded
  from iCloud KVS metadata sync.
- Unlock passwords stay in the active workspace session. An editable copy is a
  new checked PDF; the encrypted source remains unchanged.
- XFA and incompatible required fields are preserved for another compatible
  reader instead of being rewritten by PaperPath.
- No networking API or third-party analytics SDK is included in V1.

## Explicit Non-Goals

- Editing existing PDF text with layout reflow.
- Office document import and bidirectional layout conversion. PaperPath may
  export bounded local DOCX, XLSX, and high-fidelity PPTX packages when the
  output contract is explicit and independently verifiable.
- Cryptographic certificate signing.
- XFA form creation.
- Cloud collaboration.
- AI chat or server OCR.
- Generic vector-PDF compression.

These require a mature commercial PDF engine or a service layer and do not
support the first-version product reason.
