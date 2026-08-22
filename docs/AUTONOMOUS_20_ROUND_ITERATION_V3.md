# PaperPath Autonomous 20-Round Iteration V3

Baseline tag: `autonomous-20-v3-baseline`

## Direction

The first two cycles made PaperPath discoverable and efficient. The third cycle
must make it resilient as a long-lived, local document workspace.

Competitive references:

- Xodo: local file management, configurable reading, annotation presets, and
  multi-document workflows.
- Acrobat: project spaces, mobile reading, and evidence-linked navigation.
- UPDF: trash, local security space, page creation, batch handling, and
  technical document controls.

PaperPath will translate those strengths into a private, auditable architecture.
It will not add cloud accounts, online AI, link sharing, or background document
uploads.

## Twenty Product Rounds

Documentation, refactors, builds, screenshots, automated tests, and validation
do not count as rounds.

| Round | Product delivery |
|---|---|
| 1 | Replace destructive library removal with recoverable soft deletion |
| 2 | Add a Trash center with restore and permanent deletion |
| 3 | Add user-controlled Trash retention and automatic local cleanup |
| 4 | Detect exact duplicate PDFs and provide a focused cleanup workflow |
| 5 | Add an inspectable local storage center with largest-file actions |
| 6 | Add document due dates with compact library status |
| 7 | Add Today and Overdue work views driven by due dates |
| 8 | Add private document notes |
| 9 | Add a workflow board for Inbox, Reviewing, Ready, and Archived |
| 10 | Create blank PDFs from useful paper templates |
| 11 | Create PDFs from selected photos without uploading them |
| 12 | Add full-library page-level search with complete match lists |
| 13 | Add a local evidence pinboard and protected Markdown export |
| 14 | Show reading progress and estimated time remaining |
| 15 | Add a sleep timer to local text-to-speech |
| 16 | Replace anonymous page bookmarks with optional named bookmarks |
| 17 | Add configurable App Lock delay policies |
| 18 | Add a technical PDF inspector for permissions, structure, and source |
| 19 | Create protected local version snapshots before destructive mutations |
| 20 | Add version history, comparison context, and one-tap restore |

## Guardrails

- Every round must expose a complete user workflow with a visible outcome.
- The imported Files source remains untouched unless source replacement is
  explicitly chosen.
- PDF bytes, names, OCR text, notes, search evidence, and versions remain local.
- Use iOS-native interaction, Dynamic Type, Reduce Motion, semantic colors, and
  VoiceOver labels.
- Do not add or run automated tests in this cycle. Run one final complete Build
  only as the required compilation gate.
