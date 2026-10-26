# PaperPath launch compositions

12 App Store PNGs: 4 iPhone and 2 iPad images for each of en-US and zh-Hans. iPhone: 1206 × 2622; iPad: 2064 × 2752. Social preview: 1200 × 630.

These are marketing compositions using whole actual app screenshots, embedded without editing UI pixels. No synthetic UI, pricing text, free trial or subscription claims appear in the App Store images. Examples use fictional documents. Navy, ocean, paper and mint match the app direction.

## Release gates

- All screenshots currently show English app UI, including the zh-Hans compositions. Recapture actual Simplified Chinese UI and rerun with updated sources before submitting the Chinese localization. Do not translate text inside screenshots by image retouching.
- Privacy, verified-copy and OCR sources were captured on 2026-09-27. Recapture the final release build so App Store images exactly reflect the shipping version.
- iPad screenshots include the simulator's Chinese system date; use the final intended locale and a consistent status bar for release capture.
- Confirm the target device slot accepts these exact portrait dimensions in App Store Connect before upload.
- Marketing language describes the visible workflows; verified redaction still requires the release team's functional validation.

## Reproduce

Run the bundled Node binary against tools/GenerateMarketingAssets.mjs from any directory. macOS Arial, Georgia and PingFang fonts are used. See manifest.json for source paths, SHA-256 hashes, output dimensions and locale.

Preview: contact-sheet.jpg.
