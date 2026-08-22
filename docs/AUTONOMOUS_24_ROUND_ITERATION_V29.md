# PaperPath V29: Office Batch Delivery

## Product Direction

V29 closes the large-document Office workflow. A PDF that exceeds a DOCX,
XLSX, or PPTX package limit no longer exits into a separate split tool. PaperPath
plans bounded segments, rebuilds them serially, retains every successful part,
and exposes one batch share command. Every new Office receipt also carries the
runtime evidence that was previously visible only inside OOXML metadata.

## Competitive Baseline

- Adobe Acrobat provides broad conversion and batch tooling, but source
  revision, retained artifact freshness, and runtime reconstruction evidence are
  not presented as one local delivery contract.
- PDF Expert keeps common exports approachable, but does not expose a
  comparable large-source Office production queue or package-level evidence.
- UPDF covers common Office targets, while failure isolation, visual-budget
  evidence, and revision-bound repeat delivery remain less explicit.
- PaperPath now combines automatic segmentation, bounded serial production,
  partial-success recovery, embedded audit metadata, app-visible runtime yield,
  and controlled local retention.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Gain |
|---|---|---|---|
| 1 | V28 ended at manual split recovery | Define direct Office batch delivery | Removes a workflow dead end |
| 2 | Competitors separate conversion from evidence | Keep route, runtime, and artifact state together | Stronger delivery contract |
| 3 | Segment boundaries were implicit | Add a revision-bound batch plan | Reproducible page scope |
| 4 | Large runs lacked granular state | Add per-segment lifecycle models | Honest progress |
| 5 | Fixed package limits caused terminal failure | Derive bounded segment targets | Predictable package sizes |
| 6 | Unlimited tiny segments would flood history | Bound plans against a 64-receipt window | Controlled metadata growth |
| 7 | Text indices used source page numbers | Rebase text indices per segment | Correct editable output |
| 8 | Parallel visual exports could spike memory | Run segment reconstruction serially | Backpressure by design |
| 9 | Temporary inputs could leak after cancellation | Protect and clean segment PDFs per iteration | Lower local residue |
| 10 | One failed segment could invalidate a run | Isolate failures per segment | Partial success survives |
| 11 | Source edits during a run were ambiguous | Check revision before and after every segment | No mixed-revision batch |
| 12 | Completed parts needed repeat delivery | Retain and verify every successful part | Immediate reshare |
| 13 | Batch completion had no unified handoff | Add one share command for all ready parts | Shorter delivery path |
| 14 | Generic progress hid current work | Show extract, rebuild, retain, and result states | Faster diagnosis |
| 15 | Large segment lists reduced scan speed | Prioritize active, failed, recent, and queued rows | Dense status without noise |
| 16 | Seven-day retention was inflexible | Add explicit pin and unpin actions | User-controlled deliverables |
| 17 | Permanent retention could become unbounded | Limit pins to four and 512 MB per source | Predictable storage |
| 18 | Stale pinned receipts could become trapped | Allow unpin after source change or expiry | Recoverable lifecycle |
| 19 | Runtime evidence existed only in OOXML | Return a shared runtime evidence model | App and file agree |
| 20 | DOCX metrics differed from XLSX/PPTX | Normalize yield, units, text, assets, and quality | Cross-format comparison |
| 21 | Receipt rows had fragmented actions | Consolidate share, inspect, and pin in one menu | Cleaner hierarchy |
| 22 | Evidence needed a dedicated drill-down | Add a dense production evidence inspector | Auditable output |
| 23 | Narrow and large text layouts could collapse | Use adaptive grids, symbols, labels, and haptics | Accessible density |
| 24 | Cross-layer changes required integration proof | Build both simulator architectures and extension | Compile stability |

## Delivered

- Automatic split-and-export batches for Office targets over their package
  limits.
- Serial extraction and reconstruction with per-segment progress, failure
  isolation, cancellation, and source-revision checks.
- One-command sharing of all retained successful parts.
- Four pinned outputs per PDF with a 512 MB pinned quota.
- Safe unpinning even after the source changes or the normal reuse window ends.
- Common runtime evidence for DOCX, XLSX, and PPTX: page yield, searchable
  coverage, primary units, characters, assets, budget use, compression
  fallbacks, and minimum quality.
- A high-density V29 evidence inspector available from current and historical
  Office receipts.
- Office Production Audit V29 embedded in generated DOCX, XLSX, and PPTX
  packages, with DOCX retaining its richer reconstruction details.

## Competitive Gain

- Versus Acrobat, PaperPath makes batch parts, current-source validity, local
  retention, and reconstruction evidence visible in one place.
- Versus PDF Expert, an oversized source becomes an executable batch instead of
  a separate manual preparation workflow.
- Versus UPDF, a failed part does not erase successful parts, and runtime yield
  remains inspectable after export.

## Remaining Shortfalls

- Batch runs are session state; segment receipts persist, but the visual run
  summary is not restored after relaunch.
- Users cannot selectively retry only failed segments yet.
- Pin quotas are per source PDF rather than a global storage policy.
- Simulator screenshots and accessibility visual regression remain deferred by
  the compile-only iteration constraint.

## Next Precise Direction

1. Persist resumable batch manifests and restore interrupted queues.
2. Add selective retry for failed or stale segments.
3. Add a global pinned-output storage manager with bulk unpin.
4. Add optional ZIP handoff for batches with deterministic file ordering.

## Build

`xcodebuild -project PaperPath.xcodeproj -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Result: succeeded for arm64 and x86_64 simulator architectures with the Share
Extension embedded. Unit tests, UI tests, screenshots, and release gates were
intentionally not run.
