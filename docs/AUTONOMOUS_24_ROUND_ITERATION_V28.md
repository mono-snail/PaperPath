# PaperPath V28: Reusable Office Production

## Product Direction

V28 turns Office conversion from a one-shot export screen into a bounded local
production workflow. The recommended route is directly executable, progress and
failures expose operational state, and a verified output can be shared again for
seven days while it still matches the current PDF revision.

## Competitive Baseline

- Adobe Acrobat has broad conversion coverage, but retained outputs and route
  evidence are not presented as one source-revision contract.
- PDF Expert keeps export simple, but exposes less reconstruction evidence and
  fewer actionable recovery states.
- UPDF provides many target formats, but large visual exports remain closer to
  a generic conversion task than a visible memory-budgeted production run.
- PaperPath now combines local reconstruction, file-embedded audit, bounded
  visual memory, revision-aware reuse, and explicit recovery in one workflow.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Gain |
|---|---|---|---|
| 1 | V27 ended at one-shot sharing | Define reusable Office production | Fewer repeated conversions |
| 2 | Office and portable text shared state | Add explicit Office format identity | Clean histories |
| 3 | Static progress thresholds leaked implementation | Add semantic production stages | Clearer status |
| 4 | Failures were generic | Classify rights, OCR, storage, limits, revision, and verification | Actionable recovery |
| 5 | Retrying stale output was ambiguous | Bind every retained output to source revision | No stale sharing |
| 6 | Permanent retention would inflate storage | Set a seven-day reuse window | Bounded footprint |
| 7 | Temporary exports vanished after sharing | Add protected local Office cache | Fast repeat delivery |
| 8 | Cache files could outlive records | Prune expired, stale, orphaned, and deleted artifacts | Lifecycle integrity |
| 9 | Cache use was invisible | Add Office output storage accounting | Honest local footprint |
| 10 | Retained files could be damaged | Verify type and byte count before reuse | Safer sharing |
| 11 | PPTX retained up to 180 MB of images | Cap visual assets at 72 MB | Lower peak memory |
| 12 | PPTX quality was fixed | Add five-step resolution and quality fallback | Predictable long runs |
| 13 | Early slides could consume the budget | Reserve a fair share for remaining slides | Backpressure |
| 14 | Compression decisions were hidden | Embed budget use, fallback count, and minimum quality | Portable evidence |
| 15 | V27 audit name no longer described behavior | Advance to Office Production Audit V28 | Clear schema |
| 16 | Recommendation still required scanning cards | Add a primary recommended-route command | Shorter path |
| 17 | E/A/S appeared twice | Remove the duplicate route matrix | Higher signal density |
| 18 | Recovery rail repeated the primary export | Keep it for corrective actions only | Cleaner hierarchy |
| 19 | Progress symbols were generic circles | Give every production stage a stable symbol | Faster scanning |
| 20 | Failure feedback lacked source assurance | Show source unchanged and page scope | Safer retry decisions |
| 21 | Receipt history was passive | Add direct reshare controls | One-tap repeat delivery |
| 22 | Stale and expired receipts looked active | Add reusable, changed, expired, and receipt-only states | Honest availability |
| 23 | New states needed localized UI | Add Simplified Chinese production strings | Consistent experience |
| 24 | Cross-layer changes needed integration proof | Build both simulator architectures and extension | Compile stability |

## Delivered

- Seven-day, source-revision-bound local retention for DOCX, XLSX, and PPTX.
- Direct repeat sharing from the current receipt and recent Office history.
- Automatic cleanup for expired, stale, orphaned, and deleted output files.
- Storage settings now show reusable Office output usage.
- A 72 MB PPTX visual budget with fair-share backpressure and five fallback
  levels.
- V28 embedded runtime audit for asset budget use, compression fallbacks, and
  minimum accepted quality.
- A single recommended export command, semantic stages, and classified recovery.
- Portable text exports no longer create Office receipts.

## Competitive Gain

- Versus Acrobat, PaperPath makes output freshness explicit through source
  revision binding and carries production evidence inside the Office file.
- Versus PDF Expert, repeat delivery does not require rebuilding while the
  retained file remains current.
- Versus UPDF, PPTX generation has a visible, enforced memory and quality
  contract instead of only a terminal file-size failure.

## Remaining Shortfalls

- Large sources still route to the existing split tool instead of producing and
  exporting all segments as one queued batch.
- Retained outputs expire by policy; users cannot pin selected deliverables yet.
- DOCX, XLSX, and PPTX runtime evidence is format-specific rather than exposed
  in one post-export drill-down screen.
- Narrow-device and accessibility-size screenshot review remains deferred by
  the compile-only iteration constraint.

## Next Precise Direction

1. Add automatic split-and-export batches with per-segment receipts.
2. Add explicit pinning for selected retained outputs with storage quotas.
3. Add a post-export evidence inspector for package parts and runtime yield.
4. Add simulator visual regression for narrow iPhone and accessibility sizes.

## Build

`xcodebuild -project PaperPath.xcodeproj -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Result: succeeded. Unit tests, UI tests, screenshots, and release gates were
intentionally not run.
