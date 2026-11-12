#!/usr/bin/env python3
"""Independently audit PDFs produced by the merge UI, without AI or network."""
import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import unicodedata
import subprocess
import tempfile
import shutil
from PIL import Image, ImageChops
from pypdf import PdfReader


def normalized_text(page):
    return ''.join(unicodedata.normalize('NFKC', page.extract_text() or '').split())


def image_fingerprints(page):
    # Compare encoded image bytes, including masks and JBIG2 global tables.
    # No decoder executable or network installation is needed for JBIG2.
    def canonical(value, depth=0):
        assert depth < 24, 'Unexpected image resource cycle'
        value = value.get_object() if hasattr(value, 'get_object') else value
        if isinstance(value, dict):
            result = {str(k): canonical(v, depth + 1) for k, v in value.items()
                      if str(k) not in ['/Length', '/Metadata']}
            if hasattr(value, '_data'):
                result['encoded_sha256'] = hashlib.sha256(value._data).hexdigest()
            return result
        if isinstance(value, (list, tuple)):
            return [canonical(v, depth + 1) for v in value]
        return str(value)

    found = []
    def visit(resources, depth=0):
        assert depth < 24, 'Unexpected form resource cycle'
        objects = resources.get('/XObject', {})
        objects = objects.get_object() if hasattr(objects, 'get_object') else objects
        for reference in objects.values():
            obj = reference.get_object()
            if obj.get('/Subtype') == '/Image':
                found.append(hashlib.sha256(json.dumps(canonical(obj), sort_keys=True).encode()).hexdigest())
            elif obj.get('/Subtype') == '/Form':
                visit(obj.get('/Resources', {}).get_object() if hasattr(obj.get('/Resources', {}), 'get_object') else obj.get('/Resources', {}), depth + 1)
    resources = page.get('/Resources', {})
    visit(resources.get_object() if hasattr(resources, 'get_object') else resources)
    return sorted(found)


def annotation_signature(reference):
    annotation = reference.get_object()
    contents = annotation.get('/Contents')
    # Popup comments inherit the parent's contents. PDFKit may explicitly copy
    # that same text onto /Popup when saving; this is semantically identical.
    if contents is None and annotation.get('/Subtype') == '/Popup':
        parent = annotation.get('/Parent', {})
        parent = parent.get_object() if hasattr(parent, 'get_object') else parent
        contents = parent.get('/Contents', '')
    action = annotation.get('/A', {})
    action = action.get_object() if hasattr(action, 'get_object') else action
    return (str(annotation.get('/Subtype', '')), str(contents or ''),
            tuple(float(v) for v in annotation.get('/Rect', [])),
            str(action.get('/S', '')), str(action.get('/URI', '')))



def page_signature(page):
    return dict(text=normalized_text(page),
        media=[round(float(v), 3) for v in page.mediabox],
        crop=[round(float(v), 3) for v in page.cropbox], rotation=page.rotation,
        images=image_fingerprints(page),
        annotations=sorted(annotation_signature(a) for a in page.get('/Annots', [])))


def assert_same_render(source_bytes, source_page, output_path, output_page, evidence=None, output_password=None):
    # PDFKit may transcode JBIG2 to Flate without changing pixels. Compare
    # independent Poppler renders, rather than requiring identical encodings.
    with tempfile.TemporaryDirectory(prefix='paperpath-merge-render-') as directory:
        root = Path(directory)
        source = root / 'source.pdf'
        source.write_bytes(source_bytes)
        for name, path, page in [('source', source, source_page), ('result', output_path, output_page)]:
            command = ['pdftoppm', '-f', str(page + 1), '-l', str(page + 1),
                       '-singlefile', '-scale-to', '1440', '-png']
            if name == 'result' and output_password is not None:
                command += ['-upw', output_password]
            subprocess.run(command + [str(path), str(root / name)], check=True, capture_output=True)
        before = Image.open(root / 'source.png').convert('RGB')
        after = Image.open(root / 'result.png').convert('RGB')
        assert before.size == after.size, f'Page {output_page + 1} render dimensions changed'
        difference = ImageChops.difference(before, after)
        if evidence is not None:
            evidence.mkdir(parents=True, exist_ok=True)
            for name in ['source', 'result']:
                shutil.copyfile(root / (name + '.png'), evidence / f'page-{output_page + 1:02d}-{name}.png')
        assert difference.getbbox() is None, f'Page {output_page + 1} rendered pixels changed'


def audit(attachments, container, evidence_root=None):
    corpora = {}
    expectations = []
    for path in attachments.rglob('*'):
        if not path.is_file():
            continue
        try:
            value = json.loads(path.read_bytes())
        except (ValueError, UnicodeDecodeError):
            continue
        if not isinstance(value, dict):
            continue
        if value.get('schema') == 'paperpath-merge-ui-v1':
            corpora[value['fixtureID']] = value
        if value.get('schema') == 'paperpath-merge-output-v1':
            expectations.append(value)
    assert expectations, 'No output expectation attachment: saved-output verification cannot be skipped'
    results = []
    for expectation in expectations:
        corpus = corpora[expectation['fixtureID']]
        root = container / 'Documents' / 'DocumentLifecycleUITestFixtures' / expectation['fixtureID']
        records = json.loads((root / 'library.json').read_text())
        if isinstance(records, dict):
            records = records['documents']
        assert len(records) == len(corpus['sources']) + 1, 'Missing sources or unexpected duplicate output'
        sources = []
        source_hashes = {}
        for entry in corpus['sources']:
            matches = [r for r in records if r['displayName'] == entry['name']]
            assert len(matches) == 1, 'Source missing or duplicated: ' + entry['name']
            data = (root / 'Documents' / matches[0]['fileName']).read_bytes()
            expected = base64.b64decode(entry['base64'])
            assert data == expected, 'Merge changed an original: ' + entry['name']
            source_hashes[entry['name']] = hashlib.sha256(data).hexdigest()
            sources.append(None if entry['name'] in corpus.get('unreadableSources', []) else PdfReader(io.BytesIO(data), strict=True))
        matches = [r for r in records if r['displayName'] == expectation['resultName']]
        assert len(matches) == 1, 'Result not persisted exactly once'
        output_path = root / 'Documents' / matches[0]['fileName']
        result = PdfReader(str(output_path), strict=True)
        assert all(sources[number - 1] is not None for number in expectation['order']), 'Unreadable source entered successful output'
        expected_pages = [(number - 1, page_index, page) for number in expectation['order']
                          for page_index, page in enumerate(sources[number - 1].pages)]
        assert len(result.pages) == len(expected_pages), 'Output page count mismatch'
        expected_attachments = {}
        for number in expectation['order']:
            for name, payloads in sources[number - 1].attachments.items():
                expected_attachments.setdefault(name, set()).update(hashlib.sha256(data).hexdigest() for data in payloads)
        actual_attachments = {name: {hashlib.sha256(data).hexdigest() for data in payloads}
                              for name, payloads in result.attachments.items()}
        assert actual_attachments == expected_attachments, 'Embedded attachment names or bytes changed'
        checks = []
        for index, ((source_index, source_page, original), merged) in enumerate(zip(expected_pages, result.pages)):
            before, after = page_signature(original), page_signature(merged)
            image_encoding_changed = before.pop('images') != after.pop('images')
            assert before == after, f'Output page {index + 1} changed: {before} != {after}'
            render_evidence = evidence_root / expectation['fixtureID'] / 'renders' if evidence_root else None
            assert_same_render(base64.b64decode(corpus['sources'][source_index]['base64']),
                source_page, output_path, index, render_evidence)
            checks.append(dict(page=index + 1, text_order=True, geometry=True,
                rendered_pixels_identical=True, image_encoding_changed=image_encoding_changed,
                annotations=True))
        evidence = None
        if evidence_root is not None:
            evidence = evidence_root / expectation['fixtureID']
            evidence.mkdir(parents=True, exist_ok=True)
            for number, entry in enumerate(corpus['sources'], 1):
                (evidence / f'source-{number:02d}.pdf').write_bytes(base64.b64decode(entry['base64']))
            (evidence / 'merged.pdf').write_bytes(output_path.read_bytes())
            (evidence / 'sources.json').write_text(json.dumps(dict(
                sources=[dict(number=i + 1, name=entry['name'], pages=len(sources[i].pages) if sources[i] is not None else 0)
                         for i, entry in enumerate(corpus['sources'])],
                merge_order=expectation['order']), ensure_ascii=False, indent=2) + '\n')
        results.append(dict(fixtureID=expectation['fixtureID'], path=str(output_path),
            retained_evidence=str(evidence) if evidence else None,
            sha256=hashlib.sha256(output_path.read_bytes()).hexdigest(),
            original_sha256=source_hashes, source_order=expectation['order'], pages=checks,
            attachments_preserved=True, attachment_sha256={name: sorted(values) for name, values in actual_attachments.items()}))
    return dict(status='PASSED', outputs=results)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--attachments', type=Path, required=True)
    parser.add_argument('--container', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        report = audit(args.attachments, args.container, args.output.parent / "pdf-evidence")
    except Exception as error:
        report = dict(status='FAILED', error=str(error))
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print('Independent saved merge PDF audit:', report['status'], '—', args.output)
    return 0 if report['status'] == 'PASSED' else 1


if __name__ == '__main__':
    raise SystemExit(main())
