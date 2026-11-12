#!/usr/bin/env python3
"""Read actual isolated UI stores, never screenshots or synthetic success text."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import uuid
from pypdf import PdfReader


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()



def terminal_fields(reader):
    values = reader.get_fields() or {}
    result = {name: (str(field.get('/FT', '')), str(field.get('/V') or ''))
        for name, field in values.items()
        if not any(kid.get_object().get('/T') is not None for kid in field.get('/Kids', []))}
    # PDFKit's seed PDF has page widgets without an AcroForm
    # catalog. Encryption repairs that catalog. Compare the
    # actual terminal fields in both representations.
    for page in reader.pages:
        for ref in page.get('/Annots', []):
            widget = ref.get_object()
            if widget.get('/Subtype') != '/Widget': continue
            chain, seen = [], set()
            while widget is not None:
                if id(widget) in seen: raise ValueError('Cyclic form field parent')
                seen.add(id(widget)); chain.append(widget)
                widget = widget.get('/Parent')
                if widget is not None: widget = widget.get_object()
            name = '.'.join(str(node['/T']) for node in reversed(chain) if '/T' in node)
            inherited = lambda key: next((node[key] for node in chain if key in node), '')
            pair = (str(inherited('/FT')), str(inherited('/V') or ''))
            if name in result: assert result[name] == pair, 'Conflicting form field values'
            result[name] = pair
    return result


def audit(container, output, summary, test_ids, profiles):
    cases = []
    snapshots = []
    for path in (container / 'Documents/QualityEvidence').glob('*/initial.json'):
        proof = json.loads(path.read_text())
        if summary['startTime'] - 5 <= proof['createdAt'] <= summary['finishTime'] + 5:
            snapshots.append((path, proof))
    for test_id in test_ids:
        method = test_id.split('/', 1)[1].removesuffix('()')
        profile = next((dict(value, feature=key) for key, value in profiles.items()
                        if method in [value['standard'], value['largeText']] or method in value.get('additionalCases', {})), None)
        if profile is None: raise ValueError('Unregistered quality journey: ' + test_id)
        matches = [(path, proof) for path, proof in snapshots
                   if (re.search(r'\b(test\w+)\b', proof['testID']) or [''])[1] == method]
        assert len(matches) == 1, 'Missing or ambiguous initial real-file snapshot: ' + method
        path, proof = matches[0]
        assert proof['feature'] == profile['feature'], 'Captured feature does not match executed test'
        case_options = profile.get('additionalCases', {}).get(method, {})
        if method == profile['largeText'] or case_options.get('largeText'):
            assert proof['contentSize'] == 'UICTContentSizeCategoryAccessibilityXXXL', 'Large text launch was overridden'
        recorded_root = Path(proof['storeRoot'])
        def valid_uuid(value):
            try: uuid.UUID(value); return True
            except (ValueError, TypeError, AttributeError): return False
        assert valid_uuid(recorded_root.name) and recorded_root.parent.name == 'DocumentLifecycleUITestFixtures' and recorded_root.parent.parent.name == 'Documents', 'Capture escaped isolated test store'
        assert valid_uuid(proof['caseID']) and path.parent.name == proof['caseID'], 'Invalid quality case identity'
        # Reinstalling a build can relocate the same preserved app data into a
        # new Application container UUID. Bind to the immutable fixture UUID,
        # then resolve it only inside the current container's isolated stores.
        base = container / 'Documents/DocumentLifecycleUITestFixtures'
        root = base / recorded_root.name
        assert root.resolve().is_relative_to(base.resolve()), 'Capture escaped isolated test store'
        records = json.loads((root / 'library.json').read_text())
        retained = output / proof['caseID']
        retained.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, retained / 'initial.json')
        shutil.copytree(path.parent / 'sources', retained / 'sources', dirs_exist_ok=True)
        shutil.copyfile(root / 'library.json', retained / 'final-library.json')
        files = []
        for record in records:
            source = root / 'Documents' / record['fileName']
            target = retained / record['fileName']
            shutil.copyfile(source, target)
            files.append(dict(id=record['id'], name=record['displayName'], path=str(target), sha256=digest(target)))
        kind = case_options.get('audit', profile.get('audit', 'notConfigured'))
        checks = []
        if kind not in {'unchanged', 'compressionLossless', 'protection', 'extraction', 'editedContent', 'editedLink', 'redaction', 'formAdded', 'searchableOCR', 'addedAnnotation', 'wordDocument', 'pageImages', 'safeShare', 'imageCreation', 'formFilled', 'importedPDF', 'notConfigured'}: raise ValueError('Unsupported output audit: ' + kind)
        if kind == 'importedPDF':
            assert len(records) == len(proof['sources']) + 1, 'Import must add exactly one PDF'
            old_ids = {source['id'].lower() for source in proof['sources']}
            for source in proof['sources']:
                current = next(row for row in records if row['id'].lower() == source['id'].lower())
                assert digest(root / 'Documents' / current['fileName']) == source['sha256'], 'Import changed an existing PDF'
            created = next(row for row in records if row['id'].lower() not in old_ids)
            assert created['displayName'] == profile['sourceName'], 'Wrong PDF imported through Files'
            saved = root / 'Documents' / created['fileName']
            assert digest(saved) == profile['sourceSHA256'], 'Imported bytes differ from the pinned original'
            count = len(PdfReader(saved, strict=True).pages)
            assert count > 0, 'Imported PDF is unreadable'
            checks.append(dict(pinnedOriginalBytes=True, originalSourcesUnchanged=True,
                exactlyOneNewOutput=True, readablePages=count))
        if kind == 'formFilled':
            from AuditMergeOutputs import page_signature
            assert len(records) == len(proof['sources']), 'Filling a form must keep one working document'
            for source in proof['sources']:
                current = next(row for row in records if row['id'].lower() == source['id'].lower())
                saved = root / 'Documents' / current['fileName']
                original = retained / 'sources' / source['captureFile']
                assert digest(original) == source['sha256'], 'Initial form capture changed'
                if source['name'] != 'Project handoff':
                    assert digest(saved) == source['sha256'], 'Filling changed an unrelated PDF'
                    continue
                before, after = PdfReader(original, strict=True), PdfReader(saved, strict=True)
                old_fields, new_fields = terminal_fields(before), terminal_fields(after)
                field = case_options['fieldName']; value = case_options['fieldValue']
                assert old_fields.pop(field) == ('/Tx', ''), 'Expected blank text field was not present initially'
                assert new_fields.pop(field, None) == ('/Tx', value), 'Actual saved form value is missing or wrong'
                assert old_fields == new_fields, 'Filling changed other form values'
                assert len(before.pages) == len(after.pages) > 0, 'Filling lost pages'
                assert all(page_signature(a) == page_signature(b) for a,b in zip(before.pages,after.pages)), 'Filling changed original page content or geometry'
                checks.append(dict(savedFieldValueVerified=True, otherFieldsPreserved=True,
                    originalPageContentPreserved=True, unchangedDocumentIdentity=True,
                    otherDocumentsUnchanged=True, pageCount=len(after.pages), fieldName=field))
            assert checks, 'Filled source was not audited'
        if kind == 'imageCreation':
            from AuditCoreCreation import audit_creation
            assert len(records) == len(proof['sources']) + 1, 'Image creation must publish exactly one document'
            old_ids = {source['id'].lower() for source in proof['sources']}
            for source in proof['sources']:
                current = next(row for row in records if row['id'].lower() == source['id'].lower())
                assert digest(root / 'Documents' / current['fileName']) == source['sha256'], 'Image creation changed an existing PDF'
            created = next(row for row in records if row['id'].lower() not in old_ids)
            assert created['displayName'].startswith(profile['createdNamePrefix']), 'Image creation used the wrong workflow'
            result = audit_creation(root / 'Documents' / created['fileName'])
            checks.append(dict(**result, originalSourcesUnchanged=True, exactlyOneNewOutput=True))
        if kind == 'safeShare':
            from AuditSafeShareArtifact import audit_safe_share
            assert len(records) == len(proof['sources']) + 1, 'Share must publish exactly one new PDF'
            old_ids = {s['id'].lower() for s in proof['sources']}
            for source in proof['sources']:
                current = next(r for r in records if r['id'].lower() == source['id'].lower())
                assert digest(root / 'Documents' / current['fileName']) == source['sha256'], 'Share changed an original PDF'
            source = next(s for s in proof['sources'] if s['name'] == 'Project handoff')
            original = retained / 'sources' / source['captureFile']
            assert digest(original) == source['sha256'], 'Initial share capture changed'
            created = next(r for r in records if r['id'].lower() not in old_ids)
            assert created['displayName'] == 'Project handoff - Export', 'Share published the wrong named output'
            result = audit_safe_share(original, root / 'Documents' / created['fileName'])
            checks.append(dict(**result, originalSourcesUnchanged=True, exactlyOneNewOutput=True))
        if kind == 'pageImages':
            from AuditImageOutputs import audit_page_image
            assert len(records) == len(proof['sources']), 'Page image export duplicated a working PDF'
            for source in proof['sources']:
                current = next(r for r in records if r['id'].lower() == source['id'].lower())
                assert digest(root / 'Documents' / current['fileName']) == source['sha256'], 'Page image export changed an original PDF'
            source = next(s for s in proof['sources'] if s['name'] == case_options.get('sourceName', 'Project handoff'))
            original = retained / 'sources' / source['captureFile']
            assert digest(original) == source['sha256'], 'Initial capture changed'
            if case_options.get('sourceSHA256'): assert source['sha256'] == case_options['sourceSHA256'], 'Image export did not use the pinned original scan'
            groups = list((path.parent / 'image-exports').glob('*/manifest.json'))
            assert len(groups) == 1, 'Expected exactly one actual image export capture'
            capture = json.loads(groups[0].read_text())
            assert capture['caseID'] == proof['caseID'] and capture['testID'] == proof['testID'], 'Image capture belongs to another UI case'
            assert capture['recordID'].lower() == source['id'].lower() and capture['preset'] == profile['imagePreset'], 'Image capture used the wrong source or preset'
            assert summary['startTime'] - 5 <= capture['createdAt'] <= summary['finishTime'] + 5, 'Image capture is stale'
            outputs = capture['files']; count = len(PdfReader(original, strict=True).pages)
            assert len(outputs) == count and [row['pageIndex'] for row in outputs] == list(range(count)), 'Image export skipped or duplicated a page'
            page_checks = []
            for row in outputs:
                name = row['fileName']; assert Path(name).name == name, 'Image capture escaped its directory'
                image = groups[0].parent / name
                assert digest(image) == row['sha256'], 'Captured image bytes changed'
                target = retained / name; shutil.copyfile(image, target)
                files.append(dict(id='page-image-' + str(row['pageIndex']), name=name, path=str(target), sha256=digest(target)))
                page_checks.append(audit_page_image(original, row['pageIndex'], target, profile['longestEdge'], retained / 'image-comparison'))
            checks.append(dict(originalSourcesUnchanged=True, sourceAndPresetVerified=True, everyPageImageVerified=True,
                pageCount=count, exportedCount=len(outputs), maximumRelativeError=max(row['relativeMeanSquaredError'] for row in page_checks),
                pages=page_checks))
        if kind == 'wordDocument':
            from AuditOfficeArtifact import audit_docx
            assert len(records) == len(proof['sources']), 'Office export duplicated a working PDF'
            for source in proof['sources']:
                current = next(r for r in records if r['id'].lower() == source['id'].lower())
                assert digest(root / 'Documents' / current['fileName']) == source['sha256'], 'Office export changed an original PDF'
                if source['name'] != 'Project handoff': continue
                receipts = current.get('officeReceipts', [])
                assert len(receipts) == 1 and receipts[0]['format'] == 'wordDocument', 'Expected exactly one retained Word export'
                receipt = receipts[0]; filename = receipt.get('retainedFileName', '')
                assert filename and Path(filename).name == filename and filename.endswith('.docx'), 'Word artifact has an unsafe or missing filename'
                assert receipt.get('sourceRevisionID') == current['contentRevisionID'], 'Office artifact belongs to another PDF revision'
                artifact = root / 'OfficeExports' / current['id'] / filename
                assert artifact.resolve().is_relative_to((root / 'OfficeExports').resolve()), 'Office artifact escaped its store'
                assert digest(artifact) == receipt.get('artifactSHA256') and artifact.stat().st_size == receipt['fileSizeBytes'], 'Retained Word artifact differs from its receipt'
                target = retained / filename; shutil.copyfile(artifact, target)
                files.append(dict(id='office-' + receipt['id'], name='Word export', path=str(target), sha256=digest(target)))
                result = audit_docx(target, retained / 'sources' / source['captureFile'])
                checks.append(dict(**result, originalSourcesUnchanged=True, sourceRevisionVerified=True, artifactReceiptVerified=True))
            assert checks, 'Office source was not audited'
        if kind == 'addedAnnotation':
            from collections import Counter
            import math
            from AuditMergeOutputs import page_signature, annotation_signature, assert_same_render
            assert len(records) == len(proof['sources']), 'Annotation duplicated the working document'
            for source in proof['sources']:
                original = retained / 'sources' / source['captureFile']
                assert digest(original) == source['sha256'], 'Initial capture changed'
                current = next(r for r in records if r['id'].lower() == source['id'].lower())
                saved = root / 'Documents' / current['fileName']
                if source['name'] != 'Project handoff':
                    assert digest(saved) == source['sha256'], 'Annotation changed an unrelated document'
                    continue
                before, after = PdfReader(original, strict=True), PdfReader(saved, strict=True)
                assert len(before.pages) == len(after.pages), 'Annotation lost a page'
                assert terminal_fields(before) == terminal_fields(after), 'Annotation changed existing form fields'
                count = 0
                for index, (a, b) in enumerate(zip(before.pages, after.pages)):
                    left, right = page_signature(a), page_signature(b)
                    old, new = left.pop('annotations'), right.pop('annotations')
                    assert left == right, 'Annotation changed original page content or geometry'
                    assert not (Counter(old) - Counter(new)), 'Annotation removed an existing mark'
                    added = list((Counter(new) - Counter(old)).elements()); count += len(added)
                    for row in added:
                        assert row[0] in profile['annotationTypes'] and row[1] == profile['annotationContents'], 'Expected saved annotation is missing or altered'
                        x0, y0, x1, y1 = row[2]
                        assert all(math.isfinite(v) for v in row[2]) and b.mediabox.left <= x0 < x1 <= b.mediabox.right and b.mediabox.bottom <= y0 < y1 <= b.mediabox.top, 'Saved annotation lies outside its page'
                        objects = [ref.get_object() for ref in b.get('/Annots', []) if annotation_signature(ref) == row]
                        assert objects and all(not int(obj.get('/F', 0)) & 35 for obj in objects), 'Saved annotation is not visible'
                        if row[0] == '/Ink':
                            assert all(obj.get('/InkList') and all(len(path.get_object()) >= 4 and all(math.isfinite(float(v.get_object())) for v in path.get_object())
                                for path in obj['/InkList']) for obj in objects), 'Saved ink strokes are empty or invalid'
                    if added:
                        try: assert_same_render(original.read_bytes(), index, saved, index, retained / 'renders')
                        except AssertionError as error: assert 'rendered pixels changed' in str(error), str(error)
                        else: raise AssertionError('Saved annotation has no visible rendered appearance')
                    else: assert_same_render(original.read_bytes(), index, saved, index, retained / 'renders')
                assert count == profile['annotationCount'], 'Unexpected number of saved annotations'
                checks.append(dict(pageCount=len(after.pages), addedCount=count, expectedCount=profile['annotationCount'],
                    annotationContentVerified=True, visibleRenderingVerified=True, boundsAndStrokesValid=True,
                    originalContentAndFieldsPreserved=True, unchangedDocumentIdentity=True, otherDocumentsUnchanged=True))
            assert checks, 'Annotation source was not audited'
        if kind == 'searchableOCR':
            from AuditMergeOutputs import normalized_text, page_signature, assert_same_render
            assert len(records) == len(proof['sources']), 'Saving OCR duplicated the working document'
            for source in proof['sources']:
                original = retained / 'sources' / source['captureFile']
                assert digest(original) == source['sha256'], 'Initial capture changed'
                current = next(r for r in records if r['id'].lower() == source['id'].lower())
                saved = root / 'Documents' / current['fileName']
                if source['name'] != profile['sourceName']:
                    assert digest(saved) == source['sha256'], 'OCR changed an unrelated document'
                    continue
                assert source['sha256'] == profile['sourceSHA256'], 'OCR did not use the pinned original scanned PDF'
                before, after = PdfReader(original, strict=True), PdfReader(saved, strict=True)
                words = profile['expectedPageWords']
                assert len(before.pages) == len(after.pages) == len(words), 'OCR changed the expected page count'
                assert any(not normalized_text(p) for p in before.pages), 'OCR source was not image based'
                for index, (a, b, word) in enumerate(zip(before.pages, after.pages, words)):
                    assert word.casefold() in normalized_text(b).casefold(), f'OCR search layer is missing the expected word on page {index + 1}'
                    if normalized_text(a): assert normalized_text(a) in normalized_text(b), 'OCR removed existing native text'
                    left, right = page_signature(a), page_signature(b)
                    for key in ['text', 'images']: left.pop(key); right.pop(key)
                    assert left == right, 'OCR changed page geometry or annotations'
                    assert_same_render(original.read_bytes(), index, saved, index, retained / 'renders')
                checks.append(dict(pageCount=len(after.pages), expectedPageWords=words, everyPageWordVerified=True,
                    pinnedOriginalScan=True, existingNativeTextPreserved=True, renderedPixelsIdentical=True,
                    unchangedDocumentIdentity=True, otherDocumentsUnchanged=True))
            assert checks, 'OCR source was not audited'
        if kind == 'formAdded':
            from collections import Counter
            from AuditMergeOutputs import page_signature
            assert len(records) == len(proof['sources']), 'Adding a field duplicated the working document'
            for source in proof['sources']:
                original = retained / 'sources' / source['captureFile']
                assert digest(original) == source['sha256'], 'Initial capture changed'
                current = next(r for r in records if r['id'].lower() == source['id'].lower())
                saved = root / 'Documents' / current['fileName']
                if source['name'] != 'Project handoff':
                    assert digest(saved) == source['sha256'], 'Adding a field changed an unrelated document'
                    continue
                before, after = PdfReader(original, strict=True), PdfReader(saved, strict=True)
                old_fields, new_fields = terminal_fields(before), terminal_fields(after)
                expected = profile['fieldName']
                assert expected not in old_fields, 'New field was already present in the seed'
                assert new_fields.pop(expected, None) == ('/Tx', ''), 'New named text field is missing or has the wrong type/value'
                assert old_fields == new_fields, 'Adding a field changed the existing field tree or values'
                catalog_fields = after.get_fields() or {}
                assert set(old_fields) | {expected} <= set(catalog_fields), 'Form fields are disconnected from the AcroForm catalog'
                assert not int(catalog_fields[expected].get('/Ff', 0)) & 1, 'New text field is read only'
                assert len(before.pages) == len(after.pages), 'Adding a field lost a page'
                added_count = 0
                for a, b in zip(before.pages, after.pages):
                    left, right = page_signature(a), page_signature(b)
                    old, new = left.pop('annotations'), right.pop('annotations')
                    assert left == right, 'Adding a field changed original page content or geometry'
                    assert not (Counter(old) - Counter(new)), 'Adding a field removed an existing annotation'
                    added = list((Counter(new) - Counter(old)).elements()); added_count += len(added)
                    for row in added:
                        assert row[0] == '/Widget' and len(row[2]) == 4, 'New form field is not an interactive widget'
                        x0, y0, x1, y1 = row[2]
                        assert b.mediabox.left <= x0 < x1 <= b.mediabox.right and b.mediabox.bottom <= y0 < y1 <= b.mediabox.top, 'New form widget lies outside its page'
                assert added_count == 1, 'Expected exactly one new widget'
                checks.append(dict(pageCount=len(after.pages), newFieldName=expected, newTextFieldPresent=True,
                    existingFieldsPreserved=True, originalContentPreserved=True, widgetInsidePage=True,
                    fieldTreeConnected=True, writableNewField=True,
                    unchangedDocumentIdentity=True, otherDocumentsUnchanged=True,
                    limitation='Verifies field creation and preservation; native widget typing/restart is a separate uncovered journey.'))
            assert checks, 'Form source was not audited'
        if kind == 'redaction':
            from pypdf.generic import IndirectObject
            from AuditMergeOutputs import image_fingerprints
            target_name = profile['sourceName']; terms = profile['removedTerms']
            assert len(records) == len(proof['sources']), 'Redaction changed document count'
            for source in proof['sources']:
                original = retained / 'sources' / source['captureFile']
                assert digest(original) == source['sha256'], 'Initial capture changed'
                current = next(r for r in records if r['id'].lower() == source['id'].lower())
                saved = root / 'Documents' / current['fileName']
                if source['name'] != target_name:
                    assert digest(saved) == source['sha256'], 'Redaction changed an unrelated document'
                    continue
                before, after = PdfReader(original, strict=True), PdfReader(saved, strict=True)
                original_text = '\n'.join(p.extract_text() or '' for p in before.pages)
                assert terms and all(term in original_text for term in terms), 'Sensitive fixture terms were never present'
                assert len(before.pages) == len(after.pages) > 0, 'Redaction lost pages'
                assert not after.get_fields(), 'Redaction retained interactive form fields'
                assert not after.attachments, 'Redaction retained embedded files'
                for a, b in zip(before.pages, after.pages):
                    assert not (b.extract_text() or '').strip(), 'Redaction retained hidden searchable source text'
                    assert not b.get('/Annots'), 'Redaction retained editable annotations'
                    assert image_fingerprints(b), 'Redaction did not preserve a rendered page image'
                    expected = [float(a.cropbox.width), float(a.cropbox.height)]
                    if a.rotation % 180: expected.reverse()
                    assert all(abs(left-right) < .01 for left, right in zip(expected, [float(b.mediabox.width), float(b.mediabox.height)])), 'Redaction changed page geometry'
                for generation, objects in after.xref.items():
                    for number in objects:
                        if number == 0: continue
                        obj = after.get_object(IndirectObject(number, generation, after))
                        payload = obj.get_data() if hasattr(obj, 'get_data') else str(obj).encode('utf-8')
                        assert all(term.encode('utf-8').lower() not in payload.lower() and term.encode('utf-16-be') not in payload
                            for term in terms), 'Redaction retained sensitive text in an object or decoded stream'
                checks.append(dict(pageCount=len(after.pages), unchangedDocumentIdentity=True, otherDocumentsUnchanged=True,
                    sensitiveTermsOriginallyPresent=True, hiddenTextAbsent=True, annotationsFormsAttachmentsRemoved=True,
                    pageImagesPresent=True, pageGeometryPreserved=True, removedTerms=terms,
                    limitation='Validates hidden payload removal and page structure; visual region fidelity requires separate image comparison.'))
            assert checks, 'Redacted source was not audited'
        if kind in {'editedContent', 'editedLink'}:
            from collections import Counter
            from AuditMergeOutputs import page_signature, annotation_signature, assert_same_render
            assert len(records) == len(proof['sources']), 'Editing published an unexpected duplicate document'
            changed = 0
            for source in proof['sources']:
                original = retained / 'sources' / source['captureFile']
                assert digest(original) == source['sha256'], 'Initial capture changed'
                current = next(r for r in records if r['id'].lower() == source['id'].lower())
                saved = root / 'Documents' / current['fileName']
                if source['name'] != 'Project handoff':
                    assert digest(saved) == source['sha256'], 'Editing changed an unrelated document'
                    continue
                before, after = PdfReader(original, strict=True), PdfReader(saved, strict=True)
                assert len(before.pages) == len(after.pages), 'Editing changed page count'
                for index, (a, b) in enumerate(zip(before.pages, after.pages)):
                    left, right = page_signature(a), page_signature(b)
                    old, new = left.pop('annotations'), right.pop('annotations')
                    assert left == right, 'Editing changed existing page text, images or geometry'
                    if kind == 'editedContent':
                        assert not (Counter(old) - Counter(new)), 'Adding content removed an existing annotation'
                        added = list((Counter(new) - Counter(old)).elements())
                        if added:
                            assert len(added) == 1 and added[0][0] == '/FreeText' and added[0][1] == 'Automation content', 'Expected added text is missing or altered'
                            try: assert_same_render(original.read_bytes(), index, saved, index, retained / 'renders')
                            except AssertionError as error:
                                assert 'rendered pixels changed' in str(error), str(error)
                            else: raise AssertionError('Added text has no visible rendered appearance')
                            changed += 1
                        else: assert_same_render(original.read_bytes(), index, saved, index, retained / 'renders')
                    else:
                        without_labels = lambda rows: sorted((r[0], tuple(round(v, 2) for v in r[2]), r[3], r[4]) for r in rows)
                        assert without_labels(old) == without_labels(new), 'Link edit changed targets, bounds or annotation types'
                        old_links = [r for r in old if r[0] == '/Link']; new_links = [r for r in new if r[0] == '/Link']
                        assert Counter(r for r in old if r[0] != '/Link') == Counter(r for r in new if r[0] != '/Link'), 'Link edit changed an unrelated annotation'
                        differences = list((Counter(new_links) - Counter(old_links)).elements())
                        for row in differences:
                            # A tap places the caret at its actual position; at
                            # large text it can be inside the original label.
                            # Require precisely the typed insertion while
                            # preserving every original character and target.
                            candidates = [old for old in old_links if old[2:] == row[2:]]
                            assert ' Automation' in row[1] and any(row[1].replace(' Automation', '', 1) == old[1]
                                for old in candidates), 'Edited link label was not saved'
                            changed += 1
                        assert_same_render(original.read_bytes(), index, saved, index, retained / 'renders')
                checks.append(dict(pageCount=len(after.pages), unchangedDocumentIdentity=True, otherDocumentsUnchanged=True,
                    existingPageContentPreserved=True, mutationVerified=kind, changedItems=changed, renderedOutputVerified=True))
            assert changed == 1, 'Expected exactly one persisted edit'
        if kind == 'extraction':
            from AuditMergeOutputs import page_signature, assert_same_render
            originals = {source['id'].lower(): source for source in proof['sources']}
            assert len(records) == len(originals) + 1, 'Extraction did not publish exactly one output'
            for source in originals.values():
                current = next(r for r in records if r['id'].lower() == source['id'].lower())
                assert digest(root / 'Documents' / current['fileName']) == source['sha256'], 'Extraction changed an original PDF'
            outputs = [r for r in records if r['id'].lower() not in originals]
            assert len(outputs) == 1 and outputs[0]['displayName'] == 'Project handoff - extracted pages', 'Unexpected extraction output'
            source = next(s for s in originals.values() if s['name'] == 'Project handoff')
            original = retained / 'sources' / source['captureFile']
            assert digest(original) == source['sha256'], 'Initial capture changed'
            saved = root / 'Documents' / outputs[0]['fileName']
            before, after = PdfReader(original, strict=True), PdfReader(saved, strict=True)
            selection = case_options.get('pageIndices', profile.get('pageIndices', [0]))
            indices = list(range(len(before.pages))) if selection == 'all' else selection
            assert indices and len(after.pages) == len(indices), 'Extraction page count differs from the actual selection'
            for index, expected in enumerate(indices):
                assert page_signature(before.pages[expected]) == page_signature(after.pages[index]), 'Extraction changed page order, text, geometry or annotations'
                assert_same_render(original.read_bytes(), expected, saved, index, retained / 'renders')
            checks.append(dict(selectedPages=indices, pageCount=len(after.pages), originalSourcesUnchanged=True,
                contentPreserved=True, renderedPixelsIdentical=True, selectionOrderPreserved=True))
        if kind in {'unchanged', 'compressionLossless', 'protection'}:
            assert len(records) == len(proof['sources']), 'No-benefit operation published an unexpected copy'
            for source in proof['sources']:
                original = path.parent / 'sources' / source['captureFile']
                assert digest(original) == source['sha256'], 'Initial capture changed'
                current = next(r for r in records if r['id'].lower() == source['id'].lower())
                saved = root / 'Documents' / current['fileName']
                if kind == 'protection' and source['name'] == 'Project handoff':
                    from AuditMergeOutputs import page_signature, assert_same_render
                    before, after = PdfReader(str(original), strict=True), PdfReader(str(saved), strict=True)
                    password = case_options.get('password', profile.get('password'))
                    assert after.is_encrypted, 'Protection did not encrypt the actual file'
                    assert after.decrypt('wrong-quality-password') == 0, 'Protected output accepts an incorrect password'
                    assert password and after.decrypt(password) != 0, 'Protected output rejects the intended password'
                    assert terminal_fields(before) == terminal_fields(after), 'Protection changed interactive form values or field structure'
                    assert len(before.pages) == len(after.pages), 'Protection lost a page'
                    for index, (a, b) in enumerate(zip(before.pages, after.pages)):
                        left, right = page_signature(a), page_signature(b)
                        left.pop('images'); right.pop('images')
                        assert left == right, 'Protection changed text, geometry or annotations'
                        assert_same_render(original.read_bytes(), index, saved, index, retained / 'renders', output_password=password)
                    checks.append(dict(name=source['name'], protectionEnabled=True, wrongPasswordRejected=True,
                        correctPasswordAccepted=True, contentPreserved=True, renderedPixelsIdentical=True,
                        formFieldsPreserved=True, pageCount=len(after.pages)))
                    continue
                if kind == 'compressionLossless' and source['name'] == 'Quality nasa-webb':
                    from AuditMergeOutputs import page_signature, assert_same_render
                    before, after = PdfReader(str(original), strict=True), PdfReader(str(saved), strict=True)
                    assert saved.stat().st_size < original.stat().st_size, 'Positive compression did not make the actual file smaller'
                    assert len(before.pages) == len(after.pages), 'Compression lost a page'
                    for index, (a, b) in enumerate(zip(before.pages, after.pages)):
                        left, right = page_signature(a), page_signature(b)
                        left.pop('images'); right.pop('images')
                        assert left == right, 'Lossless compression changed text, geometry or annotations'
                        assert_same_render(original.read_bytes(), index, saved, index, retained / 'renders')
                    checks.append(dict(name=source['name'], strictlySmaller=True, sourceBytes=original.stat().st_size,
                        outputBytes=saved.stat().st_size, pageCount=len(after.pages), contentPreserved=True, renderedPixelsIdentical=True))
                    continue
                assert digest(saved) == source['sha256'], 'No-benefit operation changed original PDF bytes'
                reader = PdfReader(str(saved), strict=True)
                assert len(reader.pages) > 0
                checks.append(dict(name=source['name'], bytesUnchanged=True, readablePages=len(reader.pages)))
        if kind == 'protection':
            assert any(row.get('protectionEnabled') is True for row in checks), 'Protected source was not audited'
        if kind == 'compressionLossless':
            assert any(row.get('strictlySmaller') is True for row in checks), 'Positive compression source was not audited'
        cases.append(dict(testID=test_id, feature=profile['feature'], status='PASSED' if kind != 'notConfigured' else 'NOT_CONFIGURED',
                          auditKind=kind, checks=checks, files=files, contentSize=proof['contentSize'], createdAt=proof['createdAt']))
    assert cases, 'No executed quality journeys'
    return dict(status='PASSED', cases=cases)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', type=Path, required=True)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--profiles', type=Path, required=True)
    args = parser.parse_args()
    summary = json.loads((args.run / 'summary.json').read_text())
    tree = json.loads((args.run / 'test-tree.json').read_text())
    import sys
    sys.path.insert(0, str(Path(__file__).parent))
    from CheckTestQuality import test_cases
    ids = [case['nodeIdentifier'] for case in test_cases(tree) if case['result'] == 'Passed']
    try:
        report = audit(args.container, args.run / 'saved-pdf-evidence', summary, ids,
                       json.loads(args.profiles.read_text())['features'])
    except Exception as error:
        report = dict(status='FAILED', error=str(error))
    (args.run / 'quality-audit.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print('Saved UI output audit:', report['status'])
    raise SystemExit(0 if report['status'] == 'PASSED' else 1)
