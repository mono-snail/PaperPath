#!/usr/bin/env python3
"""Build the five localized, dependency-free PaperPath marketing pages."""
import argparse
import html
import json
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ROUTES = {'zh-Hans': '', 'en': 'en', 'zh-Hant': 'zh-hant', 'ja': 'ja', 'ko': 'ko'}
NAMES = {'zh-Hans': '简体中文', 'en': 'English', 'zh-Hant': '繁體中文', 'ja': '日本語', 'ko': '한국어'}

def build(destination, origin, preview=False):
    copies = json.loads((ROOT / 'tools/marketing-copy.json').read_text())
    esc = html.escape
    origin = origin.rstrip('/')
    urls = []
    for locale, route in ROUTES.items():
        c = copies[locale]
        path = destination / route
        path.mkdir(parents=True, exist_ok=True)
        home_path = '/' + (route + '/' if route else '')
        url = origin + home_path
        prefix = '../' if route else ''
        assets = prefix + 'assets/'
        alternates = '\n'.join(f'<link rel="alternate" hreflang="{lang}" href="{origin}/{r + "/" if r else ""}{suffix}">' for lang, r in ROUTES.items() for suffix in [''])
        languages = ''.join(f'<a href="/{ROUTES[lang] + "/" if ROUTES[lang] else ""}" lang="{lang}" {"aria-current=page" if lang == locale else ""}>{name}</a>' for lang, name in NAMES.items())
        icon = lambda name: f'<svg class="icon" aria-hidden="true"><use href="{prefix}assets/launch/icons.svg#{name}"/></svg>'
        faqs = ''.join(f'<details><summary>{esc(q)}</summary><p>{esc(a)}</p></details>' for q, a in c['faq'])
        software = {'@context':'https://schema.org', '@type':'SoftwareApplication', 'name':'PaperPath PDF', 'url':url, 'image':origin+'/assets/launch/og-paperpath.png', 'applicationCategory':'UtilitiesApplication', 'operatingSystem':'iOS 17.0+, iPadOS 17.0+', 'description':c['description'], 'inLanguage':locale, 'featureList':c['featureList']}
        # Price is the approved launch plan; no purchasable Offer until the listing is live.
        faq_schema = {'@context':'https://schema.org', '@type':'FAQPage', 'mainEntity':[{'@type':'Question','name':q,'acceptedAnswer':{'@type':'Answer','text':a}} for q,a in c['faq']]}
        privacy_heading = ''.join('<span class=phrase>'+esc(part+'。')+'</span>' for part in c['privacyTitle'].split('。') if part) if locale.startswith('zh') else esc(c['privacyTitle'])
        robots = 'noindex,nofollow' if preview else 'index,follow,max-image-preview:large'
        nav = f'<a href="#workflow">{esc(c["navWorkflow"])}</a><a href="#privacy">{esc(c["navPrivacy"])}</a><a href="#price">{esc(c["navPrice"])}</a>'
        page = f'''<!doctype html>
<html lang="{locale}"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(c['title'])}</title><meta name="description" content="{esc(c['description'])}">
<meta name="robots" content="{robots}"><meta name="theme-color" content="#122b3b">
<link rel="canonical" href="{url}">{alternates}
<link rel="alternate" hreflang="x-default" href="{origin}/en/">
<link rel="icon" href="{assets}app-icon.webp" type="image/webp"><link rel="apple-touch-icon" href="{assets}apple-touch-icon.png">
<link rel="manifest" href="{prefix}site.webmanifest">
<link rel="preload" as="image" href="{assets}launch/hero-ipad.webp" fetchpriority="high">
<link rel="stylesheet" href="{prefix}launch.css?v=20261028">
<meta property="og:type" content="website"><meta property="og:site_name" content="PaperPath"><meta property="og:locale" content="{c['ogLocale']}">
<meta property="og:title" content="{esc(c['title'])}"><meta property="og:description" content="{esc(c['description'])}"><meta property="og:url" content="{url}">
<meta property="og:image" content="{origin}/assets/launch/og-paperpath.png"><meta property="og:image:width" content="1200"><meta property="og:image:height" content="630"><meta property="og:image:alt" content="{esc(c['imageAlt'])}">
<meta name="twitter:card" content="summary_large_image"><meta name="twitter:title" content="{esc(c['title'])}"><meta name="twitter:description" content="{esc(c['description'])}"><meta name="twitter:image" content="{origin}/assets/launch/og-paperpath.png">
<script type="application/ld+json">{json.dumps(software, ensure_ascii=False).replace('<', '&lt;')}</script>
<script type="application/ld+json">{json.dumps(faq_schema, ensure_ascii=False).replace('<', '&lt;')}</script>
</head><body>
<a class="skip" href="#main">{esc(c['skip'])}</a>
<header class="header"><a class="brand" href="/{route + '/' if route else ''}" aria-label="PaperPath"><img src="{assets}app-icon.webp" width="36" height="36" alt=""><span>PaperPath</span></a>
<nav class="main-nav" aria-label="{esc(c['navigation'])}">{nav}</nav><div class="header-end"><details class="language"><summary>{icon('globe')}<span>{NAMES[locale]}</span></summary><nav aria-label="{esc(c['language'])}">{languages}</nav></details><a class="header-cta" href="#price">{esc(c['navCTA'])}</a></div></header>
<main id="main">
<section class="hero" aria-labelledby="hero-title"><div class="hero-copy"><p class="platform">{icon('device')}<span>iPhone &amp; iPad</span></p>
<h1 id="hero-title">{esc(c['hero1'])}<br>{esc(c['hero2'])}</h1><p class="hero-description">{esc(c['heroDescription'])}</p>
<ul class="hero-promises"><li>{icon('local')}{esc(c['promise1'])}</li><li>{icon('device')}{esc(c['promise2'])}</li><li>{icon('check')}{esc(c['promise3'])}</li></ul>
<div class="hero-actions"><a class="button primary" href="#features">{esc(c['explore'])}{icon('arrow')}</a><a class="price-link" href="#price">US$6.99 <span>{esc(c['oneTime'])}</span></a></div>
<p class="hero-availability">{esc(c['heroAvailability'])}</p></div>
<figure class="hero-art">
<div class="tablet-frame"><img src="{assets}launch/hero-ipad.webp" width="1800" height="1350" alt="{esc(c['heroIpadAlt'])}" fetchpriority="high"></div>
<div class="phone-frame hero-phone"><img src="{assets}launch/hero-phone.webp" width="1206" height="2622" alt="{esc(c['heroPhoneAlt'])}"></div>
<figcaption>{esc(c['realScreens'])}</figcaption></figure></section>
<div class="value-strip"><p>{esc(c['strip1'])}</p><p>{esc(c['strip2'])}</p><p>{esc(c['strip3'])}</p></div>
<section class="workflow section-wrap" id="workflow"><div class="section-heading"><p class="section-tag">{esc(c['workflowTag'])}</p><h2>{esc(c['workflowTitle'])}</h2><p>{esc(c['workflowIntro'])}</p></div>
<div class="workflow-layout"><div class="workflow-stage"><div class="phone-frame workflow-phone"><img src="{assets}launch/home.webp" width="660" height="1435" alt="{esc(c['homeAlt'])}" loading="lazy"></div><div class="document-label"><span>{icon('copy')}{esc(c['original'])}</span><strong>Project handoff.pdf</strong><small>{esc(c['sourceSafe'])}</small></div></div>
<ol class="workflow-steps">{''.join(f'<li><span class="step-count">{i+1}</span><div><h3>{esc(s[0])}</h3><p>{esc(s[1])}</p><span class="step-tools">{esc(s[2])}</span></div></li>' for i,s in enumerate(c['steps']))}</ol></div></section>
<section class="privacy" id="privacy"><div class="section-wrap privacy-layout"><div class="privacy-copy"><p class="section-tag">{esc(c['privacyTag'])}</p><h2>{privacy_heading}</h2><p>{esc(c['privacyIntro'])}</p><div class="privacy-tabs" role="tablist" aria-label="{esc(c['privacySteps'])}">
{''.join(f'<button type="button" role="tab" id="tab-{i}" aria-selected="{str(i==0).lower()}" aria-controls="panel-{i}" tabindex="{0 if i==0 else -1}" data-tab="{i}">{esc(s[0])}</button>' for i,s in enumerate(c['privacyPanels']))}</div>
{''.join(f'<div role="tabpanel" id="panel-{i}" aria-labelledby="tab-{i}" class="privacy-text" {"hidden" if i else ""}><h3>{esc(s[1])}</h3><p>{esc(s[2])}</p></div>' for i,s in enumerate(c['privacyPanels']))}
<p class="boundary">{esc(c['privacyBoundary'])}</p></div><figure class="privacy-visual"><div class="phone-frame"><img id="privacy-screen" src="{assets}launch/privacy-review.webp" data-images="{assets}launch/privacy-review.webp|{assets}launch/privacy-confirm.webp|{assets}launch/verified-copy.webp" data-alts="{esc('|'.join(c['privacyAlts']))}" width="660" height="1435" alt="{esc(c['privacyAlts'][0])}" loading="lazy"></div><figcaption>{esc(c['realScreens'])}</figcaption></figure></div></section>
<section class="capabilities section-wrap" id="features"><div class="section-heading"><p class="section-tag">{esc(c['featuresTag'])}</p><h2>{esc(c['featuresTitle'])}</h2></div>
<div class="feature-list">{''.join(f'<article>{icon(s[0])}<div><h3>{esc(s[1])}</h3><p>{esc(s[2])}</p></div></article>' for s in c['features'])}</div></section>
<section class="ipad-section"><div class="section-wrap ipad-layout"><div><p class="section-tag">{esc(c['ipadTag'])}</p><h2>{esc(c['ipadTitle'])}</h2><p>{esc(c['ipadIntro'])}</p><p class="screen-note">{esc(c['ipadNote'])}</p></div><figure class="ipad-landscape"><img src="{assets}launch/ipad-dark.webp" width="1200" height="1600" alt="{esc(c['ipadDarkAlt'])}" loading="lazy"></figure></div></section>
<section class="pricing section-wrap" id="price"><div class="pricing-copy"><p class="section-tag">{esc(c['priceTag'])}</p><h2>{esc(c['priceTitle'])}</h2><p>{esc(c['priceIntro'])}</p><a class="text-link" href="support/">{esc(c['supportLink'])}{icon('arrow')}</a></div><div class="price-panel"><img src="{assets}app-icon.webp" width="64" height="64" alt=""><h3>PaperPath</h3><p class="price">US$6.99</p><p class="price-term">{esc(c['priceTerm'])}</p><ul>{''.join(f'<li>{icon("check")}{esc(s)}</li>' for s in c['priceIncludes'])}</ul><p class="launch-status">{esc(c['comingSoon'])}</p><p class="price-note">{esc(c['priceNote'])}</p></div></section>
<section class="faq section-wrap" id="faq"><h2>{esc(c['faqTitle'])}</h2><div>{faqs}</div></section>
<section class="closing"><div class="section-wrap"><p>{esc(c['closing'])}</p><a class="button light" href="#price">{esc(c['closingCTA'])}{icon('arrow')}</a></div></section>
</main><footer class="footer section-wrap"><a class="brand" href="/{route + '/' if route else ''}"><img src="{assets}app-icon.webp" width="30" height="30" alt=""><span>PaperPath</span></a><nav aria-label="{esc(c['footerNav'])}"><a href="privacy/">{esc(c['privacyLink'])}</a><a href="support/">{esc(c['supportLink'])}</a><a href="https://www.monoware.app/" target="_blank" rel="noopener noreferrer">MonoWare</a></nav><p>© 2026 MonoWare</p></footer>
<noscript><style>.privacy-text[hidden]{{display:block!important}}.privacy-tabs{{display:none}}</style></noscript><script src="{prefix}launch.js?v=20261026" defer></script></body></html>'''
        (path / 'index.html').write_text(page)
        support = path / 'support'
        support.mkdir(exist_ok=True)
        support_url = url + 'support/'
        support_alternates = '\n'.join(f'<link rel="alternate" hreflang="{lang}" href="{origin}/{r + "/" if r else ""}support/">' for lang,r in ROUTES.items())
        support_html = f'''<!doctype html><html lang="{locale}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{esc(c['supportLink'])} — PaperPath PDF</title><meta name="description" content="{esc(c['supportIntro'])}"><meta name="robots" content="{robots}"><link rel="canonical" href="{support_url}">{support_alternates}<link rel="alternate" hreflang="x-default" href="{origin}/en/support/"><link rel="icon" href="{origin}/assets/app-icon.webp"><link rel="stylesheet" href="{prefix}../launch.css?v=20261028"></head><body><header class="header"><a class="brand" href="{home_path}">PaperPath</a><a href="{home_path}">{esc(c['back'])}</a></header><main class="support-page section-wrap"><h1>{esc(c['supportLink'])}</h1><p>{esc(c['supportIntro'])}</p><p><a class="button primary" href="mailto:hello@monoware.app">hello@monoware.app</a></p><p>{esc(c['contactNote'])}</p><div class="support-answers">{''.join(f'<section><h2>{esc(q)}</h2><p>{esc(a)}</p></section>' for q,a in c['support'])}</div><a href="../privacy/">{esc(c['privacyLink'])}</a></main></body></html>'''
        (support / 'index.html').write_text(support_html)
        urls.extend([url, support_url, url+'privacy/'])
    ET.register_namespace('', 'http://www.sitemaps.org/schemas/sitemap/0.9')
    ET.register_namespace('xhtml','http://www.w3.org/1999/xhtml')
    ns='{http://www.sitemaps.org/schemas/sitemap/0.9}'
    sitemap=ET.Element(ns+'urlset')
    for url in urls:
        item=ET.SubElement(sitemap,ns+'url');ET.SubElement(item,ns+'loc').text=url
        ET.SubElement(item,ns+'lastmod').text='2026-10-28'
        kind = 'support/' if url.endswith('support/') else 'privacy/' if url.endswith('privacy/') else ''
        for lang, route in [*ROUTES.items(), ('x-default','en')]:
            ET.SubElement(item,'{http://www.w3.org/1999/xhtml}link',{'rel':'alternate','hreflang':lang,'href':origin+'/'+(route+'/' if route else '')+kind})
    ET.indent(sitemap)
    ET.ElementTree(sitemap).write(destination/'sitemap.xml',encoding='utf-8',xml_declaration=True)
    (destination/'robots.txt').write_text('User-agent: *\n'+('Disallow: /\n' if preview else f'Allow: /\n\nSitemap: {origin}/sitemap.xml\n'))
    print(f'Built {len(ROUTES)} homepages, 5 support pages and sitemap at {destination}; origin={origin}; preview={preview}')

if __name__ == '__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,default=ROOT/'website');parser.add_argument('--origin',default='https://paperpath.monoware.app');parser.add_argument('--preview',action='store_true')
    args=parser.parse_args();build(args.output,args.origin,args.preview)
