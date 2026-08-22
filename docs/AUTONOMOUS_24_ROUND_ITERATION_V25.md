# PaperPath V25: Office Command Center and Runtime Route Audit

## Product Direction

V25 turns PDF to Office from a list of export buttons into a compact production
command center. V24 preserved preflight evidence inside DOCX metadata; V25 makes
the route decision operational before, during, and after export with confidence,
SLA, budget pressure, recovery actions, and actual DOCX runtime audit fields.

## Competitive Baseline

- Adobe Acrobat has strong conversion breadth, but most users still need to
  infer why Word, Excel, or PowerPoint is the safer route.
- PDF Expert is fast and polished, but Office export usually reads as a simple
  action instead of a route decision with recovery guidance.
- UPDF exposes common conversion targets, but production budget, confidence, and
  post-export evidence are not surfaced as a dense local audit.
- PaperPath's V25 edge is decision continuity: recommendation, risk, recovery,
  progress, receipt, history, and DOCX metadata now share one route model.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Intended Gain |
|---|---|---|---|
| 1 | Office export still felt like a format picker | Add route confidence model | Faster decision trust |
| 2 | Users lacked export-time expectation | Add production SLA tiers | Clear run expectations |
| 3 | Risks were visible but not actionable | Add recovery action matrix | Fewer dead ends |
| 4 | Receipts had score but weak gate summary | Add quality gate fields | Better post-export review |
| 5 | Budget plan was mostly static | Add budget use and contract summaries | More precise risk language |
| 6 | Long mixed documents could be under-warned | Tighten budget pressure thresholds | Safer large-doc behavior |
| 7 | Low text coverage needed stronger reserves | Add mixed-structure visual estimate | Better scan handling |
| 8 | Very large documents needed reserve logic | Add long-document visual reserve | Lower memory surprise |
| 9 | UI information was fragmented | Add Office Command Center | One first-screen decision desk |
| 10 | Route, SLA, and confidence were separate | Merge into header metrics | Higher density |
| 11 | Primary risk lacked prominence | Add risk ledger | Faster issue diagnosis |
| 12 | Next action was implicit | Add next-best-action rail | Shorter recovery path |
| 13 | OCR recovery needed direct routing | Route OCR action back to current document | Better flow continuity |
| 14 | Format fallback was passive | Make target-format recovery actions executable | Faster alternate export |
| 15 | Export progress was generic | Add Office-specific progress panel | Better perceived control |
| 16 | Receipt evidence was scattered | Add confidence and quality gate to receipt | Better audit density |
| 17 | History rows were hard to compare | Add confidence and budget contract to history | Faster output comparison |
| 18 | DOCX runtime audit lacked coverage ratios | Add page yield and structure coverage | Stronger evidence |
| 19 | Visual anchor success was implicit | Add anchor hit percent | Better visual budget audit |
| 20 | Budget use was only configured, not actual | Add runtime budget use | Better performance proof |
| 21 | Skip reasons were split across counters | Add skip reason summary | Faster triage |
| 22 | Quality degradation needed a digest | Add fallback quality summary | Clear downgrade evidence |
| 23 | Metadata should carry route model | Embed confidence, SLA, rank, budget contract | Evidence survives sharing |
| 24 | Iteration needs closure | Document V25 and compile Debug | Auditable handoff |

## Delivered

- Added `PDFOfficeRouteConfidence`, `PDFOfficeProductionSLA`, and
  `PDFOfficeRecoveryAction`.
- Extended `PDFOfficeVisualBudgetPlan` with estimated visual bytes, budget use,
  pressure contract, and memory guard summaries.
- Extended `PDFOfficeExportPortfolio` with route confidence, SLA, route rank,
  primary risk, decision deck line, and next-best actions.
- Tightened visual budget pressure thresholds and added mixed-structure plus
  long-document visual reserves.
- Replaced the top of the Editable Office section with a dense Office Command
  Center.
- Added route ledger, risk ledger, and executable recovery action rail.
- Added Office-specific export progress with route, confidence, and budget
  context.
- Upgraded immediate and historical Office receipt rows with quality gate,
  confidence, budget contract, and evidence summaries.
- Added DOCX runtime metrics for structured page count, page yield,
  structured coverage, visual anchor hit rate, actual budget use, skip reasons,
  and quality fallbacks.
- Embedded V25 route audit properties in DOCX `docProps/custom.xml`.

## Competitive Gain

- Compared with Acrobat, PaperPath makes the route decision inspectable before
  the user commits to a format.
- Compared with PDF Expert, PaperPath does not stop at a fast export; it shows
  confidence, risk, and fallback actions in the same workflow.
- Compared with UPDF, PaperPath carries production evidence into the exported
  DOCX file instead of leaving it only inside the app UI.

## Remaining Shortfalls

- XLSX and PPTX still do not embed the full V25 custom-property audit set.
- Office receipt history still stores metadata, not reusable exported file
  handles.
- Recovery actions do not yet include automatic split-before-export for very
  large documents.
- Command Center has compile coverage but still needs screenshot review on
  small devices and accessibility text-size passes.

## Next Precise Direction

1. Add V25 custom-property parity to XLSX and PPTX exports.
2. Add an Office lane to Verified Output history.
3. Add automatic split-before-export for constrained long documents.
4. Add page-level evidence drilldown for visual anchors and table fallbacks.

## Build

`xcodebuild -project PaperPath.xcodeproj -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build`

Result: succeeded.
