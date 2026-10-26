# PaperPath website deployment

`website/` is the production-ready static source for `https://paperpath.monoware.app`. There is no package installation or build dependency for hosting. Deploy its public contents as the document root; do not serve `.openai/` or local QA files.

Regenerate pages: `python3 tools/BuildMarketingWebsite.py`. Validate: `python3 tools/CheckMarketingWebsite.py`. Local preview: `python3 -m http.server 4173 --directory website`.

Five languages have independent URLs: `/`, `/en/`, `/zh-hant/`, `/ja/`, `/ko/`. Each has `privacy/` and `support/`. Language links are explicit; no automatic redirects. Production canonical/hreflang, robots and sitemap use the MonoWare domain.

Owner-private Sites preview: https://paperpath-studio.aquaox32.chatgpt.site
Project identity is recorded in `.openai/hosting.json`. The deployment source lives in the ignored `.artifacts/paperpath-site/`, with the site in `dist/`; its canonical domain is rewritten to the preview origin and all pages are noindex. This preview deployment does not modify DNS or deploy the MonoWare domain.

Before public launch: verify privacy identity, policy revision and support email; deploy the production source to the intended domain; replace Coming soon with the public App Store link after availability. App Store ID: **6827073389**. Listing creation alone does not make a public listing available. Do not announce Mac support until verified.

See `docs/app-store-connect-2026-10-26/SEO_AND_LAUNCH_ZH.md` for indexing, caching and Search Console handoff.
