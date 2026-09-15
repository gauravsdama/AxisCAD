import SwiftUI

struct DrawingSheetView: View {
    let sheet: CADDrawingSheet
    let onExportPDF: () -> Void
    let onExportDXF: () -> Void
    let onReturnToModel: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let page = fittedPage(in: geometry.size)
            ZStack(alignment: .bottomTrailing) {
                Color(red: 0.035, green: 0.048, blue: 0.052)
                Canvas { context, _ in drawSheet(context: &context, page: page) }
                HStack(spacing: 8) {
                    Button("Return to 3D model", systemImage: "cube") { onReturnToModel() }
                    Label("A4 · 1:1", systemImage: "doc.text")
                    Menu {
                        Button("Vector PDF", systemImage: "doc.richtext", action: onExportPDF)
                        Button("Editable DXF", systemImage: "square.and.arrow.up", action: onExportDXF)
                    } label: { Label("Export drawing", systemImage: "square.and.arrow.up") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .padding(18)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Technical drawing for \(sheet.documentName), revision \(sheet.revision)")
    }

    private func fittedPage(in size: CGSize) -> CGRect {
        let margin: CGFloat = 28
        let scale = min((size.width - margin * 2) / DrawingPDFExporter.pageSize.width, (size.height - margin * 2) / DrawingPDFExporter.pageSize.height)
        let pageSize = CGSize(width: DrawingPDFExporter.pageSize.width * scale, height: DrawingPDFExporter.pageSize.height * scale)
        return CGRect(x: (size.width - pageSize.width) / 2, y: (size.height - pageSize.height) / 2, width: pageSize.width, height: pageSize.height)
    }

    private func drawSheet(context: inout GraphicsContext, page: CGRect) {
        context.fill(Path(page), with: .color(.white))
        context.stroke(Path(page), with: .color(Color.black.opacity(0.3)), lineWidth: 1)
        let sx = page.width / DrawingPDFExporter.pageSize.width, sy = page.height / DrawingPDFExporter.pageSize.height
        func mapped(_ rect: CGRect) -> CGRect {
            CGRect(x: page.minX + rect.minX * sx, y: page.minY + (DrawingPDFExporter.pageSize.height - rect.maxY) * sy, width: rect.width * sx, height: rect.height * sy)
        }
        let viewRects = [CGRect(x: 38, y: 235, width: 490, height: 315), CGRect(x: 38, y: 70, width: 490, height: 130), CGRect(x: 560, y: 235, width: 240, height: 315)]
        for (projection, sourceRect) in zip(sheet.projections, viewRects) { draw(projection: projection, in: mapped(sourceRect), context: &context) }
        drawTitleBlock(in: mapped(CGRect(x: 540, y: 35, width: 262, height: 145)), context: &context)
    }

    private func draw(projection: DrawingProjection, in rect: CGRect, context: inout GraphicsContext) {
        context.stroke(Path(rect), with: .color(Color.black.opacity(0.18)), lineWidth: 0.7)
        context.draw(Text(projection.title).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(.black.opacity(0.7)), at: CGPoint(x: rect.minX + 22, y: rect.minY + 12))
        let scale = min((rect.width - 44) / max(projection.width, 1), (rect.height - 48) / max(projection.height, 1))
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for outline in projection.outlines {
            var path = Path()
            switch outline {
            case .rectangle(let x, let y, let width, let height):
                path.addRect(CGRect(x: center.x + x * scale, y: center.y - (y + height) * scale, width: width * scale, height: height * scale))
            case .circle(let x, let y, let radius):
                let circle = CGRect(x: center.x + (x - radius) * scale, y: center.y - (y + radius) * scale, width: radius * 2 * scale, height: radius * 2 * scale)
                path.addEllipse(in: circle)
                var centerline = Path()
                centerline.move(to: CGPoint(x: circle.minX - 3, y: circle.midY)); centerline.addLine(to: CGPoint(x: circle.maxX + 3, y: circle.midY))
                centerline.move(to: CGPoint(x: circle.midX, y: circle.minY - 3)); centerline.addLine(to: CGPoint(x: circle.midX, y: circle.maxY + 3))
                context.stroke(centerline, with: .color(Color.blue.opacity(0.48)), lineWidth: 0.45)
            }
            context.stroke(path, with: .color(Color(red: 0.04, green: 0.27, blue: 0.41)), lineWidth: 1)
        }
        let dimensionY = rect.maxY - 14
        var dimension = Path()
        let left = center.x - projection.width * scale / 2, right = center.x + projection.width * scale / 2
        dimension.move(to: CGPoint(x: left, y: dimensionY)); dimension.addLine(to: CGPoint(x: right, y: dimensionY))
        dimension.move(to: CGPoint(x: left, y: dimensionY - 4)); dimension.addLine(to: CGPoint(x: left, y: dimensionY + 4))
        dimension.move(to: CGPoint(x: right, y: dimensionY - 4)); dimension.addLine(to: CGPoint(x: right, y: dimensionY + 4))
        context.stroke(dimension, with: .color(.blue.opacity(0.65)), lineWidth: 0.55)
        context.draw(Text("\(format(projection.width)) \(sheet.units)").font(.system(size: 7, design: .monospaced)).foregroundColor(.blue), at: CGPoint(x: (left + right) / 2, y: dimensionY - 7))
    }

    private func drawTitleBlock(in block: CGRect, context: inout GraphicsContext) {
        context.stroke(Path(block), with: .color(.black.opacity(0.75)), lineWidth: 0.8)
        context.draw(Text("AXIS CAD STUDIO").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(.black), at: CGPoint(x: block.minX + 47, y: block.minY + 16))
        context.draw(Text(sheet.documentName).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(.black), at: CGPoint(x: block.midX, y: block.midY))
        context.draw(Text("REV \(sheet.revision)  ·  \(sheet.units.uppercased())  ·  SHEET 1/1").font(.system(size: 7, design: .monospaced)).foregroundColor(.black.opacity(0.65)), at: CGPoint(x: block.midX, y: block.maxY - 18))
    }

    private func format(_ value: Double) -> String { value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value) }
}
