# PaperPath V19: Office Export Performance and Stability

## Product Direction

V19 focuses on performance and stability rather than adding new user-facing
scope. The Office/DOCX export path now avoids over-reserving visual-reference
bytes across very long documents, releases thumbnail encoding memory sooner, and
records budget-window evidence inside the generated DOCX package.

## Competitive Baseline

- PDF Expert keeps conversion lightweight, but users get little evidence when
  long documents degrade visual references.
- Adobe Acrobat handles large files well, but budget and memory decisions are
  opaque to normal users.
- PDFgear is broad, but large visual conversions can still feel unpredictable.
- PaperPath's advantage is local bounded conversion with inspectable stability
  evidence: route score, budget pressure, anchor policy, reserve window, and
  output metadata.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Intended Gain |
|---|---|---|---|
| 1 | Large DOCX exports reserved against all remaining pages | Add sliding candidate window | Less over-conservative budgets |
| 2 | Critical pages need larger reserve scope | Use full mode window for critical pages | Better scan fallback stability |
| 3 | Image pages need medium reserve scope | Use half window for image pages | Balanced fidelity and size |
| 4 | Table pages need tighter reserve scope | Use one-third window for table pages | Lower package bloat |
| 5 | Page budgets lacked runtime evidence | Track min/max page budget | Easier diagnosis |
| 6 | Candidate volume was invisible | Track visual candidate pages | Better performance receipt |
| 7 | Candidate classes were hidden | Track critical/image/table candidates | Clear policy behavior |
| 8 | Window clipping was invisible | Track budget-window limited count | Auditable stability guard |
| 9 | DOCX metadata lacked V19 counters | Add custom properties for candidate metrics | Portable diagnostics |
| 10 | Earlier pages could starve later pages | Reserve bytes within a bounded window | More stable long exports |
| 11 | Very long docs suffered memory pressure | Wrap thumbnail/JPEG encoding in autoreleasepool | Faster object cleanup |
| 12 | Compression ladder needed no new UI screen | Keep ladder in existing dense budget strip | No workflow expansion |
| 13 | Users could not see reserve strategy | Add WINDOW token to export UI | Clear large-doc behavior |
| 14 | Stability controls should not become settings | Make policy automatic from document profile | Lower user burden |
| 15 | Service/UI naming could drift | Reuse `chunkPageTarget` in reserve summary | Consistent model |
| 16 | DOCX packages should self-describe | Store candidate and budget-window metrics | Better support/debugging |
| 17 | Export should remain cancelable | Keep cancellation check in visual loop | Stop remains responsive |
| 18 | No source mutation allowed | Keep all changes in generated DOCX path | Original protection |
| 19 | No network/cloud dependency | Keep export entirely local | Privacy continuity |
| 20 | Build surface should stay narrow | Touch model, DOCX service, export sheet only | Lower regression risk |
| 21 | UI density must remain high | Add one compact token, no card stack | Less generic layout |
| 22 | Budget math should be bounded | Clamp reserve windows and byte floors | Avoid pathological values |
| 23 | Output must remain OOXML-compatible | Only add custom properties | Word compatibility preserved |
| 24 | Iteration needs closure | Document V19 and compile Debug | Auditable handoff |

## Delivered

- Added priority-aware sliding reserve windows for DOCX visual references.
- Added visual candidate counters: all candidates, critical, image, and table.
- Added page-budget diagnostics: minimum budget, maximum budget, and window
  limited count.
- Added scoped `autoreleasepool` around thumbnail and JPEG encoding.
- Added DOCX custom properties for V19 performance/stability counters.
- Added `reserveWindowSummary` to Office visual budget plans.
- Added `WINDOW` evidence token to the Office export budget strip.

## Competitive Gain

- Compared with PDF Expert, PaperPath now makes large-document budget behavior
  visible and auditable.
- Compared with Acrobat, PaperPath exposes stability policy in the normal export
  workflow instead of hiding it in conversion internals.
- Compared with PDFgear, PaperPath records concrete candidate and budget-window
  counters inside the generated DOCX package.

## Remaining Shortfalls

- Candidate windows are still estimated from page position and priority, not a
  full page-level preflight.
- `pageContainsEmbeddedImage` is still computed per page during export; a future
  page-analysis cache can combine image, table, and fallback signals.
- DOCX package assembly still happens in memory; very large exports should move
  to streaming ZIP assembly.
- Receipts remain session-local and should be persisted.

## Next Precise Direction

1. Add page-analysis cache for DOCX export to avoid repeated page trait work.
2. Move OOXML ZIP assembly to a streaming writer for large documents.
3. Persist Office export receipts in verified output history.
4. Extend the same budget-window and memory policy to PPTX rendering.

## Build

`xcodebuild -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build`

Result: succeeded.
