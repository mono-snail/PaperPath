#!/usr/bin/env python3
"""Check production-candidate SEO consistency, without claiming live indexing."""
import argparse
import json
import re
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ROUTES = {'zh-Hans': '', 'en': 'en', 'zh-Hant': 'zh-hant', 'ja': 'ja', 'ko': 'ko'}


def normalized(text):
    return re.sub(r'\s+', ' ', text).strip()


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__()
        self.tags, self.visible, self.schemas = [], [], []
        self.in_title = self.in_body = self.json_script = False
        self.script = self.style = False
        self.title, self.buffer = '', ''
        self.feed(path.read_text())

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        self.tags.append((tag, a))
        if tag == 'title': self.in_title = True
        if tag == 'body': self.in_body = True
        if tag == 'script':
            self.script = True
            self.json_script = a.get('type') == 'application/ld+json'
            self.buffer = ''
        if tag == 'style': self.style = True

    def handle_endtag(self, tag):
        if tag == 'title': self.in_title = False
        if tag == 'body': self.in_body = False
        if tag == 'style': self.style = False
        if tag == 'script':
            if self.json_script: self.schemas.append(json.loads(self.buffer))
            self.script = self.json_script = False

    def handle_data(self, data):
        if self.in_title: self.title += data
        if self.json_script: self.buffer += data
        if self.in_body and not self.script and not self.style: self.visible.append(data)


def check(web, origin):
    errors, canonicals, titles = [], set(), set()
    for lang, route in ROUTES.items():
        for kind in ('', 'support/', 'privacy/'):
            relative = (route + '/' if route else '') + kind
            path = web / relative / 'index.html'
            page = Page(path)
            label = str(path.relative_to(web))
            expected = origin + '/' + relative

            def require(condition, message):
                if not condition: errors.append(f'{label}: {message}')

            require(any(t == 'html' and a.get('lang') == lang for t, a in page.tags), 'wrong document language')
            require(sum(t == 'h1' for t, a in page.tags) == 1, 'expected exactly one h1')
            require(bool(page.title.strip()), 'missing title')
            require(page.title not in titles, 'duplicate title across routes')
            titles.add(page.title)
            require(any(t == 'meta' and a.get('name') == 'description' and a.get('content', '').strip() for t, a in page.tags), 'missing description')
            require(not any(t == 'meta' and a.get('http-equiv', '').lower() == 'refresh' for t, a in page.tags), 'automatic HTML redirect')
            robot_tags = [a.get('content', '').lower() for t, a in page.tags if t == 'meta' and a.get('name') == 'robots']
            require(bool(robot_tags) and all('noindex' not in r for r in robot_tags), 'production candidate is noindex')
            canonical = [a.get('href') for t, a in page.tags if t == 'link' and a.get('rel') == 'canonical']
            require(canonical == [expected], f'canonical must point to self: {expected}')
            canonicals.add(expected)
            alternate_tags = [a for t, a in page.tags if t == 'link' and a.get('rel') == 'alternate' and a.get('hreflang')]
            alternates = {a['hreflang']: a.get('href') for a in alternate_tags}
            wanted = {locale: origin + '/' + (r + '/' if r else '') + kind for locale, r in ROUTES.items()}
            wanted['x-default'] = origin + '/en/' + kind
            require(len(alternate_tags) == len(wanted) and alternates == wanted, 'hreflang family is incomplete or points to a different page type')

            if kind: continue
            require('PDF' in page.title.upper(), 'homepage title does not identify the PDF product')
            require(any(t == 'meta' and a.get('property') == 'og:url' and a.get('content') == expected for t, a in page.tags), 'social URL differs from canonical')
            require(any(t == 'meta' and a.get('name') == 'twitter:card' and a.get('content') == 'summary_large_image' for t, a in page.tags), 'missing large social preview')
            hero_images = [a for t, a in page.tags if t == 'img' and a.get('fetchpriority') == 'high']
            require(bool(hero_images) and all(a.get('loading') != 'lazy' and a.get('width') and a.get('height') for a in hero_images), 'hero image priority or layout dimensions missing')
            apps = [s for s in page.schemas if s.get('@type') == 'SoftwareApplication']
            require(len(apps) == 1, 'missing SoftwareApplication')
            if apps:
                app = apps[0]
                require(app.get('url') == expected and app.get('inLanguage') == lang, 'app schema URL/language mismatch')
                require(app.get('applicationCategory') == 'UtilitiesApplication', 'PDF utility category mismatch')
                require('offers' not in app and 'aggregateRating' not in app, 'prelaunch app must not invent an offer or ratings')
            visible = normalized(' '.join(page.visible))
            faqs = [s for s in page.schemas if s.get('@type') == 'FAQPage']
            require(len(faqs) == 1, 'missing FAQPage')
            if faqs:
                for question in faqs[0].get('mainEntity', []):
                    require(normalized(question.get('name', '')) in visible, 'schema question is not present in page content')
                    require(normalized(question.get('acceptedAnswer', {}).get('text', '')) in visible, 'schema answer is not present in page content')

    ns = {'s': 'http://www.sitemaps.org/schemas/sitemap/0.9', 'x': 'http://www.w3.org/1999/xhtml'}
    sitemap = ET.parse(web / 'sitemap.xml').getroot()
    sitemap_urls = [e.text for e in sitemap.findall('s:url/s:loc', ns)]
    if len(sitemap_urls) != len(canonicals) or set(sitemap_urls) != canonicals:
        errors.append('sitemap: indexable canonical pages and submitted URLs differ')
    for entry in sitemap.findall('s:url', ns):
        url = entry.find('s:loc', ns).text
        kind = 'support/' if url.endswith('support/') else 'privacy/' if url.endswith('privacy/') else ''
        actual = {e.get('hreflang'): e.get('href') for e in entry.findall('x:link', ns)}
        expected = {locale: origin + '/' + (r + '/' if r else '') + kind for locale, r in ROUTES.items()}
        expected['x-default'] = origin + '/en/' + kind
        if actual != expected: errors.append(f'sitemap: inconsistent hreflang for {url}')
    robots = (web / 'robots.txt').read_text()
    if re.search(r'^Disallow:\s*/\s*$', robots, re.M): errors.append('robots.txt: public site is blocked')
    if f'Sitemap: {origin}/sitemap.xml' not in robots: errors.append('robots.txt: sitemap origin mismatch')
    return errors


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--web', type=Path, default=ROOT / 'website')
    parser.add_argument('--origin', default='https://paperpath.monoware.app')
    args = parser.parse_args()
    problems = check(args.web, args.origin.rstrip('/'))
    if problems:
        print('\n'.join(problems))
        raise SystemExit(1)
    print('PASS: 15 production-candidate pages; self-canonical, reciprocal hreflang, sitemap, visible/schema content, social previews and hero image declarations. Live availability, indexing, rankings and field Core Web Vitals are not tested.')
