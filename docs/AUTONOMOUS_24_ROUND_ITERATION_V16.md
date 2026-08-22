# PaperPath V16: Office Budget and Export Receipt Loop

## Product Direction

V16 closes the gap left by V15. V15 made Office routes explainable before
export; V16 makes Office export resources visible before export and confirms the
actual generated file immediately after export. The user no longer has to infer
whether DOCX visual references are high detail, bounded, or large-document
optimized.

## Competitive Baseline

- PDF Expert offers convenient conversion, but visual-reference budgets and
  large-file behavior are opaque.
- Adobe Acrobat has powerful conversion controls, but the user often sees
  heavyweight dialogs rather than a compact, task-local receipt.
- PDFgear is broad, but its conversion flow does not expose a structured local
  receipt that connects route score, output size, and visual-anchor strategy.
- PaperPath's advantage is a privacy-first evidence loop: route choice,
  resource policy, package audit metadata, and completion receipt stay in one
  local workflow.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Intended Gain |
|---|---|---|---|
| 1 | DOCX budget mode was a raw string | Add typed `PDFOfficeVisualBudgetMode` | Safer strategy model |
| 2 | UI could not explain visual budgets | Add `PDFOfficeVisualBudgetPlan` | Visible resource policy |
| 3 | Large PDFs lacked chunk guidance | Add chunk targets and counts | Predictable long exports |
| 4 | Users could not see image-anchor estimate | Estimate visual reference pages | Better file-size expectation |
| 5 | Total and per-page budgets were hidden | Expose formatted budget values | Clear package boundaries |
| 6 | Compression strategy was implicit | Add mode-level compression percent | Transparent fidelity tradeoff |
| 7 | Edge length was hidden in code | Surface longest visual edge | Concrete quality signal |
| 8 | Export completion only opened share sheet | Add Office export receipt model | Confirmation without guessing |
| 9 | Generated file size disappeared after share | Capture output file size | Immediate size proof |
| 10 | Route score was pre-export only | Carry route score into receipt | Closed decision loop |
| 11 | Budget strategy was pre-export only | Carry budget mode into receipt | Output traceability |
| 12 | Visual estimates were lost after export | Carry visual estimate into receipt | Better post-export review |
| 13 | DOCX custom metadata lacked budget details | Add edge, compression, and per-page budget | Stronger audit trail |
| 14 | Service/UI could drift | Share budget mode through one model | Less duplication |
| 15 | Office section risked becoming verbose | Use compact tokens and score rows | Higher density |
| 16 | Receipts should not block sharing | Show receipt inline instead of modal | Faster flow |
| 17 | Completed output needed time context | Add local short timestamp | Clear latest export |
| 18 | Protected sources need visible caution | Keep readiness color on receipt | Consistent risk language |
| 19 | Single-package vs chunked exports were unclear | Add `Single package` / chunk summary | Better expectation setting |
| 20 | Very long docs need conservative defaults | Large-document mode uses lower edge/quality | Stable output size |
| 21 | Short docs deserve fidelity | High-detail mode keeps larger edge | Better visual output |
| 22 | UI must avoid giant explanatory copy | Keep details as small evidence tokens | Less AI-like layout |
| 23 | Build surface should stay narrow | Limit edits to model, DOCX service, export sheet | Lower regression scope |
| 24 | Iteration needs auditability | Document V16 and compile Debug | Closed handoff |

## Delivered

- Added typed Office visual budget modes: high detail, balanced, bounded, and
  large document.
- Added shared Office visual budget plans with edge, compression, byte budget,
  estimated visual reference pages, and chunk summary.
- Added Office export receipt model with output file, size, readiness, route
  score, budget mode, visual estimate, and timestamp.
- Refactored DOCX budget mode away from raw strings.
- Enriched DOCX custom OOXML properties with visual edge, compression percent,
  and per-page byte limit.
- Added an Office budget strip to the export sheet.
- Added inline post-export receipt without interrupting the share flow.

## Competitive Gain

- Compared with PDF Expert, PaperPath now exposes conversion resource policy
  before export.
- Compared with Acrobat, PaperPath keeps budget and receipt evidence in the
  same compact workflow.
- Compared with PDFgear, PaperPath connects pre-export route scoring to
  post-export file evidence.

## Remaining Shortfalls

- Chunking is currently advisory; future export code should create resumable
  chunked DOCX/PPTX packages for very large PDFs.
- The visual reference estimate is profile-based and does not yet count detected
  tables before export.
- The inline receipt is session-local; it should eventually persist as part of
  verified output history.
- Receipt details are shown in the app, but not yet as a full inspection panel.

## Next Precise Direction

1. Persist Office export receipts next to verified output receipts.
2. Add page-level Office preflight for table density, image anchors, OCR fallback
   pages, and estimated visual reference use.
3. Add resumable chunked export for large DOCX/PPTX conversions.
4. Add a receipt inspector that reads `docProps/custom.xml` back from generated
   DOCX files.

## Build

`xcodebuild -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build`

Result: succeeded.
