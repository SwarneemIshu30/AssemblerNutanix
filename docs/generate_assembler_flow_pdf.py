from reportlab.lib.pagesizes import landscape, A4
from reportlab.lib import colors
from reportlab.pdfgen import canvas

W, H = landscape(A4)
OUT_V1 = 'docs/assembler-mapping-flow.pdf'
OUT_V2 = 'docs/assembler-mapping-flow-v2-swimlanes.pdf'


def box(c, x, y, w, h, title, lines, fill=colors.whitesmoke, title_size=10, body_size=8.5):
    c.setStrokeColor(colors.black)
    c.setFillColor(fill)
    c.roundRect(x, y, w, h, 8, stroke=1, fill=1)
    c.setFillColor(colors.black)
    c.setFont('Helvetica-Bold', title_size)
    c.drawString(x + 8, y + h - 16, title)
    c.setFont('Helvetica', body_size)
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


def generate_v1(path):
    c = canvas.Canvas(path, pagesize=(W, H))

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

    # PAGE 2 text
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


def generate_v2_swimlanes(path):
    c = canvas.Canvas(path, pagesize=(W, H))
    c.setFont('Helvetica-Bold', 18)
    c.drawString(30, H - 35, 'Assembler Flow V2 (Swimlanes by Owner)')
    c.setFont('Helvetica', 10)
    c.drawString(30, H - 52, 'Owner lanes: Collector / Contracts / Assembler / Template Owners')

    lane_x = 30
    lane_w = W - 60
    lane_h = 115
    lane_gap = 14
    top = H - 80

    lanes = [
        ('Collector', colors.HexColor('#E8F1FF'), [
            'Emits bundle datasets in lnv.collector.dataset.v1 envelope',
            'Path pattern: bundle/<id>/datasets/<tech>/<target>/<system>/<dataset>.json',
            'Normalization should happen upstream for document-facing use'
        ]),
        ('Contracts', colors.HexColor('#FFF3E8'), [
            'mapping.dataset-to-sdt.v1.yaml = authoritative dataset->SDT bindings',
            'assembler.projections.v1.json = table/list/scalar shaping',
            'dataset/*.assembler.meta.json = presentation intent + preferred views'
        ]),
        ('Assembler', colors.HexColor('#EFFFF0'), [
            'Invoke-AssemblerBundleRender resolves placeholders and selects catalog entries',
            'Invoke-AssemblerSdtRender applies selectors/renderHint/projectionRef',
            'Populates tokens and emits render reports'
        ]),
        ('Template Owners', colors.HexColor('#F3EEFF'), [
            'Maintain SDT token locations in DOCX/TXT templates',
            'Maintain catalog entry mappingPath/templatePath/outputFileName',
            'Validate rendered document readability and section intent'
        ])
    ]

    y = top - lane_h
    centers = []
    for name, color, lines in lanes:
        box(c, lane_x, y, lane_w, lane_h, name, lines, fill=color, title_size=12, body_size=9)
        centers.append((lane_x + lane_w / 2, y + lane_h / 2))
        y -= lane_h + lane_gap

    for i in range(len(centers) - 1):
        arrow(c, centers[i][0], centers[i][1] - lane_h / 2 + 8, centers[i + 1][0], centers[i + 1][1] + lane_h / 2 - 8)

    c.setFont('Helvetica-Bold', 12)
    c.drawString(30, 88, 'Change routing guide (fast):')
    c.setFont('Helvetica', 10)
    c.drawString(42, 70, u'• Dataset content issue -> Collector lane first')
    c.drawString(42, 56, u'• Wrong SDT binding/projection selection -> Contracts lane first')
    c.drawString(42, 42, u'• Render mechanics issue -> Assembler lane (generic capability only)')
    c.drawString(42, 28, u'• Token placement/output naming issue -> Template Owners lane')

    c.save()


def main():
    generate_v1(OUT_V1)
    generate_v2_swimlanes(OUT_V2)
    print(f'Wrote {OUT_V1}')
    print(f'Wrote {OUT_V2}')


if __name__ == '__main__':
    main()
