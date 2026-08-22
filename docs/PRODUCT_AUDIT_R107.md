# PaperPath Product Audit R107

Updated: August 14, 2026

## Product Position

PaperPath is an iPhone and iPad PDF workspace for private, professional
document completion. Its advantage is not the longest tool list. It combines:

1. On-device inspection, OCR, search, classification, and evidence links.
2. Source-safe working copies for every imported document.
3. Short, document-specific routes to the next useful action.
4. Verified outputs for redaction, protection, flattening, and Safe Share.

## Current Capability Summary

### Intake and Creation

- Single and batch PDF import from Files.
- Multi-page VisionKit document scanning.
- Multi-image PDF creation without broad photo-library permission.
- Ordered PDF merge with explicit source order.

### Reading and Retrieval

- PDFKit zoom, continuous, single-page, and two-page layouts.
- Vertical or horizontal navigation with paper, warm, and night surrounds.
- In-document search with direct page navigation.
- Cross-document search across names, text, facts, summaries, and tags.
- Bookmarks, bounded PDF outlines, pins, tags, and workflow filters.

### Local Understanding

- Text, scan, mixed, form, and protected-document inspection.
- Native-text indexing and local Vision OCR.
- Searchable PDF copies with an invisible OCR layer.
- Local classification for contracts, invoices, receipts, reports, letters,
  and forms.
- Evidence-linked dates, amounts, contacts, references, summaries, and next
  steps.

### Editing and Completion

- Highlight, underline, strikethrough, notes, Pencil/touch ink, annotation
  review, and undo.
- Standard interoperable PDF stamps: Approved, Draft, Confidential, Final,
  and Void.
- Protected reusable signatures with size and placement controls.
- Interactive form completion and incomplete-field navigation.
- Page reorder, rotate, delete, insert, crop, append, split, and extract.

### Secure Output

- Compression with explicit quality choices.
- Password-protected copies with session-only unlock credentials.
- Permanent rasterized redaction.
- Flattened PDF, text, and page-image export.
- Safe Share removes editable layers and personal metadata, reopens and
  renders every page, checks blank-page risk, and records a SHA-256 receipt.

### Platform Quality

- Adaptive iPhone and iPad navigation.
- Dynamic Type, VoiceOver labels, Reduce Motion, keyboard shortcuts, dark
  appearance, privacy cover, complete file protection, and backup exclusion.
- No account, analytics SDK, or app-managed network path.

## Competitor Strengths

Sources are the vendors' current iOS/mobile feature pages as of this audit.

- **Adobe Acrobat**: strongest enterprise breadth, original text/image
  editing, conversion, Liquid Mode, shared reviews, PDF Spaces, and
  source-linked generative summaries and Q&A.
- **PDF Expert**: strongest Apple-native editing and reading experience,
  customizable frequent tools, polished Pencil annotation, stamps, audio
  notes, scan enhancement, and broad conversion.
- **Xodo**: broad cross-platform utility coverage, cloud integrations,
  conversion, compression, redaction, and multi-document workflows.
- **PDFgear**: unusually broad free feature set, direct text/image editing,
  forms, stamps, conversion, compression, and AI chat.

Official references:

- https://helpx.adobe.com/acrobat/mobile/get-started/faqs.html
- https://helpx.adobe.com/acrobat/mobile/acrobat-ai/ai-features.html
- https://pdfexpert.com/ios/features
- https://xodo.com/mobile-apps
- https://www.pdfgear.com/pdfgear-for-ios/

## R107 Scorecard

Scores are `0-10`. PaperPath scores require implemented behavior and automated
or simulator evidence; competitors are scored from current official mobile
claims. “Best” is the strongest competitor in the benchmark set.

| Capability | PaperPath | Best | Gap | Position |
|---|---:|---:|---:|---|
| Reading, zoom, page navigation | 8.8 | 9.5 | -0.7 | Trails PDF Expert |
| Reading layouts and surrounds | 8.5 | 9.5 | -1.0 | No true text reflow |
| In-document search | 9.2 | 9.0 | +0.2 | Leads |
| Cross-document search | 9.6 | 8.5 | +1.1 | Leads |
| Evidence-linked local brief | 9.8 | 9.0 | +0.8 | Leads |
| Conversational AI/Q&A | 0.0 | 9.5 | -9.5 | Deliberately absent |
| Local OCR/searchable output | 9.1 | 9.0 | +0.1 | Leads |
| Camera scanning | 8.4 | 9.0 | -0.6 | Device gate |
| Scan cleanup/enhancement | 8.0 | 9.0 | -1.0 | Trails |
| Page reorder/rotate/delete | 9.2 | 9.5 | -0.3 | Near parity |
| Merge, split, extract | 9.3 | 9.0 | +0.3 | Leads |
| Insert, append, and crop | 8.8 | 9.0 | -0.2 | Near parity |
| Text markup | 9.1 | 9.5 | -0.4 | Color presets limited |
| Ink, notes, and stamps | 9.2 | 9.5 | -0.3 | Audio/shapes absent |
| Apple Pencil workflow | 9.0 | 9.5 | -0.5 | Device gate |
| Interactive forms | 8.8 | 9.0 | -0.2 | Near parity |
| Reusable signatures | 9.4 | 9.5 | -0.1 | Device gate |
| Permanent redaction | 9.5 | 9.0 | +0.5 | Leads |
| Compression | 8.8 | 9.0 | -0.2 | Quality tuning pending |
| Password protection | 9.2 | 9.0 | +0.2 | Leads |
| Flattened/Safe Share output | 9.8 | 9.0 | +0.8 | Leads |
| Text and image export | 9.3 | 9.0 | +0.3 | Leads |
| Existing text/image editing | 0.0 | 9.5 | -9.5 | Engine required |
| Office conversion | 0.0 | 9.5 | -9.5 | Engine required |
| Bookmarks and outline | 9.2 | 9.0 | +0.2 | Leads |
| Multiple document tabs | 0.0 | 9.0 | -9.0 | Product gap |
| Cloud sync/collaboration | 0.0 | 10.0 | -10.0 | Privacy boundary |
| Workflow and task closure | 9.8 | 6.5 | +3.3 | Leads |
| Source safety/privacy clarity | 10.0 | 7.5 | +2.5 | Leads |
| Tool discovery and shortest path | 9.4 | 9.0 | +0.4 | Leads after R107 |
| Accessibility/adaptive UI | 9.7 | 8.5 | +1.2 | Leads |
| Native iOS interaction/craft | 9.5 | 9.5 | 0.0 | Parity |

## What R98-R107 Changed

1. **R98 Reliability**: fixed delivery-receipt timestamp persistence.
2. **R99 Unified Search**: one field now finds documents and PDF tools.
3. **R100 First-Look Focus**: reduced the initial tool surface from 14 equal
   choices to four common tasks with one-tap expansion.
4. **R101 Personal Workflow**: users can persist two to six quick tools.
5. **R102 Capability Matching**: document pickers hide incompatible PDFs.
6. **R103 Next Action**: every workspace exposes one contextual executable
   action above the PDF.
7. **R104 Form Closure**: form recommendations route directly to field review.
8. **R105 Safe Share Closure**: Safe Share is a first-class direct task.
9. **R106 Professional Markup**: added five standard PDF stamps and review.
10. **R107 Verification**: strict compilation, 37 unit tests, three complete
    iPhone UI flows, a full 13-inch iPad flow, and screenshot review.

## Remaining Priority

### P0: Release Evidence

- Complete physical-device gates for camera, Pencil, locked-device file
  protection, high-resolution memory/energy, and third-party password readers.
- Tune scan enhancement and compression with a measured document corpus.

### P1: Professional Review Depth

- Add shapes, free text boxes, markup color presets, and annotation-summary
  export.
- Add iPad multi-document tabs only if testing proves it reduces task time.
- Improve form completion for non-interactive PDFs with positioned text,
  checks, and crosses.

### P2: Engine Decision

Original-content editing and Office conversion cannot be made dependable with
PDFKit alone. To exceed Acrobat and PDF Expert in raw breadth, license and
evaluate a mature PDF/conversion engine. Do not add buttons that imply these
capabilities before output fidelity is proven.
