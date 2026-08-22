# PaperPath V24: DOCX Embedded Preflight Evidence

## Product Direction

V24 embeds Office preflight evidence directly into generated DOCX files. V21
made preflight visible before export, V22 kept it in the immediate receipt, and
V23 persisted recent receipt history per document. V24 carries the same local
route and risk evidence into `docProps/custom.xml`, so the Word file remains
auditable after it leaves PaperPath.

## Competitive Baseline

- PDF Expert offers fast Word export, but exported files rarely preserve a
  readable local decision trail explaining conversion risks.
- Adobe Acrobat can produce high-quality Office files, but route rationale is
  usually opaque to the user once the file is shared.
- PDFgear exposes common conversion targets, but completion evidence is not
  embedded as structured Office metadata.
- PaperPath's advantage is evidence continuity: recommendation, preflight,
  receipt, local history, and DOCX metadata now use the same route model.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Intended Gain |
|---|---|---|---|
| 1 | DOCX custom properties lacked preflight | Add Office preflight properties | Exported file remains explainable |
| 2 | DOCX route needed source context | Pass `DocumentProfile` into export pipeline | Accurate evidence |
| 3 | Existing calls needed compatibility | Add optional profile parameter | Low migration risk |
| 4 | App route and file route could diverge | Use `PDFOfficeExportPortfolio` in DOCX service | One evidence source |
| 5 | Non-App calls still need metadata | Add fallback profile | Robust service behavior |
| 6 | Word score should be inspectable | Embed DOCX score | Route quality visible |
| 7 | Readiness should be inspectable | Embed DOCX readiness | Clear risk state |
| 8 | Summary needed a compact field | Embed preflight summary | Fast metadata scan |
| 9 | Four signals needed persistence | Embed rights/structure/visual/package | Complete preflight trail |
| 10 | Main risk should not be hidden | Embed lead risk | Faster issue diagnosis |
| 11 | Budget plan should travel with file | Embed anchor, pressure, chunk plan | Reproducible export context |
| 12 | Privacy provenance should remain explicit | Keep on-device privacy property | Trust continuity |
| 13 | Existing visual metrics should remain | Preserve prior V16-V19 custom fields | No regression |
| 14 | UI should state metadata outcome | Add Evidence token to receipt | Honest user feedback |
| 15 | History should show evidence type | Add Evidence token to history rows | Better comparison |
| 16 | Accessibility should include evidence type | Update receipt labels | Better VoiceOver output |
| 17 | Avoid overclaiming XLSX/PPTX | Mark only DOCX as `DOCX meta` | Accurate scope |
| 18 | Keep file compatibility | Use standard custom document properties | Word-safe integration |
| 19 | Avoid content leakage | Store metrics, not PDF text | Privacy-safe metadata |
| 20 | Avoid UI bloat | Add one compact metric token | High density |
| 21 | Performance should remain stable | No extra page rendering | Cheap export path |
| 22 | Commercial value should be visible | Evidence survives sharing | Stronger pro workflow |
| 23 | Scope should stay narrow | Touch export pipeline, receipt UI, docs | Lower blast radius |
| 24 | Iteration needs closure | Document V24 and compile Debug | Auditable handoff |

## Delivered

- Added optional `DocumentProfile` propagation from `PaperPathModel` to
  `PDFOutputService.exportText`.
- Added optional profile support to `DOCXExportService.export`.
- Built `PDFOfficeExportPortfolio` inside DOCX export from the passed profile.
- Added fallback profile generation for service-level use.
- Embedded Office route, DOCX score, readiness, preflight summary, preflight
  digest, lead risk, rights, structure, visual, package, anchor policy, budget
  pressure, and chunk plan into DOCX custom properties.
- Added receipt computed evidence status: `DOCX meta` for Word, `App receipt`
  for other formats.
- Added compact Evidence tokens to immediate Office receipt and recent history
  rows.
- Updated receipt accessibility labels with evidence type.

## Competitive Gain

- Compared with PDF Expert, PaperPath's exported DOCX carries the conversion
  reasoning rather than only the converted content.
- Compared with Acrobat, PaperPath exposes a readable decision trail without
  forcing users into advanced conversion diagnostics.
- Compared with PDFgear, PaperPath preserves route and risk evidence inside the
  shared Office file itself.

## Remaining Shortfalls

- XLSX and PPTX do not yet embed matching preflight custom properties.
- DOCX metadata stores signal summaries, not a full page-level Office analysis
  cache.
- Recent receipt history does not yet open or manage previously exported files.
- The Verified Output history screen still needs a dedicated Office receipt lane.

## Next Precise Direction

1. Add custom property metadata parity to XLSX and PPTX exports.
2. Add page-level Office analysis cache for real table/image/fallback evidence.
3. Add an Office lane to Verified Output history.
4. Add format-specific receipt diagnostics for spreadsheets and slides.

## Build

`xcodebuild -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build`

Result: succeeded.
