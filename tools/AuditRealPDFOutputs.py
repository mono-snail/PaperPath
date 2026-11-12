#!/usr/bin/env python3
"""Independently inspect XCTest outputs with pypdf and Poppler, not PDFKit.

Use the bundled Python runtime. First export xcresult attachments into --attachments.
Writes machine-readable checks and reproducible render pairs beside the report.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import unicodedata
import zipfile
import xml.etree.ElementTree as ET
from pypdf import PdfReader
from PIL import Image, ImageChops, ImageStat, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / 'PaperPathTests/Fixtures/RealPDFCorpus'


def normalized(value):
    value = unicodedata.normalize('NFKC', value or '')
    value = ''.join(c for c in value if c != '\ufffc' and (not unicodedata.category(c).startswith('C') or c.isspace()))
    return re.sub(r'\s+', '', value)


def terminal_fields(reader):
    # get_fields includes non-input grouping nodes (e.g. topmostSubform).
    # Preserve every actual input and value; PDFKit may flatten group hierarchy.
    return {name: field for name, field in (reader.get_fields() or {}).items()
            if not any(child.get_object().get('/T') is not None for child in field.get('/Kids', []))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--attachments', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((CORPUS / 'manifest.json').read_text())['documents']
    sources = {row['file'][:-4]: row for row in manifest}
    for name, row in sources.items():
        assert hashlib.sha256((CORPUS / row['file']).read_bytes()).hexdigest() == row['sha256']
    attachments = json.loads((args.attachments / 'manifest.json').read_text())
    files = {}
    probe_rows = []
    office_files = {}
    for test in attachments:
        for item in test.get('attachments', []):
            name = item['suggestedHumanReadableName'].split('_0_')[0]
            path = args.attachments / item['exportedFileName']
            suffix = Path(item['suggestedHumanReadableName']).suffix
            if suffix and not name.endswith(suffix):
                name += suffix
            if name.endswith('.pdf'):
                files[name] = path
            elif name.endswith(('.docx', '.xlsx', '.pptx')):
                office_files[name] = path
            elif name.startswith('real-pdf-') and path.suffix == '.json':
                probe_rows.extend(json.loads(path.read_text()))
    checks = []
    render_dir = args.output.parent / 'renders'
    render_dir.mkdir(exist_ok=True)
    render_cache = {}

    def check(file, feature, passed, detail):
        checks.append(dict(file=file, feature=feature, passed=bool(passed), detail=detail))

    def render(pdf, page, supersample=False):
        key = (str(pdf), page, supersample)
        if key not in render_cache:
            output = render_dir / (hashlib.sha256(str(pdf).encode()).hexdigest()[:10] + f'-{page}' + ('-4x' if supersample else ''))
            subprocess.run(['pdftoppm', '-f', str(page + 1), '-l', str(page + 1), '-singlefile', '-scale-to', '1440' if supersample else '360', '-png', str(pdf), str(output)], check=True, capture_output=True)
            render_cache[key] = output.with_suffix('.png')
        result = Image.open(render_cache[key]).convert('RGB')
        if supersample:
            factor = 360 / max(result.size)
            result = result.resize(tuple(max(1, round(v * factor)) for v in result.size), Image.Resampling.LANCZOS)
        return result

    for name, path in files.items():
        source_name = next((s for s in sources if name.startswith(s + '-')), None)
        if source_name is None:
            continue
        action = name[len(source_name) + 1:-4]
        source = CORPUS / sources[source_name]['file']
        try:
            original = PdfReader(source)
            output = PdfReader(path)
            if output.is_encrypted:
                check(name, 'incorrect-password-rejected', output.decrypt('incorrect-password') == 0, 'Independent reader rejects incorrect password')
                check(name, 'correct-password-accepted', output.decrypt('ReleaseTest-2026') != 0, 'Independent reader decrypts the original application output')
            check(name, 'readable', len(output.pages) > 0, f'{len(output.pages)} pages')
            if action == 'merge':
                other = next(s for s in sources if s != source_name)
                expected = list(original.pages) + list(PdfReader(CORPUS / sources[other]['file']).pages)
            elif action.startswith('page-'):
                expected = [original.pages[int(action[5:])]]
            elif action == 'pages':
                expected = list(reversed(original.pages))
            else:
                expected = list(original.pages)
            if action in ['merge', 'pages', 'preserveContent', 'optimizedImages', 'unlocked', 'protected', 'bookmarks', 'filled', 'annotations', 'content'] or action.startswith('page-'):
                check(name, 'page-count', len(output.pages) == len(expected), f'{len(output.pages)} / expected {len(expected)}')
                for i, (before, after) in enumerate(zip(expected, output.pages)):
                    lhs, rhs = normalized(before.extract_text()), normalized(after.extract_text())
                    check(name, f'text-page-{i+1}', (lhs in rhs if action == 'content' else lhs == rhs), f'{len(lhs)} / {len(rhs)} characters')
            if action in ['merge', 'unlocked', 'protected', 'preserveContent', 'optimizedImages', 'annotations', 'content', 'bookmarks', 'filled', 'pages'] or action.startswith('page-'):
                before_fields, after_fields = terminal_fields(original), terminal_fields(output)
                check(name, 'canonical-form-fields', (True if action.startswith('page-') else set(before_fields).issubset(after_fields)), f'{len(before_fields)} source / {len(after_fields)} output fields')
                if action not in ['merge', 'filled'] and not action.startswith('page-'):
                    check(name, 'canonical-form-values', all((after_fields.get(k, {}).get('/V') or '') == (v.get('/V') or '') for k, v in before_fields.items()), 'All original input values preserved')
                before_attachments = {k: [hashlib.sha256(b).hexdigest() for b in v] for k, v in original.attachments.items()}
                after_payloads = {hashlib.sha256(b).hexdigest() for v in output.attachments.values() for b in v}
                check(name, 'attachment-payloads', all(h in after_payloads for hashes in before_attachments.values() for h in hashes), f'{len(before_attachments)} source names / {len(after_payloads)} output payloads')
            if action == 'content':
                resources = output.pages[0]['/Resources'].get_object()
                xobjects = resources['/XObject'] if '/XObject' in resources else {}
                added = [v.get_object() for k, v in xobjects.items() if str(k).startswith('/PaperPathAddedImage')]
                check(name, 'added-image-form', any(v.get('/Subtype') == '/Form' for v in added), 'New image form exists beside original resources')
                annotations = [a.get_object() for a in output.pages[0].get('/Annots', [])]
                check(name, 'added-text', any(str(a.get('/Contents', '')) == 'Real PDF QA' for a in annotations), 'Text annotation survives reopening')
                check(name, 'added-link', any(str((a['/A'] if '/A' in a else {}).get('/URI', '')) == 'https://example.com/qa' for a in annotations), 'Link target survives reopening')
            if action in ['flatten', 'safe-share', 'redact']:
                check(name, 'no-hidden-source-text', all(not normalized(page.extract_text()) for page in output.pages), 'Raster copy contains no hidden source text')
                check(name, 'no-active-annotations', all(not page.get('/Annots') for page in output.pages), 'No active annotations')
                check(name, 'no-attachments', not output.attachments, 'No original attachment payloads')
                if action == 'redact':
                    image = render(path, 0)
                    mean = sum(ImageStat.Stat(image).mean) / 3
                    check(name, 'redaction-visible', mean < 1, f'Full-page redaction mean brightness {mean:.4f}/255')
            if action in ['preserveContent', 'optimizedImages', 'imageCopy', 'flatten', 'safe-share']:
                for i in range(min(len(original.pages), len(output.pages))):
                    a, b = render(source, i, action != 'preserveContent'), render(path, i, action != 'preserveContent')
                    if a.size != b.size:
                        check(name, f'render-page-{i+1}', False, f'size {a.size} / {b.size}')
                        continue
                    # Supersampling plus a one-pixel low pass avoids mistaking raster/vector font
                    # hinting and subpixel alignment for missing page content.
                    if action != 'preserveContent':
                        a, b = a.filter(ImageFilter.GaussianBlur(1)), b.filter(ImageFilter.GaussianBlur(1))
                    mae = sum(ImageStat.Stat(ImageChops.difference(a, b)).mean) / 3
                    limit = 0.25 if action == 'preserveContent' else 15
                    check(name, f'render-page-{i+1}', mae <= limit, f'mean absolute channel difference {mae:.4f}/255 (limit {limit})')
        except Exception as error:
            check(name, 'read-or-verify', False, str(error))
    for name, path in office_files.items():
        try:
            with zipfile.ZipFile(path) as archive:
                entries = archive.namelist()
                check(name, 'zip-crc', archive.testzip() is None, 'All archived parts pass CRC')
                root = {'docx': 'word/document.xml', 'xlsx': 'xl/workbook.xml', 'pptx': 'ppt/presentation.xml'}[Path(name).suffix[1:]]
                check(name, 'office-main-part', root in entries, root)
                xml_parts = [entry for entry in entries if entry.endswith(('.xml', '.rels'))]
                for entry in xml_parts:
                    ET.fromstring(archive.read(entry))
                check(name, 'office-xml', bool(xml_parts), f'{len(xml_parts)} well-formed XML parts')
                # Resolve package-internal relationship targets independently.
                import posixpath
                for entry in entries:
                    if not entry.endswith('.rels'): continue
                    directory = posixpath.dirname(posixpath.dirname(entry)) if entry != '_rels/.rels' else ''
                    for relation in ET.fromstring(archive.read(entry)):
                        if relation.get('TargetMode') == 'External': continue
                        target = relation.get('Target', '').split('#')[0]
                        resolved = target.lstrip('/') if target.startswith('/') else posixpath.normpath(posixpath.join(directory, target))
                        check(name, 'office-relationship', resolved in entries, entry + ' -> ' + resolved)
        except Exception as error:
            check(name, 'office-read-or-verify', False, str(error))
    failures = [row for row in checks if not row['passed']]
    result = dict(sources=manifest, probes=probe_rows, pdf_output_count=len(files), checks=checks, failures=failures,
                  status='PASSED' if checks and not failures and not any(r['status'] == 'failed' for r in probe_rows) else 'FAILED')
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(f'{len(files)} output PDFs, {len(checks)} independent checks, {len(failures)} failed; {result["status"]}')
    for failure in failures:
        print(failure['file'], failure['feature'], failure['detail'])
    return 0 if result['status'] == 'PASSED' else 1


if __name__ == '__main__':
    raise SystemExit(main())
