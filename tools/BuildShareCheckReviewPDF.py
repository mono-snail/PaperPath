from pathlib import Path
from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import landscape, A4
from reportlab.lib.colors import HexColor
from reportlab.lib.utils import ImageReader
from pypdf import PdfReader

root = Path(__file__).resolve().parents[1]
output = root / 'output/pdf/PaperPath-22-review-walkthrough.pdf'
output.parent.mkdir(parents=True, exist_ok=True)
width, height = landscape(A4)
c = canvas.Canvas(str(output), pagesize=(width, height))
c.setTitle('PaperPath 1.1.0 (22) - Check before sharing')
c.setAuthor('MonoWare')
c.setFillColor(HexColor('#F8F5F1')); c.rect(0, 0, width, height, stroke=0, fill=1)
c.setFillColor(HexColor('#172D3A')); c.setFont('Helvetica-Bold', 20)
c.drawString(28, height - 29, 'PaperPath | Check before sharing')
c.setFont('Helvetica', 9)
c.drawString(28, height - 46, 'Documents > Check before sharing > Try a fictional sample')
c.drawRightString(width - 28, height - 29, '1.1.0 (22)')
items = [
    ('1. Start from Documents', 'iphone-01-start.png'),
    ('2. Review detected details', 'iphone-02-review.png'),
    ('3. Inspect the checked output', 'iphone-03-output.png'),
]
column = (width - 56 - 32) / 3
for index, (label, filename) in enumerate(items):
    x = 28 + index * (column + 16)
    c.setFont('Helvetica-Bold', 10)
    c.drawString(x, height - 67, label)
    image = ImageReader(str(root / '.artifacts/share-check-release-20261105/store-assets/en-US' / filename))
    iw, ih = image.getSize()
    image_height = height - 112
    image_width = image_height * iw / ih
    c.drawImage(image, x + (column - image_width) / 2, 31, width=image_width, height=image_height,
                preserveAspectRatio=True, mask='auto')
c.setFillColor(HexColor('#51616B')); c.setFont('Helvetica', 8)
c.drawString(28, 17, 'Fictional data. Review manually; file checks do not certify content accuracy. No AI model or account is required.')
c.showPage(); c.save()
reader = PdfReader(str(output)); assert len(reader.pages) == 1
assert 'PaperPath' in reader.pages[0].extract_text()
print(output)
