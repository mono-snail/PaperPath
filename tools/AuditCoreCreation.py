"""Independent checks for the two-page native image-review test fixture.

Uses actual saved PDFs. This proves image-review -> PDF creation, not camera or
photo-library acquisition. The fixture is 600x800: teal page then indigo page,
white inset frame and white page-label ink near the top.
"""
from pathlib import Path
import subprocess
import tempfile
from PIL import Image
from pypdf import PdfReader


def audit_creation(path):
    reader = PdfReader(path, strict=True)
    assert len(reader.pages) == 2, 'Image review lost or duplicated a page'
    checks = []
    with tempfile.TemporaryDirectory() as temporary:
        for index, page in enumerate(reader.pages):
            assert [float(page.mediabox.width), float(page.mediabox.height)] == [612, 792], 'Created PDF has unexpected geometry'
            assert not page.rotation and not page.get('/Annots'), 'Created page has unexpected rotation or annotations'
            prefix = Path(temporary) / f'page-{index}'
            subprocess.run(['pdftoppm', '-f', str(index+1), '-l', str(index+1), '-singlefile',
                '-r', '72', '-png', str(path), str(prefix)], check=True, capture_output=True)
            with Image.open(prefix.with_suffix('.png')) as image:
                image = image.convert('RGB')
                center = list(image.crop((240, 350, 370, 450)).getdata())
                rgb = [sum(pixel[channel] for pixel in center)/len(center) for channel in range(3)]
                if index == 0:
                    assert rgb[1] > rgb[0]+65 and rgb[2] > rgb[0]+65, 'First page is not the teal source page'
                else:
                    assert rgb[2] > rgb[0]+65 and rgb[2] > rgb[1]+65 and abs(rgb[0]-rgb[1]) < 35, 'Second page is not the indigo source page'
                frame = list(image.crop((24, 24, 45, 45)).getdata())
                assert all(min(pixel) > 235 for pixel in frame), 'Created PDF lost the source white frame'
                label = list(image.crop((106, 116, 390, 180)).getdata())
                ink = sum(min(pixel) > 225 for pixel in label)/len(label)
                assert .002 < ink < .65, 'Created page label region is blank or damaged'
                checks.append(dict(pageIndex=index, sourceColor=rgb, labelInkFraction=ink))
    return dict(pageCount=2, imageContentPresent=True, pageOrderVerified=True,
                geometryVerified=True, labelInkPresent=True, pages=checks,
                limitation='Fixture image review only; camera/photo acquisition and exact label OCR are outside this check.')
