# PaperPath V20: Office Export Decision Desk

## Product Direction

V20 focuses on function experience and UI details. Earlier Office iterations
added route scoring, budget pressure, visual anchors, and stability evidence.
V20 makes that evidence actionable: the Office export sheet now presents a
recommended route, emphasizes the best format, provides fallback actions, and
adds lightweight selection/success feedback.

## Competitive Baseline

- PDF Expert exposes common export choices, but the user still has to infer the
  best Office target.
- Adobe Acrobat has powerful conversion controls, but recommendation and
  evidence are not presented as one compact decision surface.
- PDFgear offers broad format coverage, but fallback guidance between DOCX,
  XLSX, and PPTX remains thin.
- PaperPath's advantage is a high-density local decision desk: route, score,
  budget, anchor, fallback, and receipt evidence are available in one workflow.

## 24 Product Rounds

| Round | Diagnosis | Implemented Direction | Intended Gain |
|---|---|---|---|
| 1 | Office evidence was strong but not action-led | Add recommended route line | Faster first decision |
| 2 | Best format was only visible in metrics | Add decision line with format, role, score | Clear recommendation |
| 3 | Secondary option was hidden | Add second-choice fallback mention | Better recovery path |
| 4 | Risk copy was scattered | Add portfolio caution line | One compact warning |
| 5 | Buttons looked equal even when scores differed | Add recommended row emphasis | Better visual hierarchy |
| 6 | Format roles were implicit | Add decision roles per format | Faster scanning |
| 7 | Scores were spread across bars and copy | Add compact E/A/S evidence | Better dense comparison |
| 8 | CTA language was generic | Add readiness-based action title | More honest execution |
| 9 | Weak routes lacked next step | Add fallback action button | Less dead-end behavior |
| 10 | Fallback could have nested interaction risk | Keep fallback as separate button | Stable SwiftUI behavior |
| 11 | Selection had no tactile response | Add selection haptic trigger | Better perceived control |
| 12 | Success had no tactile response | Add success haptic trigger | Stronger completion feedback |
| 13 | Receipt icon was static | Add bounce symbol effect | More visible completion |
| 14 | UI needed density, not new pages | Use compact strips and row tokens | No workflow expansion |
| 15 | Recommended state needed visible marker | Add BEST label | Faster glance recognition |
| 16 | Row tint was too generic | Tint by readiness | Status is visible earlier |
| 17 | Recommended row needed subtle depth | Add small inline background and rail | Less flat list feel |
| 18 | Accessibility needed action context | Keep export hint on format rows | Screen-reader clarity |
| 19 | Button copy should not overpromise | Use Export / Export with review / Export limited | Better trust |
| 20 | Decision surface should stay local | No network, no cloud, no source mutation | Privacy continuity |
| 21 | UI should match dense command style | Avoid large cards and hero copy | Less generic UI |
| 22 | Model/View logic should stay separated | Put decision helpers in models | Cleaner maintenance |
| 23 | Scope should remain narrow | Touch only Office model and export sheet | Lower regression risk |
| 24 | Iteration needs closure | Document V20 and compile Debug | Auditable handoff |

## Delivered

- Added `decisionRole`, `compactEvidence`, and `actionTitle` to Office format
  plans.
- Added `secondChoicePlan`, `decisionLine`, and `cautionLine` to the Office
  portfolio.
- Added a compact recommended route strip before the route matrix.
- Redesigned Office format rows with readiness tint, BEST marker, action title,
  compact role/evidence, and recommended rail.
- Added fallback action rows for weak route decisions.
- Added selection haptic feedback for Office route actions.
- Added success haptic feedback and receipt symbol bounce after export.

## Competitive Gain

- Compared with PDF Expert, PaperPath no longer leaves the user to infer the
  best Office format.
- Compared with Acrobat, PaperPath combines recommendation and evidence in the
  normal export path without a separate advanced dialog.
- Compared with PDFgear, PaperPath gives format-level fallback actions instead
  of only listing formats.

## Remaining Shortfalls

- Recommended route is still score-based; it should later include actual
  page-level table/image/fallback preflight.
- Fallback actions are immediate exports; a future version can preview the
  tradeoff before starting.
- Receipt history is still session-local and should be persisted.
- PPTX and XLSX outputs should receive their own post-export detail receipts.

## Next Precise Direction

1. Add page-level Office preflight to improve route recommendation quality.
2. Persist Office receipts in verified output history.
3. Add a compact pre-export tradeoff preview for fallback choices.
4. Extend post-export receipts with format-specific diagnostics.

## Build

`xcodebuild -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build`

Result: succeeded.
