# PaperPath website deployment

The `website/` directory is a dependency-free static site. Deploy its contents
as the web root for `paperpath.monoware.app`.

Before production:

1. Connect `paperpath.monoware.app` and confirm the canonical domain. If the
   production hostname changes, update `sitemap.xml` and `robots.txt`.
2. Replace each localized "Coming soon" status with the public App Store URL
   after the listing is live.
3. Confirm `hello@monoware.app` and the MonoWare support form remain the
   published privacy contact routes.
4. The requested blog destination is `https://blog.monoware.app/`. It did not
   resolve during the 2026-09-30 build, so configure that host before launch.

Localized product and privacy pages:

- Simplified Chinese: `/` and `/privacy/`
- Traditional Chinese: `/zh-hant/` and `/zh-hant/privacy/`
- English: `/en/` and `/en/privacy/`
- Japanese: `/ja/` and `/ja/privacy/`
- Korean: `/ko/` and `/ko/privacy/`

The unprefixed routes negotiate the visitor's saved choice or browser language
before rendering. Unsupported languages fall back to English. Crawlers remain
on the canonical Simplified Chinese route so `hreflang` indexing stays stable.

Local preview:

```bash
python3 -m http.server 4173 --directory website
```
