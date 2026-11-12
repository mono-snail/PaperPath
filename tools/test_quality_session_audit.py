"""Independent controls for UI session snapshots and no-benefit file results."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import uuid
from pypdf import PdfReader, PdfWriter
from AuditQualitySession import audit


class QualitySessionAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.case_id = str(uuid.uuid4())
        self.store = self.root / 'Documents/DocumentLifecycleUITestFixtures' / str(uuid.uuid4())
        self.capture = self.root / 'Documents/QualityEvidence' / self.case_id
        (self.store / 'Documents').mkdir(parents=True)
        (self.capture / 'sources').mkdir(parents=True)
        pdf = PdfWriter(); pdf.add_blank_page(width=612, height=792); pdf.write(self.store / 'Documents/source.pdf')
        data = (self.store / 'Documents/source.pdf').read_bytes()
        (self.capture / 'sources/original.pdf').write_bytes(data)
        (self.store / 'library.json').write_text(json.dumps([dict(id='record', displayName='Original', fileName='source.pdf')]))
        self.proof = dict(testID='testRecorded', feature='quickTasks.compressPDF', createdAt=15,
            storeRoot=str(self.store), caseID=self.case_id, contentSize='UICTContentSizeCategoryL',
            sources=[dict(id='record', name='Original', fileName='source.pdf', captureFile='original.pdf',
                          sha256=hashlib.sha256(data).hexdigest())])
        self.profiles = {'quickTasks.compressPDF': dict(standard='testRecorded', largeText='testRecordedLarge', audit='unchanged')}
        self.save()

    def save(self): (self.capture / 'initial.json').write_text(json.dumps(self.proof))
    def check(self, method='testRecorded'):
        return audit(self.root, self.root / 'retained', dict(startTime=10, finishTime=20),
                     ['PaperPathUITests/' + method + '()'], self.profiles)

    def test_correct_unchanged_output_passes(self):
        self.assertEqual(self.check()['cases'][0]['status'], 'PASSED')
        self.profiles['quickTasks.compressPDF']['audit'] = 'compressionLossless'
        original = self.capture / 'sources/original.pdf'
        original.write_bytes(original.read_bytes() + b'\n%' + b'padding' * 1000 + b'\n')
        self.proof['sources'][0]['name'] = 'Quality nasa-webb'
        self.proof['sources'][0]['sha256'] = hashlib.sha256(original.read_bytes()).hexdigest()
        self.save()
        self.assertTrue(self.check()['cases'][0]['checks'][0]['strictlySmaller'])

    def test_changed_saved_pdf_is_rejected(self):
        pdf = PdfWriter(); pdf.add_blank_page(width=500, height=792); pdf.write(self.store / 'Documents/source.pdf')
        with self.assertRaisesRegex(AssertionError, 'changed original'): self.check()
        self.profiles['quickTasks.compressPDF']['audit'] = 'compressionLossless'
        original = self.capture / 'sources/original.pdf'
        original.write_bytes(original.read_bytes() + b'\n%' + b'padding' * 1000 + b'\n')
        self.proof['sources'][0]['name'] = 'Quality nasa-webb'
        self.proof['sources'][0]['sha256'] = hashlib.sha256(original.read_bytes()).hexdigest()
        self.save()
        with self.assertRaisesRegex(AssertionError, 'changed text, geometry'): self.check()


    def test_unexpected_duplicate_output_is_rejected(self):
        rows = json.loads((self.store / 'library.json').read_text()); rows.append(rows[0])
        (self.store / 'library.json').write_text(json.dumps(rows))
        with self.assertRaisesRegex(AssertionError, 'unexpected copy'): self.check()

    def test_false_large_text_launch_is_rejected(self):
        self.proof['testID'] = 'testRecordedLarge'; self.save()
        with self.assertRaisesRegex(AssertionError, 'Large text launch was overridden'): self.check('testRecordedLarge')

    def test_old_snapshot_is_not_reused(self):
        self.proof['createdAt'] = 0; self.save()
        with self.assertRaisesRegex(AssertionError, 'Missing or ambiguous'): self.check()

    def test_moved_app_container_preserves_case_identity(self):
        import shutil
        with tempfile.TemporaryDirectory() as temporary:
            moved = Path(temporary) / 'new-container'
            shutil.copytree(self.root, moved)
            report = audit(moved, moved / 'retained', dict(startTime=10, finishTime=20),
                ['PaperPathUITests/testRecorded()'], self.profiles)
            self.assertEqual(report['cases'][0]['status'], 'PASSED')

    def test_capture_cannot_escape_store_or_case_directory(self):
        self.proof['storeRoot'] = str(self.root / 'Library/private'); self.save()
        with self.assertRaisesRegex(AssertionError, 'escaped isolated test store'): self.check()
        self.proof['storeRoot'] = str(self.store); self.proof['caseID'] = '../escape'; self.save()
        with self.assertRaisesRegex(AssertionError, 'Invalid quality case identity'): self.check()

    def configure_protection(self, encrypted=True):
        self.profiles = {'quickTasks.protectPDF': dict(standard='testRecorded', largeText='testRecordedLarge',
                         audit='protection', password='Quality-2026')}
        self.proof['feature'] = 'quickTasks.protectPDF'
        self.proof['sources'][0]['name'] = 'Project handoff'
        self.save()
        if encrypted:
            writer = PdfWriter()
            writer.add_page(PdfReader(self.capture / 'sources/original.pdf').pages[0])
            writer.encrypt('Quality-2026', algorithm='AES-256')
            writer.write(self.store / 'Documents/source.pdf')

    def test_protected_output_requires_correct_password(self):
        self.configure_protection()
        self.assertTrue(self.check()['cases'][0]['checks'][0]['wrongPasswordRejected'])
        self.profiles['quickTasks.protectPDF']['password'] = 'not-the-password'
        with self.assertRaisesRegex(AssertionError, 'rejects the intended password'): self.check()

    def test_missing_encryption_is_rejected(self):
        self.configure_protection(encrypted=False)
        with self.assertRaisesRegex(AssertionError, 'did not encrypt'): self.check()

    def widget_only_protection(self, remove=False):
        from pypdf.generic import DictionaryObject, NameObject, TextStringObject, ArrayObject, NumberObject
        writer = PdfWriter(); page = writer.add_blank_page(width=612, height=792)
        widget = DictionaryObject({NameObject('/Subtype'): NameObject('/Widget'), NameObject('/FT'): NameObject('/Tx'),
            NameObject('/T'): TextStringObject('Recipient'), NameObject('/V'): TextStringObject(''),
            NameObject('/Rect'): ArrayObject([NumberObject(v) for v in [10, 10, 90, 30]])})
        page[NameObject('/Annots')] = ArrayObject([writer._add_object(widget)])
        original = self.capture / 'sources/original.pdf'; writer.write(original)
        self.proof['sources'][0]['sha256'] = hashlib.sha256(original.read_bytes()).hexdigest()
        self.configure_protection(encrypted=False)
        writer = PdfWriter(); writer.add_page(PdfReader(original).pages[0])
        refs = writer.pages[0]['/Annots']
        if remove: writer.pages[0][NameObject('/Annots')] = ArrayObject()
        else: writer._root_object[NameObject('/AcroForm')] = DictionaryObject({NameObject('/Fields'): refs})
        writer.encrypt('Quality-2026', algorithm='AES-256'); writer.write(self.store / 'Documents/source.pdf')

    def test_widget_only_form_catalog_repair_preserves_fields(self):
        self.widget_only_protection()
        self.assertTrue(self.check()['cases'][0]['checks'][0]['formFieldsPreserved'])

    def test_removed_protected_form_field_is_rejected(self):
        self.widget_only_protection(remove=True)
        with self.assertRaisesRegex(AssertionError, 'form values or field structure'): self.check()

    def configure_extraction(self, output_index=1):
        self.profiles = {'quickTasks.splitPDF': dict(standard='testRecorded', largeText='testRecordedLarge',
                         audit='extraction', pageIndices=[1])}
        self.proof['feature'] = 'quickTasks.splitPDF'; self.proof['sources'][0]['name'] = 'Project handoff'
        writer = PdfWriter(); writer.add_blank_page(width=612, height=792); writer.add_blank_page(width=500, height=700)
        original = self.capture / 'sources/original.pdf'; writer.write(original)
        (self.store / 'Documents/source.pdf').write_bytes(original.read_bytes())
        self.proof['sources'][0]['sha256'] = hashlib.sha256(original.read_bytes()).hexdigest(); self.save()
        writer = PdfWriter(); writer.add_page(PdfReader(original).pages[output_index]); writer.write(self.store / 'Documents/result.pdf')
        rows = json.loads((self.store / 'library.json').read_text())
        rows.append(dict(id='result', displayName='Project handoff - extracted pages', fileName='result.pdf'))
        (self.store / 'library.json').write_text(json.dumps(rows))

    def test_selected_extracted_page_passes(self):
        self.configure_extraction()
        self.assertEqual(self.check()['cases'][0]['checks'][0]['selectedPages'], [1])

    def test_wrong_extracted_page_is_rejected(self):
        self.configure_extraction(output_index=0)
        with self.assertRaisesRegex(AssertionError, 'page order, text, geometry'): self.check()

    def test_extraction_cannot_overwrite_original(self):
        self.configure_extraction()
        (self.store / 'Documents/source.pdf').write_bytes((self.store / 'Documents/result.pdf').read_bytes())
        with self.assertRaisesRegex(AssertionError, 'changed an original'): self.check()

    def configure_link_edit(self, target='https://example.com/guide', label='Delivery guide Automation'):
        from pypdf.generic import DictionaryObject, NameObject, TextStringObject, ArrayObject, NumberObject
        writer = PdfWriter(); page = writer.add_blank_page(width=612, height=792)
        link = DictionaryObject({NameObject('/Subtype'): NameObject('/Link'), NameObject('/Contents'): TextStringObject('Delivery guide'),
            NameObject('/Rect'): ArrayObject([NumberObject(v) for v in [10, 10, 90, 30]]),
            NameObject('/A'): DictionaryObject({NameObject('/S'): NameObject('/URI'), NameObject('/URI'): TextStringObject('https://example.com/guide')})})
        page[NameObject('/Annots')] = ArrayObject([writer._add_object(link)])
        original = self.capture / 'sources/original.pdf'; writer.write(original)
        self.proof['feature'] = 'documentTools.links'; self.proof['sources'][0]['name'] = 'Project handoff'
        self.proof['sources'][0]['sha256'] = hashlib.sha256(original.read_bytes()).hexdigest(); self.save()
        self.profiles = {'documentTools.links': dict(standard='testRecorded', largeText='testRecordedLarge', audit='editedLink')}
        link[NameObject('/Contents')] = TextStringObject(label)
        link['/A'][NameObject('/URI')] = TextStringObject(target)
        writer.write(self.store / 'Documents/source.pdf')

    def test_saved_link_label_preserves_target(self):
        self.configure_link_edit()
        self.assertEqual(self.check()['cases'][0]['checks'][0]['changedItems'], 1)
        self.configure_link_edit(label='Delivery Automation guide')
        self.assertEqual(self.check()['cases'][0]['checks'][0]['changedItems'], 1)

    def test_saved_link_cannot_change_target_silently(self):
        self.configure_link_edit(target='https://example.com/wrong')
        with self.assertRaisesRegex(AssertionError, 'changed targets'): self.check()

    def test_missing_added_text_is_rejected(self):
        self.proof['feature'] = 'documentTools.content'; self.proof['sources'][0]['name'] = 'Project handoff'; self.save()
        self.profiles = {'documentTools.content': dict(standard='testRecorded', largeText='testRecordedLarge', audit='editedContent')}
        with self.assertRaisesRegex(AssertionError, 'exactly one persisted edit'): self.check()

    def configure_redaction(self, hidden=False, orphan=False):
        from pypdf.generic import DictionaryObject, NameObject, DecodedStreamObject, NumberObject
        from PIL import Image, ImageDraw
        writer = PdfWriter(); page = writer.add_blank_page(width=612, height=792)
        font = DictionaryObject({NameObject('/Type'): NameObject('/Font'), NameObject('/Subtype'): NameObject('/Type1'),
            NameObject('/BaseFont'): NameObject('/Helvetica')})
        page[NameObject('/Resources')] = DictionaryObject({NameObject('/Font'): DictionaryObject({NameObject('/F1'): writer._add_object(font)})})
        stream = DecodedStreamObject(); stream.set_data(b'BT /F1 12 Tf 50 700 Td (billing@example.com) Tj ET')
        page[NameObject('/Contents')] = writer._add_object(stream)
        original = self.capture / 'sources/original.pdf'; writer.write(original)
        self.proof['feature'] = 'workflows.privacyScan'; self.proof['sources'][0]['name'] = 'August invoice'
        self.proof['sources'][0]['sha256'] = hashlib.sha256(original.read_bytes()).hexdigest(); self.save()
        self.profiles = {'workflows.privacyScan': dict(standard='testRecorded', largeText='testRecordedLarge', audit='redaction',
            sourceName='August invoice', removedTerms=['billing@example.com'])}
        writer = PdfWriter(); page = writer.add_blank_page(width=612, height=792)
        image = Image.new('RGB', (100, 100), 'white'); ImageDraw.Draw(image).rectangle((8, 8, 80, 15), fill='black')
        image_stream = DecodedStreamObject(); image_stream.set_data(image.tobytes())
        image_stream.update({NameObject('/Type'): NameObject('/XObject'), NameObject('/Subtype'): NameObject('/Image'),
            NameObject('/Width'): NumberObject(100), NameObject('/Height'): NumberObject(100),
            NameObject('/ColorSpace'): NameObject('/DeviceRGB'), NameObject('/BitsPerComponent'): NumberObject(8)})
        page[NameObject('/Resources')] = DictionaryObject({NameObject('/XObject'): DictionaryObject({NameObject('/Im0'): writer._add_object(image_stream)})})
        content = DecodedStreamObject(); content.set_data(b'q 612 0 0 792 0 0 cm /Im0 Do Q')
        page[NameObject('/Contents')] = writer._add_object(content)
        if hidden:
            page['/Resources'][NameObject('/Font')] = DictionaryObject({NameObject('/F1'): writer._add_object(font)})
            content.set_data(content.get_data() + b' BT /F1 12 Tf 3 Tr 50 700 Td (billing@example.com) Tj ET')
        if orphan:
            secret = DecodedStreamObject(); secret.set_data(b'old unused stream billing@example.com'); writer._add_object(secret)
        writer.write(self.store / 'Documents/source.pdf')

    def test_redaction_removes_hidden_payload(self):
        self.configure_redaction()
        self.assertTrue(self.check()['cases'][0]['checks'][0]['hiddenTextAbsent'])

    def test_black_overlay_cannot_hide_searchable_text(self):
        self.configure_redaction(hidden=True)
        with self.assertRaisesRegex(AssertionError, 'hidden searchable source text'): self.check()

    def test_redaction_cannot_leave_unused_sensitive_stream(self):
        self.configure_redaction(orphan=True)
        with self.assertRaisesRegex(AssertionError, 'object or decoded stream'): self.check()

    def configure_added_form(self, omit=False, lose_original=False):
        from pypdf.generic import DictionaryObject, NameObject, TextStringObject, ArrayObject, NumberObject
        self.widget_only_protection()
        self.proof['feature'] = 'documentTools.fillForm'; self.save()
        self.profiles = {'documentTools.fillForm': dict(standard='testRecorded', largeText='testRecordedLarge',
            audit='formAdded', fieldName='Automation field')}
        writer = PdfWriter(); page = writer.add_page(PdfReader(self.capture / 'sources/original.pdf').pages[0])
        annotations = ArrayObject([] if lose_original else list(page['/Annots']))
        if not omit:
            widget = DictionaryObject({NameObject('/Subtype'): NameObject('/Widget'), NameObject('/FT'): NameObject('/Tx'),
                NameObject('/T'): TextStringObject('Automation field'), NameObject('/V'): TextStringObject(''),
                NameObject('/Rect'): ArrayObject([NumberObject(v) for v in [100, 100, 250, 140]])})
            annotations.append(writer._add_object(widget))
        page[NameObject('/Annots')] = annotations
        writer._root_object[NameObject('/AcroForm')] = DictionaryObject({NameObject('/Fields'): annotations})
        writer.write(self.store / 'Documents/source.pdf')

    def test_added_form_field_preserves_existing_tree(self):
        self.configure_added_form()
        self.assertTrue(self.check()['cases'][0]['checks'][0]['existingFieldsPreserved'])

    def test_missing_added_form_field_is_rejected(self):
        self.configure_added_form(omit=True)
        with self.assertRaisesRegex(AssertionError, 'New named text field'): self.check()

    def test_adding_field_cannot_drop_original_fields(self):
        self.configure_added_form(lose_original=True)
        with self.assertRaisesRegex(AssertionError, 'existing field tree'): self.check()

    def test_new_widget_cannot_be_disconnected_from_form_catalog(self):
        from pypdf.generic import NameObject
        self.configure_added_form()
        path = self.store / 'Documents/source.pdf'
        writer = PdfWriter(clone_from=path); writer._root_object.pop(NameObject('/AcroForm')); writer.write(path)
        with self.assertRaisesRegex(AssertionError, 'disconnected from the AcroForm'): self.check()

    def configure_saved_ocr(self, skip_second=False, visible=False):
        from pypdf.generic import DictionaryObject, NameObject, NumberObject, DecodedStreamObject, ArrayObject
        from PIL import Image, ImageDraw
        words = ['Watson', 'England']; writer = PdfWriter()
        for word in words:
            page = writer.add_blank_page(width=612, height=792)
            image = Image.new('RGB', (240, 120), 'white'); ImageDraw.Draw(image).text((20, 40), word, fill='black')
            bitmap = DecodedStreamObject(); bitmap.set_data(image.tobytes())
            bitmap.update({NameObject('/Type'): NameObject('/XObject'), NameObject('/Subtype'): NameObject('/Image'),
                NameObject('/Width'): NumberObject(240), NameObject('/Height'): NumberObject(120),
                NameObject('/ColorSpace'): NameObject('/DeviceRGB'), NameObject('/BitsPerComponent'): NumberObject(8)})
            page[NameObject('/Resources')] = DictionaryObject({NameObject('/XObject'): DictionaryObject({NameObject('/Im0'): writer._add_object(bitmap)})})
            stream = DecodedStreamObject(); stream.set_data(b'q 612 0 0 792 0 0 cm /Im0 Do Q')
            page[NameObject('/Contents')] = writer._add_object(stream)
        original = self.capture / 'sources/original.pdf'; writer.write(original)
        source_hash = hashlib.sha256(original.read_bytes()).hexdigest()
        self.proof['feature'] = 'documentTools.recognize'; self.proof['sources'][0].update(name='Quality scan', sha256=source_hash); self.save()
        self.profiles = {'documentTools.recognize': dict(standard='testRecorded', largeText='testRecordedLarge', audit='searchableOCR',
            sourceName='Quality scan', sourceSHA256=source_hash, expectedPageWords=words)}
        writer = PdfWriter(clone_from=original)
        for index, (page, word) in enumerate(zip(writer.pages, words)):
            if skip_second and index == 1: continue
            font = DictionaryObject({NameObject('/Type'): NameObject('/Font'), NameObject('/Subtype'): NameObject('/Type1'), NameObject('/BaseFont'): NameObject('/Helvetica')})
            page['/Resources'][NameObject('/Font')] = DictionaryObject({NameObject('/F1'): writer._add_object(font)})
            text = DecodedStreamObject(); text.set_data(f'BT /F1 12 Tf {0 if visible else 3} Tr 50 700 Td ({word}) Tj ET'.encode())
            page[NameObject('/Contents')] = ArrayObject([page.raw_get('/Contents'), writer._add_object(text)])
        writer.write(self.store / 'Documents/source.pdf')

    def test_saved_ocr_layer_preserves_every_page(self):
        self.configure_saved_ocr()
        self.assertTrue(self.check()['cases'][0]['checks'][0]['everyPageWordVerified'])

    def test_ocr_cannot_skip_second_page(self):
        self.configure_saved_ocr(skip_second=True)
        with self.assertRaisesRegex(AssertionError, 'expected word on page 2'): self.check()

    def test_ocr_text_must_remain_invisible(self):
        self.configure_saved_ocr(visible=True)
        with self.assertRaisesRegex(AssertionError, 'rendered pixels changed'): self.check()

    def test_ocr_requires_the_pinned_original_scan(self):
        self.configure_saved_ocr(); self.profiles['documentTools.recognize']['sourceSHA256'] = '0' * 64
        with self.assertRaisesRegex(AssertionError, 'pinned original scanned PDF'): self.check()

    def configure_saved_ink(self, missing=False, hidden=False):
        from pypdf.generic import DictionaryObject, NameObject, TextStringObject, ArrayObject, NumberObject
        self.proof['feature'] = 'documentTools.sign'; self.proof['sources'][0]['name'] = 'Project handoff'; self.save()
        self.profiles = {'documentTools.sign': dict(standard='testRecorded', largeText='testRecordedLarge', audit='addedAnnotation',
            annotationTypes=['/Ink'], annotationContents='Signature', annotationCount=1)}
        writer = PdfWriter(clone_from=self.capture / 'sources/original.pdf')
        if not missing:
            ink = DictionaryObject({NameObject('/Subtype'): NameObject('/Ink'), NameObject('/Contents'): TextStringObject('Signature'),
                NameObject('/Rect'): ArrayObject([NumberObject(v) for v in [100, 100, 200, 140]]),
                NameObject('/InkList'): ArrayObject([writer._add_object(ArrayObject([NumberObject(v) for v in [100, 100, 200, 140]]))]),
                NameObject('/C'): ArrayObject([NumberObject(0)] * 3), NameObject('/F'): NumberObject(3 if hidden else 4),
                NameObject('/BS'): DictionaryObject({NameObject('/W'): NumberObject(2)})})
            writer.pages[0][NameObject('/Annots')] = ArrayObject([writer._add_object(ink)])
        writer.write(self.store / 'Documents/source.pdf')

    def test_saved_signature_has_real_visible_strokes(self):
        self.configure_saved_ink()
        self.assertTrue(self.check()['cases'][0]['checks'][0]['visibleRenderingVerified'])

    def test_missing_signature_is_rejected(self):
        self.configure_saved_ink(missing=True)
        with self.assertRaisesRegex(AssertionError, 'number of saved annotations'): self.check()

    def test_hidden_signature_is_rejected(self):
        self.configure_saved_ink(hidden=True)
        with self.assertRaisesRegex(AssertionError, 'not visible'): self.check()

    def test_saved_ink_cannot_have_empty_indirect_path(self):
        from pypdf.generic import NameObject, ArrayObject
        self.configure_saved_ink(); path = self.store / 'Documents/source.pdf'
        writer = PdfWriter(clone_from=path)
        writer.pages[0]['/Annots'][0].get_object()[NameObject('/InkList')] = ArrayObject([writer._add_object(ArrayObject())])
        writer.write(path)
        with self.assertRaisesRegex(AssertionError, 'strokes are empty or invalid'): self.check()

    def configure_word_export(self, lose_number=False, bad_receipt=False, missing_main=False):
        import zipfile
        from pypdf.generic import DictionaryObject, NameObject, DecodedStreamObject
        writer = PdfWriter(); page = writer.add_blank_page(width=612, height=792)
        font = DictionaryObject({NameObject('/Type'): NameObject('/Font'), NameObject('/Subtype'): NameObject('/Type1'), NameObject('/BaseFont'): NameObject('/Helvetica')})
        page[NameObject('/Resources')] = DictionaryObject({NameObject('/Font'): DictionaryObject({NameObject('/F1'): writer._add_object(font)})})
        stream = DecodedStreamObject(); stream.set_data(b'BT /F1 12 Tf 50 700 Td (Project handoff Decision record 1280) Tj ET')
        page[NameObject('/Contents')] = writer._add_object(stream)
        original = self.capture / 'sources/original.pdf'; writer.write(original)
        (self.store / 'Documents/source.pdf').write_bytes(original.read_bytes())
        self.proof['feature'] = 'quickTasks.exportText'; self.proof['sources'][0].update(name='Project handoff', sha256=hashlib.sha256(original.read_bytes()).hexdigest()); self.save()
        self.profiles = {'quickTasks.exportText': dict(standard='testRecorded', largeText='testRecordedLarge', audit='wordDocument')}
        output = self.store / 'OfficeExports/record/output.docx'; output.parent.mkdir(parents=True)
        with zipfile.ZipFile(output, 'w') as archive:
            archive.writestr('[Content_Types].xml', '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
            if not missing_main:
                number = '' if lose_number else '1280'
                archive.writestr('word/document.xml', '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Project handoff</w:t></w:r></w:p><w:p><w:r><w:t>Decision record ' + number + '</w:t></w:r></w:p></w:body></w:document>')
        records = json.loads((self.store / 'library.json').read_text())
        records[0].update(contentRevisionID='revision-a', officeReceipts=[dict(id='receipt', format='wordDocument',
            retainedFileName='output.docx', sourceRevisionID='revision-a', fileSizeBytes=output.stat().st_size,
            artifactSHA256='0'*64 if bad_receipt else hashlib.sha256(output.read_bytes()).hexdigest())])
        (self.store / 'library.json').write_text(json.dumps(records))

    def test_real_word_export_preserves_text_and_numbers(self):
        self.configure_word_export()
        self.assertTrue(self.check()['cases'][0]['checks'][0]['allNativeWordsAndNumbersPreserved'])

    def test_word_export_cannot_drop_source_numbers(self):
        self.configure_word_export(lose_number=True)
        with self.assertRaisesRegex(AssertionError, 'lost original words or numbers'): self.check()

    def test_word_artifact_must_match_its_receipt(self):
        self.configure_word_export(bad_receipt=True)
        with self.assertRaisesRegex(AssertionError, 'differs from its receipt'): self.check()

    def test_word_export_requires_a_real_main_document(self):
        self.configure_word_export(missing_main=True)
        with self.assertRaisesRegex(AssertionError, 'missing its main document'): self.check()

    def configure_page_images(self, skip_second=False, blank_second=False, reverse=False, landscape=False):
        import subprocess
        from PIL import Image
        from pypdf.generic import DictionaryObject, NameObject, DecodedStreamObject
        writer = PdfWriter()
        for text in ['FIRST PAGE WATSON', 'SECOND PAGE ENGLAND']:
            page = writer.add_blank_page(width=718.5 if landscape else 612, height=300 if landscape else 792)
            font = DictionaryObject({NameObject('/Type'): NameObject('/Font'), NameObject('/Subtype'): NameObject('/Type1'), NameObject('/BaseFont'): NameObject('/Helvetica')})
            page[NameObject('/Resources')] = DictionaryObject({NameObject('/Font'): DictionaryObject({NameObject('/F1'): writer._add_object(font)})})
            stream = DecodedStreamObject(); stream.set_data(f'BT /F1 32 Tf 50 {float(page.mediabox.height)*.75} Td ({text}) Tj ET'.encode())
            page[NameObject('/Contents')] = writer._add_object(stream)
        original = self.capture / 'sources/original.pdf'; writer.write(original)
        (self.store / 'Documents/source.pdf').write_bytes(original.read_bytes())
        self.proof['feature'] = 'quickTasks.exportImages'; self.proof['sources'][0].update(name='Project handoff', sha256=hashlib.sha256(original.read_bytes()).hexdigest()); self.save()
        self.profiles = {'quickTasks.exportImages': dict(standard='testRecorded', largeText='testRecordedLarge', audit='pageImages', imagePreset='jpegCompact', longestEdge=400)}
        group = self.capture / 'image-exports/batch'; group.mkdir(parents=True)
        rows = []
        for index in range(1 if skip_second else 2):
            selected = 1 - index if reverse else index
            prefix = group / 'reference'
            subprocess.run(['pdftoppm', '-f', str(selected+1), '-l', str(selected+1), '-singlefile', '-scale-to-x', '400' if landscape else '310', '-scale-to-y', '168' if landscape else '400', '-png', str(original), str(prefix)], check=True, capture_output=True)
            image = Image.open(prefix.with_suffix('.png')).convert('RGB')
            if blank_second and index == 1: image = Image.new('RGB', image.size, 'white')
            target = group / f'Page-{index+1:03d}.jpg'; image.save(target, 'JPEG', quality=85)
            rows.append(dict(pageIndex=index, fileName=target.name, sha256=hashlib.sha256(target.read_bytes()).hexdigest()))
        (group / 'manifest.json').write_text(json.dumps(dict(caseID=self.case_id, testID=self.proof['testID'], recordID='record', preset='jpegCompact', createdAt=15, files=rows)))

    def test_every_exported_page_image_matches_its_source(self):
        self.configure_page_images()
        self.assertTrue(self.check()['cases'][0]['checks'][0]['everyPageImageVerified'])

    def test_fractional_landscape_pixel_rounding_is_allowed(self):
        self.configure_page_images(landscape=True)
        self.assertTrue(self.check()['cases'][0]['checks'][0]['everyPageImageVerified'])

    def test_page_image_export_cannot_skip_second_page(self):
        self.configure_page_images(skip_second=True)
        with self.assertRaisesRegex(AssertionError, 'skipped or duplicated a page'): self.check()

    def test_page_image_export_cannot_publish_blank_second_page(self):
        self.configure_page_images(blank_second=True)
        with self.assertRaisesRegex(AssertionError, 'differs from its original'): self.check()

    def test_page_image_export_cannot_reverse_page_contents(self):
        self.configure_page_images(reverse=True)
        with self.assertRaisesRegex(AssertionError, 'differs from its original'): self.check()

    def configure_safe_share(self, missing_page=False, blank=False, hidden_text=False):
        from PIL import Image
        import subprocess
        self.configure_page_images()
        images = []
        for index in range(1 if missing_page else 2):
            prefix = self.capture / 'share-reference'
            subprocess.run(['pdftoppm', '-f', str(index+1), '-l', str(index+1), '-singlefile', '-r', '144', '-png', str(self.capture / 'sources/original.pdf'), str(prefix)], check=True, capture_output=True)
            image = Image.open(prefix.with_suffix('.png')).convert('RGB')
            if blank: image = Image.new('RGB', image.size, 'white')
            images.append(image)
        target = self.store / 'Documents/shared.pdf'
        images[0].save(target, 'PDF', save_all=True, append_images=images[1:], resolution=144)
        if hidden_text: target.write_bytes((self.capture / 'sources/original.pdf').read_bytes())
        records = json.loads((self.store / 'library.json').read_text())
        records.append(dict(id='new-output', displayName='Project handoff - Export', fileName='shared.pdf'))
        (self.store / 'library.json').write_text(json.dumps(records))
        self.proof['feature'] = 'quickTasks.safeShare'; self.save()
        self.profiles = {'quickTasks.safeShare': dict(standard='testRecorded', largeText='testRecordedLarge', audit='safeShare')}

    def test_real_share_copy_preserves_rendered_pages(self):
        self.configure_safe_share()
        self.assertTrue(self.check()['cases'][0]['checks'][0]['renderedOutputVerified'])

    def test_share_copy_cannot_lose_second_page(self):
        self.configure_safe_share(missing_page=True)
        with self.assertRaisesRegex(AssertionError, 'lost pages'): self.check()

    def test_share_copy_cannot_publish_blank_pages(self):
        self.configure_safe_share(blank=True)
        with self.assertRaisesRegex(AssertionError, 'differs from its original'): self.check()

    def test_share_copy_cannot_keep_hidden_source_text(self):
        self.configure_safe_share(hidden_text=True)
        with self.assertRaisesRegex(AssertionError, 'searchable source text'): self.check()

    def test_share_copy_cannot_overwrite_original(self):
        self.configure_safe_share()
        (self.store / 'Documents/source.pdf').write_bytes((self.store / 'Documents/shared.pdf').read_bytes())
        with self.assertRaisesRegex(AssertionError, 'changed an original'): self.check()

    def check_created_fixture(self, reverse=False, missing=False, blank=False):
        from PIL import Image, ImageDraw
        from AuditCoreCreation import audit_creation
        pictures = []
        colors = [(48,176,199),(88,86,214)]
        if reverse: colors.reverse()
        for i,color in enumerate(colors[:1] if missing else colors):
            image=Image.new('RGB',(612,792),'white')
            if not (blank and i==1):
                draw=ImageDraw.Draw(image);draw.rectangle((79,73,532,719),fill=color)
                draw.rectangle((115,122,230,144),fill='white')
            pictures.append(image)
        path=self.root/'created.pdf';pictures[0].save(path,'PDF',save_all=True,append_images=pictures[1:],resolution=72)
        return audit_creation(path)

    def test_created_image_pdf_has_both_ordered_source_pages(self):
        self.assertTrue(self.check_created_fixture()['pageOrderVerified'])

    def test_created_image_pdf_cannot_drop_a_page(self):
        with self.assertRaisesRegex(AssertionError,'lost or duplicated'):self.check_created_fixture(missing=True)

    def test_created_image_pdf_cannot_reverse_source_pages(self):
        with self.assertRaisesRegex(AssertionError,'teal source page'):self.check_created_fixture(reverse=True)

    def test_created_image_pdf_cannot_publish_blank_second_page(self):
        with self.assertRaisesRegex(AssertionError,'indigo source page'):self.check_created_fixture(blank=True)

    def configure_filled_value(self, missing=False, change_geometry=False):
        from pypdf.generic import DictionaryObject, NameObject, TextStringObject, ArrayObject, NumberObject
        writer=PdfWriter();page=writer.add_blank_page(width=612,height=792)
        widget=DictionaryObject({NameObject('/Subtype'):NameObject('/Widget'),NameObject('/FT'):NameObject('/Tx'),
            NameObject('/T'):TextStringObject('Recipient name'),NameObject('/V'):TextStringObject(''),
            NameObject('/Rect'):ArrayObject([NumberObject(v) for v in [20,20,200,50]])})
        page[NameObject('/Annots')]=ArrayObject([writer._add_object(widget)])
        original=self.capture/'sources/original.pdf';writer.write(original)
        self.proof['feature']='documentTools.fillForm';self.proof['sources'][0].update(name='Project handoff',sha256=hashlib.sha256(original.read_bytes()).hexdigest());self.save()
        widget[NameObject('/V')]=TextStringObject('' if missing else 'Core Verified 2026')
        if change_geometry: page.mediabox.upper_right=(600,792)
        writer.write(self.store/'Documents/source.pdf')
        self.profiles={'documentTools.fillForm':dict(standard='testRecorded',largeText='testRecordedLarge',audit='formFilled',
            additionalCases={'testRecorded':dict(fieldName='Recipient name',fieldValue='Core Verified 2026')})}

    def test_filled_form_reads_back_actual_saved_value(self):
        self.configure_filled_value();self.assertTrue(self.check()['cases'][0]['checks'][0]['savedFieldValueVerified'])

    def test_filled_form_cannot_keep_an_empty_value(self):
        self.configure_filled_value(missing=True)
        with self.assertRaisesRegex(AssertionError,'saved form value'):self.check()

    def test_filled_form_cannot_damage_page_geometry(self):
        self.configure_filled_value(change_geometry=True)
        with self.assertRaisesRegex(AssertionError,'original page content or geometry'):self.check()

    def configure_pinned_import(self, wrong_hash=False):
        original=self.capture/'sources/original.pdf';target=self.store/'Documents/import.pdf';target.write_bytes(original.read_bytes())
        rows=json.loads((self.store/'library.json').read_text());rows.append(dict(id='imported',displayName='ocr-jbig2',fileName='import.pdf'))
        (self.store/'library.json').write_text(json.dumps(rows));self.proof['feature']='core.importPDF';self.save()
        self.profiles={'core.importPDF':dict(standard='testRecorded',largeText='testRecordedLarge',audit='importedPDF',sourceName='ocr-jbig2',sourceSHA256='0'*64 if wrong_hash else hashlib.sha256(target.read_bytes()).hexdigest())}

    def test_imported_pdf_matches_the_pinned_source_bytes(self):
        self.configure_pinned_import();self.assertTrue(self.check()['cases'][0]['checks'][0]['pinnedOriginalBytes'])

    def test_imported_pdf_cannot_substitute_another_file(self):
        self.configure_pinned_import(wrong_hash=True)
        with self.assertRaisesRegex(AssertionError,'pinned original'):self.check()

    def test_imported_pdf_cannot_change_existing_documents(self):
        self.configure_pinned_import();(self.store/'Documents/source.pdf').write_bytes(b'changed existing source')
        with self.assertRaisesRegex(AssertionError,'changed an existing'):self.check()

    def test_unimplemented_audit_cannot_pretend_to_pass(self):
        self.profiles['quickTasks.compressPDF']['audit'] = 'invented-validator'
        with self.assertRaisesRegex(ValueError, 'Unsupported output audit'): self.check()


if __name__ == '__main__': unittest.main()
