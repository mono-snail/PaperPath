# PaperPath launch materials · 2026-10-26

## Implemented website

The actual implementation is `website/`, with five static localized homepages, five support pages and five retained privacy pages. The final hero foregrounds offline PDF tools, no document uploads and no subscription; originals and checked sharing are explained in the workflow. US$9.99 is the planned one-time paid-download price; launch availability and Mac support are not claimed.

Visual system: ink `#122b3b`, ocean `#00658b`, paper `#f7f6f3`, mint `#a7ddc7`, white `#ffffff`. The app wordmark uses Georgia; controls and body use the platform sans-serif stack. Chinese headlines use the native system sans-serif for legibility. The large document workspace carries the visual focus; supporting sections alternate a workflow, interactive privacy review, a concise capability list, iPad workspace and pricing.

`homepage-direction.png` is an Image Tool concept, not an implemented screen. The implementation uses intact actual app screenshots and HTML/CSS device frames. It does not use generated interface pixels. The decorative paper sheet is an illustrative document, separate from the real app screens.

## Assets

- `store-assets/`: 12 App Store screenshot compositions and one 1200×630 social preview, with a source/hash manifest and contact sheet.
- `website-actual-desktop.png`: actual full desktop browser capture.
- Other `website-*.png`: actual browser captures. Desktop and alternate-width captures show a scaled iframe whose layout viewport is 1440, 768, 390 or 320 pixels; these are browser-rendered pages, not image proposals. The surrounding diagnostic view is intentionally retained.
- Built-in Image Tool was used for direction exploration. Prompt: `image-direction-prompt.txt`.

## Verification

- `python3 tools/BuildMarketingWebsite.py` reproduces static localized HTML and sitemap.
- `python3 tools/CheckMarketingWebsite.py` checks 15 pages, local links/assets, absolute canonical and reciprocal language links, JSON-LD, sitemap and paid-download copy. It also checks English/Chinese Connect field lengths.
- Browser layout checks: 1440px Chinese/English desktop, 768px Japanese, 390px Chinese, 320px English. Reported document width matched each viewport; no broken loaded images.
- Privacy tabs verified by click and arrow-key navigation, with actual matching screenshot changes. Native FAQ and language disclosure controls retain keyboard behavior.
- The site uses no remote font, analytics, cookie tracking or third-party JS. Core marketing content is static HTML. Reduced-motion is supported; the product figures have fixed dimensions to limit layout shift.

## Remaining release work

Store images are prepared marketing drafts. Chinese headings currently surround English app UI; recapture the Chinese locale from the final shipping build. Older privacy/OCR screens also need final-build recapture. The primary checkout is still running a separate release audit. The user subsequently requested a paid build upload: paid-download migration, signed archive and regression evidence are isolated in `/Users/yanjun/.codex/worktrees/paperpath-paid-launch/PaperPath`. Consult its paid-release report for upload status.

SEO metadata describes the app but does not invent ratings or a purchasable Offer. An app rich result is not promised. The public domain still needs deployment/verification and Search Console ownership; a private preview cannot be indexed. The public App Store URL is pending, so the site clearly says Coming soon rather than linking a fake download button.
