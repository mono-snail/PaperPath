#!/usr/bin/env python3
"""Original fictional PDF artwork for real-app website captures. No external PDF content."""
from pathlib import Path
from reportlab.pdfgen import canvas
from reportlab.lib.colors import HexColor, Color, white
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.utils import ImageReader
from pypdf import PdfReader
import textwrap

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'output/pdf'
ART = ROOT / 'design/hero-2026-10-28/garden-illustration.png'
OUT.mkdir(parents=True, exist_ok=True)
FONTS=Path('/System/Library/Fonts/Supplemental')
for name,file in [('Body','Arial.ttf'),('Bold','Arial Bold.ttf'),('Editorial','Georgia.ttf'),('EditorialBold','Georgia Bold.ttf'),('Signature','SnellRoundhand.ttc')]:
    pdfmetrics.registerFont(TTFont(name, str(FONTS/file)))
INK='#173342'; BLUE='#00658b'; MUTED='#566870'; RULE='#d7e0df'; PALE='#eaf1ee'; GREEN='#52715b'

def text(c,x,y,s,size=12,font='Body',color=INK):
    c.setFillColor(HexColor(color)); c.setFont(font,size); c.drawString(x,y,s)
def line(c,x,y,x2,y2,color=RULE,width=.8):
    c.setStrokeColor(HexColor(color)); c.setLineWidth(width);c.line(x,y,x2,y2)
def block(c,x,y,s,width,size=12,leading=18,font='Body',color=MUTED):
    words=s.split(); rows=[]; row=''
    for word in words:
        if pdfmetrics.stringWidth((row+' '+word).strip(),font,size)>width:
            rows.append(row);row=word
        else: row=(row+' '+word).strip()
    if row:rows.append(row)
    for row in rows:text(c,x,y,row,size,font,color);y-=leading
    return y

def header(c,w,label,folio):
    text(c,36,622,'R / G',13,'Bold',BLUE)
    text(c,97,623,'RIVERSIDE STUDIO',10,'Bold')
    text(c,w-208,623,label,9,'Body',MUTED)
    line(c,36,607,w-36,607)
    line(c,36,34,w-36,34)
    text(c,36,19,'FICTIONAL PROJECT  /  ORIGINAL DEMONSTRATION DOCUMENT',8,'Body',MUTED)
    text(c,w-95,19,folio,8,'Body',MUTED)

p=OUT/'Riverside Garden.pdf'
c=canvas.Canvas(str(p),pagesize=(900,650));c.setTitle('Riverside Garden - Design Proposal');c.setAuthor('PaperPath fictional demo')
header(c,900,'DESIGN PROPOSAL  /  OCT 2026','01 / 02')
text(c,36,578,'A LITTLE MORE ROOM TO GROW',10,'Bold',BLUE)
text(c,36,540,'Riverside',38,'EditorialBold');text(c,36,495,'Community Garden',32,'EditorialBold')
block(c,36,461,'A greener riverfront. A shared place to pause, meet and grow.',275,16,22,'Editorial',GREEN)
block(c,36,389,'An underused riverside lot becomes a welcoming neighborhood garden. Native planting, rain-fed beds and step-free paths connect everyday life with the water.',275,12,18)
# Editorial project facts: large values remain legible in the homepage composition.
for x,n,label in [(36,'1,240','m2 restored'),(139,'68%','planted area'),(242,'24','new trees')]:
    text(c,x,287,n,25,'Bold',BLUE);text(c,x,269,label,9,'Body',MUTED)
if ART.exists():c.drawImage(ImageReader(str(ART)),329,291,width=538,height=302,preserveAspectRatio=True,anchor='c',mask='auto')
text(c,355,289,'01  /  THE GARDEN PLAN',9,'Bold',BLUE)
text(c,579,289,'Native planting  -  Open seating  -  River walk',9,'Body',MUTED)
line(c,36,247,864,247)
text(c,36,224,'Designed for everyday life',19,'EditorialBold')
block(c,36,198,'A sheltered meeting table anchors the garden. Permeable paths and seasonal planting create a calm, accessible route from the street to the river.',275,11,17)
text(c,36,114,'Three priorities',10,'Bold',BLUE)
for yy,n,s in [(94,'01','Restore the river edge'),(76,'02','Make every route accessible'),(58,'03','Keep care simple and local')]:
    text(c,36,yy,n,9,'Bold',BLUE);text(c,62,yy,s,11)
text(c,354,224,'Budget at a glance',19,'EditorialBold')
for yy,label,val in [(194,'Groundwork & drainage','$24,000'),(169,'Native planting & trees','$32,000'),(144,'Paths, seating & pavilion','$56,000'),(119,'Design & contingency','$28,000')]:
    text(c,354,yy,label,11);text(c,751,yy,val,11,'Body');line(c,354,yy-8,864,yy-8)
c.setFillColor(HexColor(PALE));c.rect(348,54,516,42,fill=1,stroke=0)
text(c,361,70,'TOTAL PROJECT ESTIMATE',10,'Bold',BLUE);text(c,738,68,'$140,000',19,'Bold',BLUE)
c.showPage();header(c,900,'DELIVERY PLAN  /  OCT 2026','02 / 02')
text(c,36,556,'From proposal to planted space',32,'EditorialBold')
block(c,36,515,'A practical sequence for a small project with a lasting neighborhood benefit.',700,15,22,'Editorial',GREEN)
for i,(title,body) in enumerate([('01  Listen & refine','Gather neighbor feedback, confirm access routes and refine the planting palette.'),('02  Prepare & build','Complete drainage and groundworks before installing paths, seating and pavilion.'),('03  Plant & care','Plant in the cool season. Establish a simple watering and maintenance schedule.')]):
    x=36+i*282;c.setFillColor(HexColor(PALE));c.rect(x,287,262,170,fill=1,stroke=0)
    text(c,x+18,425,title,18,'EditorialBold');block(c,x+18,390,body,224,13,21)
text(c,36,238,'Delivery checkpoints',21,'EditorialBold')
for yy,a,b in [(204,'November 2026','Design review and community approval'),(166,'January 2027','Groundworks and material procurement'),(128,'March 2027','Planting, inspection and opening')]:
    text(c,36,yy,a,13,'Bold',BLUE);text(c,237,yy,b,13);line(c,36,yy-15,864,yy-15)
text(c,36,66,'Prepared by Riverside Studio. All names, figures and project details are fictional.',11,'Body',MUTED)
c.save()

p=OUT/'Project Approval.pdf'
c=canvas.Canvas(str(p),pagesize=(420,650));c.setTitle('Project Approval - Riverside Garden');c.setAuthor('PaperPath fictional demo')
text(c,28,615,'R / G',16,'Bold',BLUE);text(c,93,618,'RIVERSIDE STUDIO',10,'Bold');text(c,93,603,'PROJECT RECORD  /  RG-026',9,'Body',MUTED)
line(c,28,584,392,584)
text(c,28,550,'Project approval',30,'EditorialBold')
text(c,28,526,'Riverside Community Garden',14,'Body',GREEN)
c.setFillColor(HexColor(PALE));c.roundRect(28,431,364,70,6,fill=1,stroke=0)
text(c,42,480,'APPROVED PROJECT BUDGET',9,'Bold',BLUE);text(c,42,449,'$140,000',27,'Bold',BLUE)
text(c,273,476,'TARGET OPENING',8,'Bold',BLUE);text(c,273,453,'March 2027',12,'Bold')
for yy,a,b in [(405,'CLIENT','Riverside Community'),(370,'PROJECT LEAD','Alex Morgan'),(335,'REFERENCE','RG-026 / Revision 03')]:
    text(c,28,yy,a,8,'Bold',MUTED);text(c,28,yy-17,b,13);line(c,28,yy-25,392,yy-25)
text(c,28,280,'Scope confirmed',16,'EditorialBold')
block(c,28,257,'I approve the design, scope and estimated budget in the attached proposal. The team may proceed to the next delivery stage.',362,12,18)
# Completed fields and an example handwritten signature are original PDF content.
# No certification / legal identity verification is implied.
text(c,28,184,'CLIENT SIGNATURE',8,'Bold',MUTED)
text(c,31,141,'Alex Morgan',30,'Signature',BLUE)
line(c,28,130,235,130);text(c,272,184,'DATE',8,'Bold',MUTED);text(c,272,148,'28 Oct 2026',12);line(c,272,130,392,130)
c.setStrokeColor(HexColor(BLUE));c.setLineWidth(1);c.rect(29,94,10,10,fill=0,stroke=1)
line(c,31,99,34,96,BLUE,1.3);line(c,34,96,38,103,BLUE,1.3)
text(c,47,96,'Design and budget reviewed',10,'Body')
line(c,28,56,392,56);text(c,28,38,'FICTIONAL SAMPLE  /  NOT A REAL AGREEMENT',8,'Body',MUTED);text(c,365,38,'01',8,'Body',MUTED)
c.save()
for p in OUT.glob('*.pdf'):
    if p.name not in ['Riverside Garden.pdf','Project Approval.pdf']:continue
    r=PdfReader(p); assert all(len(page.extract_text())>350 for page in r.pages)
    print(f'{p}: {len(r.pages)} pages, {p.stat().st_size:,} bytes')
