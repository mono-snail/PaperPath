# PDF workflow iteration evidence

Real iOS Simulator renders:

- `before.png`: current workspace before this iteration, iPhone.
- `home-first-pass.png`: first implementation; wrapping labels and recommendation block prompted refinement.
- `iphone-final.png`: final implemented iPhone home after refinement.
- `ipad-light.png`: implemented compact four-action home with document preview.
- `ipad-dark-large-zh.png`: implemented Chinese, dark appearance, maximum accessibility text size.
- `ipad-empty.png`: implemented empty library with import, scan and four workflow entries.
- `split-picker.png`: real split workflow document picker.
- `merge-dragged-order.png`: passing XCTest screenshot after moving August invoice ahead of Project handoff by dragging.

`layout-proposal.png` is a generated design proposal, not an app screenshot. `image-prompt.txt` records the built-in imagegen brief and reference. The app uses native controls, not generated UI pixels.

The detailed audit and verification record is in `docs/MARKET_ITERATION_2026_10_26_ZH.md`.
`validation.txt` records the seven passing selected regression cases. This is not a full-suite or physical-device release certification.
