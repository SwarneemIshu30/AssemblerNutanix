from reportlab.lib.pagesizes import landscape, A4
from reportlab.lib import colors
from reportlab.pdfgen import canvas

W, H = landscape(A4)
OUT = 'docs/assembler-mapping-flow.pdf'


def box(c, x, y, w, h, title, lines, fill=colors.whitesmoke):
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


def arrow(c, x1, y1, x2, y2, label=''):
    c.setStrokeColor(colors.darkblue)
    c.setLineWidth(1.2)
    c.line(x1, y1, x2, y2)
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


def section_title(c, text, y):
    c.setFont('Helvetica-Bold', 13)
    c.drawString(30, y, text)


def bullets(c, items, start_y, indent=42, line_gap=13):
    y = start_y
    c.setFont('Helvetica', 10)
    for item in items:
        c.drawString(indent - 12, y, u'•')
        c.drawString(indent, y, item)
        y -= line_gap
    return y


c = canvas.Canvas(OUT, pagesize=(W, H))

# PAGE 1: Diagram
c.setFont('Helvetica-Bold', 18)
c.drawString(30, H - 35, 'Assembler Dataset -> Mapping -> Projection -> SDT Output Flow')
c.setFont('Helvetica', 10)
c.drawString(30, H - 52, 'Diagram + change points for team onboarding and safe contract-driven edits.')

y = 280
h = 115
w = 165
xs = [25, 205, 385, 565, 745]

box(c, xs[0], y, w, h, '1) Collector datasets in bundle', [
    'bundle/<id>/datasets/<tech>/.../*.json',
    'Envelope: lnv.collector.dataset.v1',
    'Contains items + metadata'
], fill=colors.HexColor('#EEF5FF'))

box(c, xs[1], y, w, h, '2) Bundle orchestration', [
    'Invoke-AssemblerBundleRender.ps1',
    'Reads objectIndex + catalog',
    'Resolves __TARGET__/__SYSTEM__ placeholders'
], fill=colors.HexColor('#EEF5FF'))

box(c, xs[2], y, w, h, '3) Mapping resolution', [
    'templates/skeletons/<tech>/*.mapping.json',
    'dataset + selectors + target/sdtTag',
    'renderHint: renderAs/projectionRef/view'
], fill=colors.HexColor('#EEF5FF'))

box(c, xs[3], y, w, h, '4) Projection + sidecar intent', [
    '.deps/contracts/tech/<tech>/',
    'assembler.projections.v1.json',
    'dataset/*.assembler.meta.json'
], fill=colors.HexColor('#EEF5FF'))

box(c, xs[4], y, w, h, '5) SDT render output', [
    'Invoke-AssemblerSdtRender.ps1',
    'Populates <<SDT:...>> tokens in template',
    'Writes DOCX/TXT + render reports'
], fill=colors.HexColor('#EEF5FF'))

for i in range(len(xs)-1):
    arrow(c, xs[i] + w, y + h/2, xs[i+1] - 8, y + h/2)

box(c, 25, 120, 300, 125, 'Authoritative contract ownership', [
    'Edit FIRST: .deps/contracts/tech/<tech>/mapping.dataset-to-sdt.v1.yaml',
    'Then keep runtime mapping copy aligned:',
    'templates/skeletons/<tech>/*.mapping.json',
    'Mirror handoff artifacts under exports/LNV.AsBuiltDoc.Contracts/...'
], fill=colors.HexColor('#FFF7E6'))

box(c, 350, 120, 260, 125, 'Change table shape', [
    'Edit assembler.projections.v1.json',
    '- columns, formats, ordering',
    '- empty behavior, aliases',
    'Ensure mapping renderHint.projectionRef points correctly'
], fill=colors.HexColor('#F0FFF4'))

box(c, 635, 120, 275, 125, 'Change token/template/output file', [
    'Template tokens: templates/skeletons/<tech>/*.docx or *.template.txt',
    'Catalog run control: templates/skeletons/<tech>/*.catalog.json',
    '- mappingPath, templatePath, outputFileName, enabled'
], fill=colors.HexColor('#F0FFF4'))

arrow(c, 325, 182, 350, 182)
arrow(c, 610, 182, 635, 182)

c.setFont('Helvetica-Oblique', 8)
c.drawString(25, 25, 'Tip: Prefer contract-driven changes (mapping/projection/sidecar) over adding tech-specific renderer logic.')

# PAGE 2: Relationship model + control points (verbose text from prior explanation)
c.showPage()
c.setFont('Helvetica-Bold', 18)
c.drawString(30, H - 35, 'Relationship Model: What Controls What')
c.setFont('Helvetica', 10)
c.drawString(30, H - 52, 'Reference text for contributors making mapping/SDT/output changes.')

y = H - 85
section_title(c, 'Core relationships', y)
y = bullets(c, [
    'Dataset JSON = collected/normalized facts from collectors.',
    'Mapping (mapping.dataset-to-sdt) binds dataset -> SDT tag and declares render hints.',
    'Dataset sidecar metadata (*.assembler.meta.json) declares default presentation intent.',
    'Projection contract (assembler.projections.v1.json) defines shaping: columns/order/format/empty behavior.',
    'Template (.docx/.txt) contains SDT tokens that receive rendered values.',
    'Catalog selects which mapping + template run and names output files.'
], y - 22)

section_title(c, 'Where to modify for common changes', y - 8)
y = bullets(c, [
    'Table layout change: edit assembler.projections.v1.json projection columns/order/format.',
    'Dataset-to-token binding change: edit mapping.dataset-to-sdt.v1.yaml entry dataset/selectors/tag/renderHint.',
    'Default dataset view/presentation change: edit dataset/<name>.assembler.meta.json.',
    'SDT token/template change: edit template and corresponding mapping target.sdtTag (or sdtTag).',
    'Output naming / template selection change: edit templates/skeletons/<tech>/*.catalog.json.'
], y - 22)

section_title(c, 'Operational guidance', y - 8)
y = bullets(c, [
    'Use bundle render entrypoint so __TARGET__/__SYSTEM__ placeholders resolve before SDT render.',
    'Prefer contract-first edits over tech-specific logic in Invoke-AssemblerSdtRender.ps1.',
    'Treat .deps/contracts as synced runtime snapshot; mirror owned handoff artifacts under exports/...'
], y - 22)

section_title(c, 'Quick walkthrough example (HostPortsFC)', y - 8)
bullets(c, [
    '1) Update projection: LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsFC.',
    '2) Verify mapping renderHint.projectionRef points to that projection and dataset host-ports.json.',
    '3) Ensure template contains <<SDT:LNV.Lenovo.DE.System[ArrayName].Tables.HostPortsFC>>.',
    '4) Run Invoke-AssemblerBundleRender.ps1 and review rendered DOCX/TXT + report.'
], y - 22)

c.save()
print(f'Wrote {OUT}')
