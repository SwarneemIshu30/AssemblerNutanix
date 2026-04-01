from reportlab.lib.pagesizes import landscape, A4
from reportlab.lib import colors
from reportlab.pdfgen import canvas

W, H = landscape(A4)
OUT = 'docs/assembler-mapping-flow.pdf'

c = canvas.Canvas(OUT, pagesize=(W, H))

# Title
c.setFont('Helvetica-Bold', 18)
c.drawString(30, H - 35, 'Assembler Dataset -> Mapping -> Projection -> SDT Output Flow')
c.setFont('Helvetica', 10)
c.drawString(30, H - 52, 'Purpose: show where to modify mappings, projections, templates, and output behavior.')


def box(x, y, w, h, title, lines, fill=colors.whitesmoke):
    c.setStrokeColor(colors.black)
    c.setFillColor(fill)
    c.roundRect(x, y, w, h, 8, stroke=1, fill=1)
    c.setFillColor(colors.black)
    c.setFont('Helvetica-Bold', 10)
    c.drawString(x + 8, y + h - 16, title)
    c.setFont('Helvetica', 8.5)
    ty = y + h - 30
    for line in lines:
        c.drawString(x + 8, ty, line)
        ty -= 11


def arrow(x1, y1, x2, y2, label=''):
    c.setStrokeColor(colors.darkblue)
    c.setLineWidth(1.2)
    c.line(x1, y1, x2, y2)
    # simple arrow head
    if x2 >= x1:
        c.line(x2, y2, x2 - 8, y2 + 4)
        c.line(x2, y2, x2 - 8, y2 - 4)
    else:
        c.line(x2, y2, x2 + 8, y2 + 4)
        c.line(x2, y2, x2 + 8, y2 - 4)
    if label:
        c.setFillColor(colors.darkblue)
        c.setFont('Helvetica', 8)
        c.drawString((x1 + x2) / 2 - 20, (y1 + y2) / 2 + 6, label)
        c.setFillColor(colors.black)

# Main pipeline row
y = 280
h = 115
w = 165
xs = [25, 205, 385, 565, 745]

box(xs[0], y, w, h, '1) Collector datasets in bundle', [
    'bundle/<id>/datasets/<tech>/.../*.json',
    'Envelope: lnv.collector.dataset.v1',
    'Contains items + metadata'
], fill=colors.HexColor('#EEF5FF'))

box(xs[1], y, w, h, '2) Bundle orchestration', [
    'Invoke-AssemblerBundleRender.ps1',
    'Reads objectIndex + catalog',
    'Resolves __TARGET__/__SYSTEM__'
], fill=colors.HexColor('#EEF5FF'))

box(xs[2], y, w, h, '3) Mapping resolution', [
    'templates/skeletons/<tech>/*.mapping.json',
    'dataset + selectors + target/sdtTag',
    'renderHint: renderAs/projectionRef/view'
], fill=colors.HexColor('#EEF5FF'))

box(xs[3], y, w, h, '4) Projection + sidecar intent', [
    '.deps/contracts/tech/<tech>/',
    'assembler.projections.v1.json',
    'dataset/*.assembler.meta.json'
], fill=colors.HexColor('#EEF5FF'))

box(xs[4], y, w, h, '5) SDT render output', [
    'Invoke-AssemblerSdtRender.ps1',
    'Populates <<SDT:...>> in template',
    'Writes DOCX/TXT + render reports'
], fill=colors.HexColor('#EEF5FF'))

for i in range(len(xs)-1):
    arrow(xs[i] + w, y + h/2, xs[i+1] - 8, y + h/2)

# Ownership/authoritative section
box(25, 120, 300, 125, 'Authoritative contract ownership', [
    'Edit FIRST: .deps/contracts/tech/<tech>/mapping.dataset-to-sdt.v1.yaml',
    'Then keep runtime mapping copy aligned:',
    'templates/skeletons/<tech>/*.mapping.json',
    'Mirror owned handoff artifacts under exports/LNV.AsBuiltDoc.Contracts/...'
], fill=colors.HexColor('#FFF7E6'))

box(350, 120, 260, 125, 'Change table shape', [
    'Edit assembler.projections.v1.json',
    '- columns, formats, ordering',
    '- empty behavior, aliases',
    'Ensure mapping renderHint.projectionRef points correctly'
], fill=colors.HexColor('#F0FFF4'))

box(635, 120, 275, 125, 'Change token/template/output file', [
    'Template tokens: templates/skeletons/<tech>/*.docx or *.template.txt',
    'Catalog run control: templates/skeletons/<tech>/*.catalog.json',
    '- mappingPath, templatePath, outputFileName, enabled'
], fill=colors.HexColor('#F0FFF4'))

arrow(325, 182, 350, 182)
arrow(610, 182, 635, 182)

c.setFont('Helvetica-Oblique', 8)
c.drawString(25, 25, 'Tip: Prefer contract-driven changes (mapping/projection/sidecar) over adding tech-specific logic in renderer scripts.')

c.save()
print(f'Wrote {OUT}')
