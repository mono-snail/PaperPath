#!/usr/bin/env python3
"""Validate launch metadata, crawlable routes, internal assets and paid-launch copy."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse, unquote
import json
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
WEB=ROOT/'website'
class Page(HTMLParser):
    def __init__(self,path):
        super().__init__();self.tags=[];self.ids=set();self.h1=0;self.schema=[];self.collect=False;self.buffer='';self.feed(path.read_text())
    def handle_starttag(self,tag,attrs):
        a=dict(attrs);self.tags.append((tag,a))
        if a.get('id'):self.ids.add(a['id'])
        if tag=='h1':self.h1+=1
        if tag=='script' and a.get('type')=='application/ld+json':self.collect=True;self.buffer=''
    def handle_data(self,data):
        if self.collect:self.buffer+=data
    def handle_endtag(self,tag):
        if tag=='script' and self.collect:self.schema.append(json.loads(self.buffer));self.collect=False

errors=[];count=0
pages={p:Page(p) for p in WEB.rglob('index.html')}
for path,page in pages.items():
    count+=1;label=str(path.relative_to(WEB));source=path.read_text()
    canonical=[a['href'] for t,a in page.tags if t=='link' and a.get('rel')=='canonical']
    if len(canonical)!=1 or not canonical[0].startswith('https://paperpath.monoware.app/'):errors.append(label+': invalid canonical')
    alternates=[a for t,a in page.tags if t=='link' and a.get('rel')=='alternate' and a.get('hreflang')]
    if len(alternates)!=6 or any(not a['href'].startswith('https://') for a in alternates):errors.append(label+': incomplete absolute hreflang')
    if page.h1!=1:errors.append(label+': expected one h1')
    for t,a in page.tags:
        if t=='img' and (not a.get('alt') and a.get('alt')!=''):errors.append(label+': image missing alt')
        for field in ('href','src'):
            value=a.get(field,'');u=urlparse(value)
            if not value or u.scheme or value.startswith('//'):continue
            target=(WEB/unquote(u.path.lstrip('/'))) if u.path.startswith('/') else path.parent/unquote(u.path)
            if not u.path:target=path
            if target.is_dir():target=target/'index.html'
            if not target.exists():errors.append(label+': missing '+value);continue
            if u.fragment and target.suffix=='.html' and target in pages and u.fragment not in pages[target].ids:errors.append(label+': missing fragment '+value)
    if '/privacy/' not in '/'+label:
        if 'locale-router.js' in source:errors.append(label+': automatic language redirect')
    if label.count('/')<=1 and not label.startswith(('privacy/','support/')):
        if 'US$6.99' not in source:errors.append(label+': missing approved price')
        if any(s in source for s in ['Download free','免费下载','免费下载','"price": "0"']):errors.append(label+': stale free pricing')
        if len(page.schema)!=2:errors.append(label+': missing app/FAQ schema')
        if any('aggregateRating' in json.dumps(s) for s in page.schema):errors.append(label+': unverified ratings')
urls=ET.parse(WEB/'sitemap.xml').getroot()
if len(urls)!=15:errors.append('sitemap: expected 15 localized pages')
for loc in ['en-US','zh-Hans']:
    d=json.loads((ROOT/'docs/app-store-connect-2026-10-26'/f'{loc}.json').read_text())
    for key,limit in [('name',30),('subtitle',30),('promotionalText',170),('description',4000)]:
        if len(d[key])>limit:errors.append(f'{loc}: {key} exceeds {limit}')
    if len(d['keywords'].encode('utf-8'))>100:errors.append(loc+': keywords exceed 100 UTF-8 bytes')
if errors:
    print('\n'.join(errors));raise SystemExit(1)
print(f'PASS: {count} HTML pages; local links/assets, canonical/hreflang, sitemap, app/FAQ JSON-LD, paid-launch copy and bilingual Connect field limits.')
