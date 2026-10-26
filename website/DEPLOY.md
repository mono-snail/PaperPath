# PaperPath website deployment

Official public site: https://paperpath.monoware.app (English: https://paperpath.monoware.app/en/).

The production website now has an independent private GitHub repository: https://github.com/mono-snail/paperpath-website. Its local checkout is ../PaperPathWebsite. Future website changes must be made there; this App repository retains the website snapshot for historical reference.

Cloudflare Pages project paperpath-website deploys the independent repository main branch automatically. Build command: python3 tools/BuildCloudflareSite.py; output: dist. The custom domain and TLS validation are active. Initial production source: website-v1.0.0 (4904620). Do not deploy the private Sites preview as production or reintroduce noindex into the official site.

The production build validates all 15 localized home/privacy/support pages. See the website repository docs/DEPLOYMENT_2026_10_26.md for deployment evidence, the live-check network limitation, and remaining Search Console verification/submission. The App Store listing and launch price remain planned until public availability.
