"""Fault injection: the output gate must reject incorrect results."""
import base64
import io
import json
from pathlib import Path
import tempfile
import unittest
from pypdf import PdfReader, PdfWriter
from AuditMergeOutputs import audit


class MergeOutputAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.attachments = root / 'attachments'
        self.attachments.mkdir()
        self.container = root / 'app'
        self.store = self.container / 'Documents/DocumentLifecycleUITestFixtures/fixture'
        self.files = self.store / 'Documents'
        self.files.mkdir(parents=True)
        self.sources = []
        self.records = []
        for number, width in enumerate([612, 792], 1):
            writer = PdfWriter()
            writer.add_blank_page(width=width, height=792)
            buffer = io.BytesIO()
            writer.write(buffer)
            data = buffer.getvalue()
            name = f'Merge {number:02d}'
            filename = f'source-{number}.pdf'
            (self.files / filename).write_bytes(data)
            self.sources.append(dict(name=name, base64=base64.b64encode(data).decode()))
            self.records.append(dict(displayName=name, fileName=filename))
        self.records.append(dict(displayName='Merged', fileName='result.pdf'))
        (self.store / 'library.json').write_text(json.dumps(self.records))
        (self.attachments / 'corpus.json').write_text(json.dumps(dict(
            schema='paperpath-merge-ui-v1', fixtureID='fixture', sources=self.sources)))
        (self.attachments / 'expectation.json').write_text(json.dumps(dict(
            schema='paperpath-merge-output-v1', fixtureID='fixture', resultName='Merged', order=[2, 1])))
        self.write_result([2, 1])

    def write_result(self, order):
        writer = PdfWriter()
        for number in order:
            writer.add_page(PdfReader(self.files / f'source-{number}.pdf').pages[0])
        writer.write(self.files / 'result.pdf')

    def test_correct_output_passes(self):
        self.assertEqual(audit(self.attachments, self.container)['status'], 'PASSED')
        # A known corrupt, unselected source is preserved byte-for-byte while
        # the valid source still produces an independently checked output.
        bad = b'%PDF-1.7\nbroken-source\n'
        (self.files / 'source-1.pdf').write_bytes(bad)
        corpus = json.loads((self.attachments / 'corpus.json').read_text())
        corpus['sources'][0]['base64'] = base64.b64encode(bad).decode()
        corpus['unreadableSources'] = ['Merge 01']
        (self.attachments / 'corpus.json').write_text(json.dumps(corpus))
        expectation = json.loads((self.attachments / 'expectation.json').read_text())
        expectation['order'] = [2]
        (self.attachments / 'expectation.json').write_text(json.dumps(expectation))
        self.write_result([2])
        self.assertEqual(audit(self.attachments, self.container)['status'], 'PASSED')
        expectation['order'] = [1, 2]
        (self.attachments / 'expectation.json').write_text(json.dumps(expectation))
        with self.assertRaisesRegex(AssertionError, 'Unreadable source'):
            audit(self.attachments, self.container)

    def test_wrong_page_order_is_rejected(self):
        self.write_result([1, 2])
        with self.assertRaisesRegex(AssertionError, 'Output page 1 changed'):
            audit(self.attachments, self.container)

    def test_missing_page_is_rejected(self):
        self.write_result([2])
        with self.assertRaisesRegex(AssertionError, 'page count'):
            audit(self.attachments, self.container)

    def test_modified_original_is_rejected(self):
        (self.files / 'source-1.pdf').write_bytes((self.files / 'source-2.pdf').read_bytes())
        with self.assertRaisesRegex(AssertionError, 'changed an original'):
            audit(self.attachments, self.container)

    def test_missing_embedded_attachment_is_rejected(self):
        source = PdfWriter()
        source.add_page(PdfReader(self.files / 'source-2.pdf').pages[0])
        source.add_attachment('important.txt', b'Keep the exact embedded payload')
        source.write(self.files / 'source-2.pdf')
        corpus = json.loads((self.attachments / 'corpus.json').read_text())
        corpus['sources'][1]['base64'] = base64.b64encode((self.files / 'source-2.pdf').read_bytes()).decode()
        (self.attachments / 'corpus.json').write_text(json.dumps(corpus))
        result = PdfWriter()
        for number in [2, 1]: result.add_page(PdfReader(self.files / f'source-{number}.pdf').pages[0])
        result.add_attachment('important.txt', b'Keep the exact embedded payload')
        result.write(self.files / 'result.pdf')
        self.assertEqual(audit(self.attachments, self.container)['status'], 'PASSED')
        self.write_result([2, 1])
        with self.assertRaisesRegex(AssertionError, 'Embedded attachment'):
            audit(self.attachments, self.container)

    def test_no_output_evidence_is_rejected(self):
        (self.attachments / 'expectation.json').unlink()
        with self.assertRaisesRegex(AssertionError, 'No output expectation'):
            audit(self.attachments, self.container)


if __name__ == '__main__':
    unittest.main()
