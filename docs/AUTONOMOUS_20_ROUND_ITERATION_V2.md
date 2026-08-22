# PaperPath Autonomous 20-Round Iteration V2

Baseline tag: `autonomous-20-v2-baseline`

## Product Direction

The first autonomous cycle made PaperPath's main actions visible. The second
cycle must make sustained document work faster and safer:

1. Organize a growing local library without introducing cloud accounts.
2. Move among documents and pages without losing reading context.
3. Turn repeated markup into a personalized, one-tap workflow.
4. Make review evidence portable, not trapped inside the PDF.
5. Expose privacy controls as real behavior rather than reassurance copy.

The comparison targets are:

- PDF Expert for reading rhythm, indexed search, and customizable tools.
- Xodo for multi-document switching and reusable annotation presets.
- Acrobat for small-screen readability and hands-free document access.
- PDFgear for broad feature discoverability and short task paths.

PaperPath will not copy their cloud collaboration or online AI surfaces. Its
advantage remains private working copies, on-device understanding, and verified
delivery.

## Twenty Product Rounds

Builds, tests, screenshots, validation, and documentation do not count as
rounds.

| Round | User problem | Product delivery |
|---|---|---|
| 1 | One row density cannot serve scanning and visual browsing | Persistent List / Grid library views |
| 2 | Tags exist in the model but cannot be managed visibly | Focused single-document tag editor |
| 3 | Tags cannot narrow a large library | Horizontal tag filter rail with counts |
| 4 | Common document states require manual filters | Smart views for attention, scans, forms, ready, and verified |
| 5 | Repeated searches must be retyped | Private, bounded library search history |
| 6 | Filing several documents repeats the same action | Bulk add and remove tags |
| 7 | Experimenting requires re-importing the source | Duplicate private working copy |
| 8 | Switching among active PDFs loses context | Recent-document tab strip in the workspace |
| 9 | Long PDFs are slow to traverse page by page | Direct page scrubber with stable page feedback |
| 10 | Following links and findings loses the prior location | Back / Forward page navigation history |
| 11 | Reading chrome competes with the page | Immersive reading mode with one-tap restore |
| 12 | Frequent in-document queries are forgotten | Per-device document search history |
| 13 | Search results are difficult to scan | Match count, query-highlighted snippets, and result position |
| 14 | Markup colors are fixed and repetitive | Persistent color presets for highlight, underline, and strike |
| 15 | A dense annotation list mixes unrelated review work | Annotation type filters with live counts |
| 16 | Review evidence cannot leave the app | Local annotation summary export |
| 17 | Printing is hidden behind external handoff | Explicit system Print action |
| 18 | App switching protection does not stop local reopening | Optional Face ID / passcode app lock |
| 19 | Sensitive previews remain visible inside the active app | Inspectable thumbnail privacy control |
| 20 | Verified outputs are hard to revisit from the library | Delivery Center for current and expired receipts |

## Guardrails

- Each round must ship an independently visible workflow or capability.
- Keep the imported source untouched unless the user explicitly chooses source
  replacement.
- Keep PDF bytes, OCR text, names, and extracted content off
  PaperPath-managed networks.
- Use native iOS controls, system fonts, semantic colors, Dynamic Type,
  reduced-motion behavior, and useful VoiceOver labels.
- Do not add marketing, onboarding, cloud accounts, or online AI.
- Prefer compact controls and progressive disclosure over more explanatory
  cards.
