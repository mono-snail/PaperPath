# PaperPath Autonomous 20-Round Iteration

Baseline tag: `autonomous-20-baseline`

## Product Direction

PaperPath should not compete with PDF Expert, Acrobat, or PDFgear by exposing
more tools. Its defensible path is a quieter local document desk:

1. Return to unfinished work immediately.
2. Find the right document and the exact matching page quickly.
3. Keep common document actions visible without turning the library into a
   toolbar.
4. Make the current page, next task, and verified output obvious in the
   workspace.
5. Preserve PaperPath's distinction: original-safe, on-device processing, and
   checked output.

The comparison target is PDF Expert's native interaction rhythm, PDFgear's
feature discoverability, Xodo's multi-document efficiency, and Smallpdf's short
task paths. PaperPath will not add cloud accounts, online AI, or shallow copies
of heavyweight editing features.

## Twenty Product Rounds

Validation, build work, tests, screenshots, and documentation do not count as
rounds.

| Round | User problem | Product delivery |
|---|---|---|
| 1 | An interrupted task is buried in the library | Compact Continue Work shelf using task checkpoints and last page |
| 2 | Pinned files do not feel pinned | Dedicated Pinned desk section |
| 3 | A long library is one undifferentiated stream | Today / Earlier document grouping |
| 4 | Users cannot choose the order that matches their job | Sort by recent edit, recent open, name, or size |
| 5 | Document rows are too tall for repeated work | Comfortable and compact density modes |
| 6 | Search mixes documents and commands without control | All / Documents / Tools search scope |
| 7 | A document match gives no evidence | Matching page number and local text excerpt |
| 8 | Row actions are hidden behind long press | Visible document overflow menu |
| 9 | Repeated library housekeeping is one-file-at-a-time | Multi-select mode with a stable selection bar |
| 10 | Selected files cannot be organized together | Bulk pin, workflow move, and private-copy removal |
| 11 | Current page position is not obvious | Page counter and direct page jump in the workspace |
| 12 | Bookmarking the current page takes a detour | One-tap current-page bookmark |
| 13 | Sharing can accidentally target the working copy | Explicit verified-share action in the workspace bar |
| 14 | The recommended next action is visually separated from work controls | Adaptive Next action in the bottom command bar |
| 15 | Repeated tools still require reopening the full palette | Most-recent tool promoted into the workspace bar |
| 16 | Recent tools are not the same as personal favorites | Persistent favorite tools in the tool palette |
| 17 | Hidden incompatible tools make capability boundaries unclear | Contextual unavailable-tool reasons |
| 18 | A verified output feels like another ordinary PDF | Result strip with receipt, change state, and share |
| 19 | Local privacy exists mostly as copy | Inspectable privacy center with precise storage boundaries |
| 20 | Home and workspace still have uneven density and hierarchy | Cross-screen typography, spacing, motion, and action-priority closeout |

## Guardrails

- Every round must change a user-visible workflow or capability.
- No automated test, validation script, metric, or documentation-only change
  may be counted as a round.
- Preserve the imported source and create explicit output copies.
- Keep PDF bytes, OCR text, and extracted content off PaperPath-managed
  networks.
- Use system fonts, semantic colors, Dynamic Type, reduced-motion behavior, and
  native iOS controls.
- Prefer visible commands and menus over explanatory feature cards.
- Do not add landing-page copy inside the working product.
