# PaperPath V1 Feature Priorities

## P0 - Product Proof

| Capability | Acceptance criterion |
|---|---|
| PDF import | Select a PDF, copy it into the sandbox, and show it in the library. |
| Batch PDF intake | Import multiple PDFs in one Files pass and create independent working copies. |
| Document camera | Scan one or more pages with VisionKit and create a local PDF. |
| Document inspection | Report pages, size, text coverage, forms, and protection state. |
| Contextual next actions | Recommend OCR for scans, page tools for multi-page files, and share for completed files. |
| Persistent local index | Extract native or OCR text by page, persist it in sidecars, and reload it without rescanning. |
| Document brief | Classify the document and expose an evidence-backed summary, facts, and next steps. |
| Document workflow | Track Inbox, Reviewing, Ready, and Archived state, plus pins and searchable tags. |
| Cross-document search | Match names, full text, summaries, facts, categories, and tags with stage/type filters. |
| PDF workspace | Render PDFs reliably with zoom, search-ready text selection, and page continuity. |
| Page organization | Rotate, move, and delete pages without modifying the original import. |
| Page extraction | Select pages and create a separate ordered PDF working copy. |
| Local PDF merge | Combine two or more PDFs in user-defined order without uploading them. |
| Local OCR | Extract readable text from scanned pages without a network request. |
| Searchable PDF copy | Re-render a scan with an invisible OCR text layer while preserving the source copy. |
| Export copy | Share the current working PDF through the system share sheet. |
| Local library | Persist metadata, rename files, and remove app-owned copies. |
| Privacy evidence | Show concise proof: on device, no account, original untouched. |

## P1 - Release Quality

| Capability | Acceptance criterion |
|---|---|
| Adaptive layout | Use an efficient single-column phone layout and constrained iPad workspace. |
| Large-file handling | Inspect a bounded page sample and avoid eager full-document rendering. |
| Failure recovery | Explain locked, malformed, unsupported, and write-failure states without data loss. |
| Accessibility | Support Dynamic Type, VoiceOver labels, Reduce Motion, and sufficient contrast. |
| Haptics and feedback | Confirm imports, mutations, and OCR completion without relying on haptics alone. |
| Empty and loading states | Every asynchronous and empty state has an explicit, actionable presentation. |
| Unit tests | Cover inspection, understanding, persistence, composition, extraction, and searchable text layers. |
| UI smoke tests | Verify search, brief, merge, workspace, and page extraction on iPhone and iPad. |

## P2 - Post-Prototype

- Shortcuts and App Intents.
- Password-protected local vault.
- Share extension for direct PDF intake.
- Non-destructive annotation tools.
- Scan cleanup controls and receipt-specific capture.
- Saved smart views and reusable batch recipes.
- Calendar/reminder handoff for evidence-backed due dates.

## Deferred

- Existing-text layout editing.
- PDF-to-Office conversion.
- Digital certificate signing.
- XFA authoring.
- Cross-user collaboration.
- Cloud or generative-AI processing.

## Priority Rule

When a feature conflicts with the product reason, use this order:

1. Source-file safety.
2. Correct recommendation.
3. Shortest completion path.
4. Performance and accessibility.
5. Visual polish.
6. Feature breadth.
