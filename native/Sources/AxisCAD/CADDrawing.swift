import CoreGraphics
import CoreText
import Foundation

enum DrawingOutline: Equatable, Sendable {
    case rectangle(x: Double, y: Double, width: Double, height: Double)
    case circle(x: Double, y: Double, radius: Double)
}

struct DrawingProjection: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var width: Double
    var height: Double
    var outlines: [DrawingOutline]
}

struct CADDrawingSheet: Equatable, Sendable {
    var documentName: String
    var documentId: String
    var revision: Int
    var units: String
    var projections: [DrawingProjection]

    static func make(document: CADDocument) -> CADDrawingSheet {
        let instances = document.features.filter { $0.visible && $0.kind == "assembly_instance" }
        if !instances.isEmpty {
            return assemblySheet(document: document, instances: instances)
        }
        let profile = document.features.first { $0.id == "sketch-base" }
        let pad = document.features.first { $0.id == "pad-base" }
        let pockets = document.features.first { $0.id == "pocket-holes" }
        let width = profile?.params["width"] ?? 86
        let height = profile?.params["height"] ?? 54
        let depth = pad?.params["length"] ?? 6
        let radius = (pockets?.params["diameter"] ?? 5) / 2
        let offset = pockets?.params["offset"] ?? 12

        var front: [DrawingOutline] = [.rectangle(x: -width / 2, y: -height / 2, width: width, height: height)]
        if pockets?.visible != false {
            for x in [-width / 2 + offset, width / 2 - offset] {
                for y in [-height / 2 + offset, height / 2 - offset] { front.append(.circle(x: x, y: y, radius: radius)) }
            }
        }
        var top: [DrawingOutline] = [.rectangle(x: -width / 2, y: -depth / 2, width: width, height: depth)]
        var right: [DrawingOutline] = [.rectangle(x: -height / 2, y: -depth / 2, width: height, height: depth)]

        for feature in document.features where feature.visible {
            let x = feature.params["x"] ?? 0, y = feature.params["y"] ?? 0, z = feature.params["z"] ?? 0
            if feature.kind == "box" {
                let w = feature.params["width"] ?? 30, h = feature.params["height"] ?? 24, d = feature.params["depth"] ?? 16
                front.append(.rectangle(x: x - w / 2, y: y - h / 2, width: w, height: h))
                top.append(.rectangle(x: x - w / 2, y: z - d / 2, width: w, height: d))
                right.append(.rectangle(x: y - h / 2, y: z - d / 2, width: h, height: d))
            } else if feature.kind == "cylinder" {
                let r = feature.params["radius"] ?? 8, h = feature.params["height"] ?? 22
                front.append(.circle(x: x, y: y, radius: r))
                top.append(.rectangle(x: x - r, y: z - h / 2, width: r * 2, height: h))
                right.append(.rectangle(x: y - r, y: z - h / 2, width: r * 2, height: h))
            }
        }
        return CADDrawingSheet(documentName: document.name, documentId: document.id, revision: document.revision, units: document.units, projections: [
            DrawingProjection(id: "front", title: "FRONT", width: width, height: height, outlines: front),
            DrawingProjection(id: "top", title: "TOP", width: width, height: max(depth, 24), outlines: top),
            DrawingProjection(id: "right", title: "RIGHT", width: height, height: max(depth, 24), outlines: right)
        ])
    }

    private static func assemblySheet(document: CADDocument, instances: [CADFeature]) -> CADDrawingSheet {
        var front: [DrawingOutline] = [], top: [DrawingOutline] = [], right: [DrawingOutline] = []
        for instance in instances {
            guard let sourceId = instance.inputFeatureIds?.first,
                  let source = document.features.first(where: { $0.id == sourceId }) else { continue }
            let x = (source.params["x"] ?? 0) + (instance.params["x"] ?? 0)
            let y = (source.params["y"] ?? 0) + (instance.params["y"] ?? 0)
            let z = (source.params["z"] ?? 0) + (instance.params["z"] ?? 0)
            switch source.kind {
            case "box":
                let w = source.params["width"] ?? 30, h = source.params["height"] ?? 24, d = source.params["depth"] ?? 16
                front.append(.rectangle(x: x - w / 2, y: y - h / 2, width: w, height: h))
                top.append(.rectangle(x: x - w / 2, y: z - d / 2, width: w, height: d))
                right.append(.rectangle(x: y - h / 2, y: z - d / 2, width: h, height: d))
            case "cylinder", "sphere":
                let r = source.params["radius"] ?? 8
                let h = source.kind == "cylinder" ? source.params["height"] ?? r * 2 : r * 2
                front.append(.circle(x: x, y: y, radius: r))
                top.append(.rectangle(x: x - r, y: z - h / 2, width: r * 2, height: h))
                right.append(.rectangle(x: y - r, y: z - h / 2, width: r * 2, height: h))
            default: continue
            }
        }
        func centered(_ outlines: [DrawingOutline]) -> (outlines: [DrawingOutline], width: Double, height: Double) {
            let xValues = outlines.flatMap { outline -> [Double] in switch outline { case .rectangle(let x, _, let w, _): [x, x + w]; case .circle(let x, _, let r): [x - r, x + r] } }
            let yValues = outlines.flatMap { outline -> [Double] in switch outline { case .rectangle(_, let y, _, let h): [y, y + h]; case .circle(_, let y, let r): [y - r, y + r] } }
            guard let minX = xValues.min(), let maxX = xValues.max(), let minY = yValues.min(), let maxY = yValues.max() else { return ([], 100, 100) }
            let centerX = (minX + maxX) / 2, centerY = (minY + maxY) / 2
            let translated = outlines.map { outline -> DrawingOutline in
                switch outline {
                case .rectangle(let x, let y, let w, let h): .rectangle(x: x - centerX, y: y - centerY, width: w, height: h)
                case .circle(let x, let y, let r): .circle(x: x - centerX, y: y - centerY, radius: r)
                }
            }
            return (translated, max(100, maxX - minX), max(100, maxY - minY))
        }
        let frontView = centered(front), topView = centered(top), rightView = centered(right)
        return CADDrawingSheet(documentName: document.name, documentId: document.id, revision: document.revision, units: document.units, projections: [
            DrawingProjection(id: "front", title: "ASSEMBLY FRONT", width: frontView.width, height: frontView.height, outlines: frontView.outlines),
            DrawingProjection(id: "top", title: "ASSEMBLY TOP", width: topView.width, height: topView.height, outlines: topView.outlines),
            DrawingProjection(id: "right", title: "ASSEMBLY RIGHT", width: rightView.width, height: rightView.height, outlines: rightView.outlines)
        ])
    }
}

enum DrawingPDFExporter {
    static let pageSize = CGSize(width: 842, height: 595)

    static func write(sheet: CADDrawingSheet, to url: URL) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(mediaBox)
        context.setStrokeColor(CGColor(red: 0.08, green: 0.16, blue: 0.22, alpha: 1)); context.setLineWidth(0.8)

        let viewRects = [CGRect(x: 38, y: 235, width: 490, height: 315), CGRect(x: 38, y: 70, width: 490, height: 130), CGRect(x: 560, y: 235, width: 240, height: 315)]
        for (projection, rect) in zip(sheet.projections, viewRects) { draw(projection: projection, in: rect, context: context, units: sheet.units) }
        drawTitleBlock(sheet: sheet, context: context)
        context.endPDFPage(); context.closePDF()
    }

    private static func draw(projection: DrawingProjection, in rect: CGRect, context: CGContext, units: String) {
        context.saveGState()
        context.setStrokeColor(CGColor(gray: 0.78, alpha: 1)); context.stroke(rect)
        drawText(projection.title, at: CGPoint(x: rect.minX + 6, y: rect.maxY - 16), size: 8, bold: true, context: context, color: CGColor(gray: 0.25, alpha: 1))
        let scale = min((rect.width - 44) / max(projection.width, 1), (rect.height - 54) / max(projection.height, 1))
        let center = CGPoint(x: rect.midX, y: rect.midY - 4)
        context.setStrokeColor(CGColor(red: 0.05, green: 0.28, blue: 0.43, alpha: 1)); context.setLineWidth(1.1)
        for outline in projection.outlines {
            switch outline {
            case .rectangle(let x, let y, let width, let height):
                context.stroke(CGRect(x: center.x + x * scale, y: center.y + y * scale, width: width * scale, height: height * scale))
            case .circle(let x, let y, let radius):
                context.strokeEllipse(in: CGRect(x: center.x + (x - radius) * scale, y: center.y + (y - radius) * scale, width: radius * 2 * scale, height: radius * 2 * scale))
                context.setLineWidth(0.45)
                context.move(to: CGPoint(x: center.x + (x - radius - 2) * scale, y: center.y + y * scale)); context.addLine(to: CGPoint(x: center.x + (x + radius + 2) * scale, y: center.y + y * scale))
                context.move(to: CGPoint(x: center.x + x * scale, y: center.y + (y - radius - 2) * scale)); context.addLine(to: CGPoint(x: center.x + x * scale, y: center.y + (y + radius + 2) * scale)); context.strokePath(); context.setLineWidth(1.1)
            }
        }
        drawDimension(from: CGPoint(x: center.x - projection.width * scale / 2, y: rect.minY + 18), to: CGPoint(x: center.x + projection.width * scale / 2, y: rect.minY + 18), label: "\(format(projection.width)) \(units)", context: context)
        context.restoreGState()
    }

    private static func drawDimension(from: CGPoint, to: CGPoint, label: String, context: CGContext) {
        context.setStrokeColor(CGColor(red: 0.15, green: 0.42, blue: 0.64, alpha: 1)); context.setLineWidth(0.55)
        context.move(to: from); context.addLine(to: to)
        context.move(to: CGPoint(x: from.x, y: from.y - 4)); context.addLine(to: CGPoint(x: from.x, y: from.y + 4))
        context.move(to: CGPoint(x: to.x, y: to.y - 4)); context.addLine(to: CGPoint(x: to.x, y: to.y + 4)); context.strokePath()
        drawText(label, at: CGPoint(x: (from.x + to.x) / 2 - 16, y: from.y + 4), size: 7, bold: false, context: context, color: CGColor(red: 0.15, green: 0.42, blue: 0.64, alpha: 1))
    }

    private static func drawTitleBlock(sheet: CADDrawingSheet, context: CGContext) {
        let block = CGRect(x: 540, y: 35, width: 262, height: 145)
        context.setStrokeColor(CGColor(gray: 0.18, alpha: 1)); context.setLineWidth(0.8); context.stroke(block)
        context.move(to: CGPoint(x: block.minX, y: block.minY + 42)); context.addLine(to: CGPoint(x: block.maxX, y: block.minY + 42))
        context.move(to: CGPoint(x: block.minX, y: block.minY + 82)); context.addLine(to: CGPoint(x: block.maxX, y: block.minY + 82)); context.strokePath()
        drawText("AXIS CAD STUDIO", at: CGPoint(x: block.minX + 10, y: block.maxY - 24), size: 9, bold: true, context: context, color: CGColor(gray: 0.12, alpha: 1))
        drawText(sheet.documentName, at: CGPoint(x: block.minX + 10, y: block.minY + 55), size: 15, bold: true, context: context, color: CGColor(gray: 0.08, alpha: 1))
        drawText("ID  \(sheet.documentId)", at: CGPoint(x: block.minX + 10, y: block.minY + 25), size: 7, bold: false, context: context, color: CGColor(gray: 0.3, alpha: 1))
        drawText("REV \(sheet.revision)    UNITS \(sheet.units.uppercased())    SHEET 1 / 1", at: CGPoint(x: block.minX + 10, y: block.minY + 9), size: 7, bold: false, context: context, color: CGColor(gray: 0.3, alpha: 1))
        drawText("A4 LANDSCAPE  |  THIRD ANGLE", at: CGPoint(x: block.minX + 10, y: block.maxY - 40), size: 7, bold: false, context: context, color: CGColor(gray: 0.3, alpha: 1))
    }

    private static func drawText(_ text: String, at point: CGPoint, size: CGFloat, bold: Bool, context: CGContext, color: CGColor) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point; CTLineDraw(line, context)
    }

    private static func format(_ value: Double) -> String { value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value) }
}

enum DrawingDXFExporter {
    static func write(sheet: CADDrawingSheet, to url: URL) throws {
        var lines = ["0", "SECTION", "2", "HEADER", "9", "$INSUNITS", "70", "4", "0", "ENDSEC", "0", "SECTION", "2", "ENTITIES"]
        let offsets: [(Double, Double)] = [(0, 0), (0, -100), (140, 0)]
        for (projection, offset) in zip(sheet.projections, offsets) {
            for outline in projection.outlines {
                switch outline {
                case .rectangle(let x, let y, let width, let height):
                    appendLine(&lines, x + offset.0, y + offset.1, x + width + offset.0, y + offset.1, layer: projection.title)
                    appendLine(&lines, x + width + offset.0, y + offset.1, x + width + offset.0, y + height + offset.1, layer: projection.title)
                    appendLine(&lines, x + width + offset.0, y + height + offset.1, x + offset.0, y + height + offset.1, layer: projection.title)
                    appendLine(&lines, x + offset.0, y + height + offset.1, x + offset.0, y + offset.1, layer: projection.title)
                case .circle(let x, let y, let radius):
                    lines += ["0", "CIRCLE", "8", projection.title, "10", format(x + offset.0), "20", format(y + offset.1), "30", "0", "40", format(radius)]
                }
            }
        }
        lines += ["0", "ENDSEC", "0", "EOF"]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func appendLine(_ lines: inout [String], _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, layer: String) {
        lines += ["0", "LINE", "8", layer, "10", format(x1), "20", format(y1), "30", "0", "11", format(x2), "21", format(y2), "31", "0"]
    }

    private static func format(_ value: Double) -> String { String(format: "%.6f", value) }
}
