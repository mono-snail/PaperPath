"""Build a local, unsubmitted reviewer guide from retained build-23 screenshots."""
from pathlib import Path
import hashlib
import json
import textwrap
from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import landscape, A4
from reportlab.lib.colors import HexColor
from reportlab.lib.utils import ImageReader
from pypdf import PdfReader

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'output/pdf/PaperPath-23-review-evidence.pdf'
BASE = '.artifacts/resubmit-20261112-build23-iphone-final/attachments/'
SCREENS = [
    ('1. Start in Documents', BASE + '9EFC1F44-2543-4F8B-B146-D9851E3EBC9D.png'),
    ('2. Choose the fictional sample', BASE + '51D0EDFB-4B66-40DD-AFEF-4EB103346390.png'),
    ('3. Review in page context', BASE + '4E07B4C6-71FB-4957-BAE2-563BA4A4D3C3.png'),
    ('4. Inspect the redaction result', BASE + '4397D845-5B99-457B-A571-0F3C3268B203.png'),
    ('Separate output receipt example', '.artifacts/resubmit-20261111-preparation/full-phone-attachments/04CC8CE0-CFA6-488C-B601-9D10F78C8A4E.png'),
]

def build():
    OUT.parent.mkdir(parents=True, exist_ok=True)
    width, height = landscape(A4)
    c = canvas.Canvas(str(OUT), pagesize=(width, height))
    c.setTitle('PaperPath 1.1.0 (23) - Review workflow evidence')
    c.setAuthor('MonoWare')

    def header(title, subtitle, page):
        c.setFillColor(HexColor('#F8F5F1'))
        c.rect(0, 0, width, height, stroke=0, fill=1)
        c.setFillColor(HexColor('#172D3A'))
        c.setFont('Helvetica-Bold', 20)
        c.drawString(28, height - 32, title)
        c.setFont('Helvetica', 10)
        c.drawString(28, height - 51, subtitle)
        c.setFont('Helvetica', 8)
        c.drawRightString(width - 28, 15, f'1.1.0 (23) | {page}/2')

    def screen(item, x, y, maxw, maxh):
        label, path = item
        c.setFillColor(HexColor('#172D3A'))
        c.setFont('Helvetica-Bold', 10)
        c.drawString(x, y + maxh + 10, label)
        im = ImageReader(str(ROOT / path))
        iw, ih = im.getSize()
        scale = min(maxw / iw, maxh / ih)
        w, h = iw * scale, ih * scale
        c.drawImage(im, x + (maxw-w)/2, y, width=w, height=h, mask='auto')

    def paragraph(text, x, y, chars=54, size=11, leading=16):
        c.setFont('Helvetica', size)
        c.setFillColor(HexColor('#172D3A'))
        for line in textwrap.wrap(text, width=chars):
            c.drawString(x, y, line)
            y -= leading
        return y - 14

    header('Check a PDF before sharing',
           'Documents > Check before sharing > Try a fictional sample', 1)
    col = (width - 88) / 3
    for i, item in enumerate(SCREENS[:3]):
        screen(item, 28 + i*(col+16), 49, col, height-135)
    c.setFont('Helvetica', 8)
    c.drawString(28, 28, 'Actual build-23 iPhone simulator screenshots from retained validation runs. Fictional data only.')
    c.showPage()

    header('Inspect the copy and its receipt',
           'The redaction result and separate delivery receipt demonstrate two related review paths.', 2)
    screen(SCREENS[3], 28, 48, 205, height-139)
    screen(SCREENS[4], 249, 48, 205, height-139)
    y = height - 90
    for text in [
        'After reviewing and confirming candidates, open the redacted document to inspect the result. The source remains available in version history.',
        'For an image-based delivery copy, open Deliver > Verify & Share. Open Delivery receipt to inspect output checks, warnings and the corresponding file fingerprint.',
        'The receipt shown here is from a separate fictional "Project handoff" fixture. It is not a receipt for the sample shown on the left. It intentionally retains a visual-review warning.',
        'Image-based output removes searchable text, links and interactive forms. Automatic detection can miss content. File checks do not certify accuracy, signer identity or legal compliance.',
        'No PaperPath account, network connection or AI model download is needed for the core workflow.',
    ]:
        y = paragraph(text, 477, y, chars=49, size=10, leading=14)
    assert y > 28, y
    c.showPage()
    c.save()
    reader = PdfReader(str(OUT))
    assert len(reader.pages) == 2
    assert 'separate' in reader.pages[1].extract_text().lower()
    evidence = [dict(label=label, source=path,
                     sha256=hashlib.sha256((ROOT/path).read_bytes()).hexdigest())
                for label, path in SCREENS]
    (ROOT/'docs/review-2026-11-12/SCREENSHOT_EVIDENCE.json').write_text(
        json.dumps(dict(status='LOCAL_DRAFT_NOT_SUBMITTED', version='1.1.0', build='23',
                        pdf=str(OUT.relative_to(ROOT)), screenshots=evidence), indent=2)+'\n')
    print(OUT)

if __name__ == '__main__':
    build()
