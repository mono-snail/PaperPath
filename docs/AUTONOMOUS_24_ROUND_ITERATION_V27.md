# PaperPath V27: Cross-Format Office Audit and Recovery Flow

## Product Direction

V27 closes the evidence gap between Word, Excel, and PowerPoint export. Office
conversion is now one local production system: the route model, package
boundary, runtime output evidence, file metadata, progress, and recovery actions
remain consistent across all three OOXML formats.

## Competitive Baseline

- Adobe Acrobat offers broad conversion, but route evidence and actual runtime
  output metrics are not carried as one compact decision contract.
- PDF Expert is fast and polished, but Office export does not expose a
  cross-format, file-embedded local audit.
- UPDF exposes common format actions, but large-document limits and recovery
  paths are still more reactive than operational.
- PaperPath V27 differentiates through on-device evidence continuity: every
  Office package carries the route, preflight, privacy boundary, output yield,
  and format-specific runtime facts that created it.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Intended Gain |
|---|---|---|---|
| 1 | V26 evidence parity stopped at DOCX | Audit all three OOXML writers | One product promise |
| 2 | Format state was app-only | Define a shared embedded audit schema | Evidence travels with files |
| 3 | Runtime output was not comparable | Add source/output page yield | Honest conversion scope |
| 4 | Recovery was mostly advisory | Add tool targets to recovery actions | Shorter corrective path |
| 5 | XLSX had no execution evidence | Record sheets, cells, characters, and searchable pages | Inspectable workbook rebuild |
| 6 | PPTX had no execution evidence | Record slides, searchable pages, assets, and rendered bytes | Inspectable visual rebuild |
| 7 | Route scores could diverge at export | Pass the same document profile to every writer | Stable decisions |
| 8 | Shared audit needed a compact contract | Embed route, rank, confidence, SLA, preflight, and privacy | Cross-format parity |
| 9 | XLSX package omitted custom properties | Add `docProps/custom.xml` and relationship | Workbook evidence persistence |
| 10 | PPTX package omitted custom properties | Add `docProps/custom.xml` and relationship | Presentation evidence persistence |
| 11 | Package validation accepted partial audits | Require custom properties for every OOXML profile | Stronger package integrity |
| 12 | PPTX page rendering could spike memory | Wrap each JPEG render in `autoreleasepool` | Lower long-run memory pressure |
| 13 | Audit parity was invisible before export | Add 3/3 file-audit metric | Immediate trust signal |
| 14 | Output limits were buried in service errors | Add page boundary contract | Fewer failed attempts |
| 15 | Format cards lacked delivery evidence | Show embedded audit and hard limits inline | Faster comparison |
| 16 | Recovery actions opened notices | Route OCR and Split directly to their tools | Executable workflow |
| 17 | Recommendation ignored hard format limits | Make limits part of readiness and ranking | No impossible best route |
| 18 | Large sources failed after waiting | Convert over-limit actions to Split First | Fail before work starts |
| 19 | Export progress was generic | Add Analyze, Rebuild, Package, Verify stages | Clear production state |
| 20 | Failed export lost route context | Add inline retry and split recovery | Resume without re-deciding |
| 21 | Failure feedback was only textual | Add error haptic and stable warning rail | Faster state recognition |
| 22 | Dense controls needed narrow-screen resilience | Use short labels, stable dimensions, and adaptive rows | Better iPhone fit |
| 23 | New flow needed compile repair | Fix opaque-return inference and rebuild | Compile stability |
| 24 | Iteration needed a durable audit trail | Add V27 product and technical record | Clear handoff |

## Delivered

- Added a shared V27 Office Route Audit schema for DOCX, XLSX, and PPTX.
- Embedded actual XLSX workbook yield and PPTX searchable/rendered asset facts.
- Made `docProps/custom.xml` mandatory in OOXML package validation.
- Added format limits to route readiness, ranking, buttons, and recovery.
- Added a compact output contract with file audit, preflight, pages, and local
  privacy boundary.
- Added four-stage Office progress plus inline retry and split recovery.
- Added direct Split PDF and OCR routing instead of passive notices.
- Added Simplified Chinese strings for the new production states.

## Competitive Gain

- Compared with Acrobat, PaperPath carries route and runtime evidence inside all
  three Office file types, not only in the conversion UI.
- Compared with PDF Expert, PaperPath exposes the local privacy boundary and
  actual output scope before and after export.
- Compared with UPDF, PaperPath prevents known over-limit runs and turns
  large-document recovery into a direct split workflow.

## Remaining Shortfalls

- Office receipt history stores audit facts but not reusable exported file
  handles.
- Split recovery opens the existing split tool; automatic segment generation
  is not yet bundled into one batch Office job.
- DOCX has deeper page-anchor telemetry than XLSX and PPTX because those formats
  use different reconstruction strategies.
- Narrow iPhone and accessibility-size screenshot review remains intentionally
  deferred.

## Next Precise Direction

1. Add batch Office export from automatically generated page segments.
2. Persist reusable exported-file handles with expiry and source-revision checks.
3. Add page-level anchor drilldown for DOCX and slide-level image budget evidence
   for PPTX.
4. Add simulator screenshot review for narrow iPhone and accessibility sizes.

## Build

`xcodebuild -project PaperPath.xcodeproj -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Result: succeeded. Unit tests, UI tests, and release gates were intentionally
not run for this iteration.
