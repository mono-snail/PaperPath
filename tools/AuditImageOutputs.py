"""Compare actual exported page images with independent Poppler renders."""
from pathlib import Path
import subprocess
import tempfile
from PIL import Image, ImageChops, ImageStat
from pypdf import PdfReader


def audit_page_image(source, page_index, output, longest_edge, evidence):
    with Image.open(output) as actual:
        assert actual.format == 'JPEG', 'Compact JPEG export has the wrong image format'
        actual.load(); width, height = actual.size
        assert max(width, height) == longest_edge, 'Exported image has the wrong preset resolution'
        page = PdfReader(source, strict=True).pages[page_index]
        expected_size = [float(page.cropbox.width), float(page.cropbox.height)]
        if page.rotation % 180: expected_size.reverse()
        scale = longest_edge / max(expected_size)
        assert all(abs(actual - points * scale) <= 1.001 for actual, points in zip([width, height], expected_size)), 'Exported image has the wrong page orientation/aspect ratio'
        actual_small = actual.convert('RGB').resize((256, 256), Image.Resampling.LANCZOS)
    with tempfile.TemporaryDirectory() as temporary:
        prefix = Path(temporary) / 'reference'
        subprocess.run(['pdftoppm', '-f', str(page_index + 1), '-l', str(page_index + 1), '-singlefile',
            '-cropbox', '-scale-to-x', str(width), '-scale-to-y', str(height), '-png', str(source), str(prefix)],
            check=True, capture_output=True)
        reference = Image.open(prefix.with_suffix('.png')).convert('RGB')
        reference_small = reference.resize((256, 256), Image.Resampling.LANCZOS)
        variance = sum(ImageStat.Stat(reference_small).var) / 3
        error = sum(ImageStat.Stat(ImageChops.difference(reference_small, actual_small)).sum2) / (256 * 256 * 3)
        relative_error = error / max(variance, 1)
        assert relative_error <= .12, f'Exported page {page_index + 1} differs from its original (relative error {relative_error:.4f})'
        evidence.mkdir(parents=True, exist_ok=True)
        reference_small.save(evidence / f'page-{page_index + 1:03d}-reference.png')
        actual_small.save(evidence / f'page-{page_index + 1:03d}-export.png')
    return dict(pageIndex=page_index, width=width, height=height, imageFormat='JPEG',
        geometryVerified=True, pageContentVerified=True, relativeMeanSquaredError=relative_error)
