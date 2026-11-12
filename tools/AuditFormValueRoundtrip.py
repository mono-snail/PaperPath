"""Read the isolated UI-test PDF with pypdf; never modify the app or its files."""
import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
from pypdf import PdfReader


def widget_values(reader):
    values = {}
    for page in reader.pages:
        for reference in page.get('/Annots', []):
            widget = reference.get_object()
            if widget.get('/Subtype') != '/Widget':
                continue
            current = widget
            name = None
            value = None
            for _ in range(8):
                if name is None:
                    name = current.get('/T')
                if value is None:
                    value = current.get('/V')
                parent = current.get('/Parent')
                if parent is None:
                    break
                current = parent.get_object()
            if name is not None:
                assert str(name) not in values, 'Duplicate fixture field name'
                values[str(name)] = '' if value is None else str(value)
    return values


def audit(container, attachments):
    manifest = json.loads((attachments / 'manifest.json').read_text())
    entries = [a for test in manifest for a in test['attachments']]
    oracle_entry = next(a for a in entries if 'form-value-roundtrip-oracle' in a['suggestedHumanReadableName'])
    oracle = json.loads((attachments / oracle_entry['exportedFileName']).read_text())
    corpus = next(json.loads((attachments / a['exportedFileName']).read_text()) for a in entries
                  if 'merge-corpus-' in a['suggestedHumanReadableName']
                  and json.loads((attachments / a['exportedFileName']).read_text())['fixtureID'] == oracle['fixtureID'])
    fixture = container / 'Documents' / 'DocumentLifecycleUITestFixtures' / oracle['fixtureID']
    records = json.loads((fixture / 'library.json').read_text())
    matches = [r for r in records if r['displayName'] == oracle['documentName']]
    assert len(matches) == 1, 'Expected one saved fixture document'
    filename = matches[0]['fileName']
    assert Path(filename).name == filename, 'Fixture PDF must be a leaf filename'
    path = fixture / 'Documents' / filename
    saved_bytes = path.read_bytes()
    source = next(row for row in corpus['sources'] if row['name'] == oracle['documentName'])
    source_bytes = base64.b64decode(source['base64'], validate=True)
    before = PdfReader(io.BytesIO(source_bytes), strict=True)
    after = PdfReader(io.BytesIO(saved_bytes), strict=True)
    assert len(after.pages) == len(before.pages) == 1
    before_fields = widget_values(before)
    after_fields = widget_values(after)
    assert before_fields[oracle['fieldName']] == ''
    assert after_fields[oracle['fieldName']] == oracle['expectedValue']
    assert set(before_fields) == set(after_fields), 'Saved PDF lost or added fields'
    for key in before_fields.keys() - {oracle['fieldName']}:
        assert after_fields[key] == before_fields[key], 'Unrelated field changed'
    for old, new in zip(before.pages, after.pages):
        assert list(old.mediabox) == list(new.mediabox), 'Page geometry changed'
        old_text = ' '.join((old.extract_text() or '').split())
        new_text = ' '.join((new.extract_text() or '').split())
        assert 'MERGE-SOURCE-1-PAGE-1' in old_text, 'Source fixture text was not readable'
        assert old_text == new_text, 'Saved PDF changed page content'
    return dict(status='passed', parser='pypdf', fixtureID=oracle['fixtureID'],
                documentName=oracle['documentName'], pdf=str(path), pageCount=len(after.pages),
                fieldName=oracle['fieldName'], savedValue=after_fields[oracle['fieldName']],
                fieldCount=len(after_fields), geometryPreserved=True, pageTextPreserved=True,
                sourceSHA256=hashlib.sha256(source_bytes).hexdigest(),
                savedSHA256=hashlib.sha256(saved_bytes).hexdigest(),
                limitation='One isolated text-field fixture; not all PDF form types or readers.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', type=Path, required=True)
    parser.add_argument('--attachments', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = audit(args.container, args.attachments)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print('PASS: saved field value, field inventory, page geometry and page text verified independently with pypdf')
