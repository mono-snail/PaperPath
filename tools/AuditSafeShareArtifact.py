"""Verify a real flattened share PDF against its original, using offline Poppler."""
from pathlib import Path
import subprocess
import tempfile
from PIL import Image, ImageChops, ImageStat
from pypdf import PdfReader


def audit_safe_share(original, output):
    before, after = PdfReader(original, strict=True), PdfReader(output, strict=True)
    assert len(before.pages) == len(after.pages) > 0, 'Share export lost pages'
    assert not after.get_fields() and not after.attachments, 'Share export retained forms or attachments'
    assert not any(key in after.trailer['/Root'] for key in ['/OpenAction', '/AA', '/Metadata']), 'Share export retained active/private catalog data'
    errors = []
    with tempfile.TemporaryDirectory() as temporary:
        for index, (source, saved) in enumerate(zip(before.pages, after.pages)):
            assert not (saved.extract_text() or '').strip(), 'Share export retained searchable source text'
            assert not saved.get('/Annots'), 'Share export retained editable annotations'
            expected = [float(source.cropbox.width), float(source.cropbox.height)]
            if source.rotation % 180: expected.reverse()
            actual = [float(saved.cropbox.width), float(saved.cropbox.height)]
            if saved.rotation % 180: actual.reverse()
            assert all(abs(a-b) < .01 for a, b in zip(expected, actual)), 'Share export changed page geometry'
            pictures = []
            for name, pdf in [('original', original), ('export', output)]:
                prefix = Path(temporary) / name
                subprocess.run(['pdftoppm', '-f', str(index+1), '-l', str(index+1), '-singlefile',
                    '-cropbox', '-scale-to', '1536', '-png', str(pdf), str(prefix)], check=True, capture_output=True)
                with Image.open(prefix.with_suffix('.png')) as image:
                    pictures.append(image.convert('RGB').resize((256, 256), Image.Resampling.LANCZOS))
            variance = sum(ImageStat.Stat(pictures[0]).var) / 3
            error = sum(ImageStat.Stat(ImageChops.difference(*pictures)).sum2) / (256*256*3*max(variance, 1))
            assert error <= .12, f'Share page {index+1} differs from its original ({error:.4f})'
            errors.append(error)
    return dict(pageCount=len(after.pages), pageGeometryPreserved=True, hiddenTextAbsent=True,
        annotationsFormsAttachmentsRemoved=True, renderedOutputVerified=True, maximumRelativeError=max(errors))
