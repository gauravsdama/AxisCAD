import SwiftUI
import simd

struct ProfileSketchEditorView: View {
    enum Tool: String, CaseIterable {
        case select = "Select", line = "Line", arc = "Arc", circle = "Circle"

        var shortcut: String {
            switch self {
            case .select: "V"
            case .line: "L"
            case .arc: "A"
            case .circle: "C"
            }
        }
    }

    let feature: CADFeature
    let units: String
    let onAdd: (CADSketchEntity) -> Void
    let onDelete: (String) -> Void
    let onToggleConstruction: (String) -> Void
    let onAddConstraint: (CADSketchConstraint) -> Void
    let onUpdateConstraint: (String, Double) -> Void
    let onTrimExtend: (String, String, String, String) -> Void
    let onExtrude: () -> Void
    let onFinish: () -> Void

    @State private var tool: Tool = .line
    @State private var pendingPoint: SIMD2<Double>?
    @State private var arcStartPoint: SIMD2<Double>?
    @State private var selectedEntityId: String?
    @State private var referenceEntityId: String?
    @State private var constructionMode = false
    @State private var dimensionEdit: DimensionEdit?
    @State private var activeLoopId = "outer"

    private var solution: CADProfileSketchSolution { CADProfileSketch.solve(feature: feature) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { proxy in
                let transform = SketchCanvasTransform(size: proxy.size, solution: solution)
                Canvas { context, size in
                    drawGrid(context: &context, size: size, transform: transform)
                    drawAxes(context: &context, size: size, transform: transform)
                    for entity in feature.sketch?.entities ?? [] { draw(entity: entity, context: &context, transform: transform) }
                    drawDimensions(context: &context, transform: transform)
                    if let pendingPoint {
                        let point = transform.view(pendingPoint)
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(.orange))
                    }
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { event in handleTap(event.location, transform: transform) })
                .overlay(alignment: .bottomLeading) {
                    Text(toolHint)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).padding(12)
                }
            }
            statusBar
        }
        .background(Color(red: 0.045, green: 0.06, blue: 0.065))
        .sheet(item: $dimensionEdit) { edit in
            DimensionEditor(edit: edit, units: units) { value in
                onUpdateConstraint(edit.id, value)
                dimensionEdit = nil
            } onCancel: { dimensionEdit = nil }
        }
        .onKeyPress { press in
            guard dimensionEdit == nil else { return .ignored }
            if press.key == .delete || press.key == .deleteForward {
                guard let selectedEntityId else { return .ignored }
                onDelete(selectedEntityId)
                if referenceEntityId == selectedEntityId { referenceEntityId = nil }
                self.selectedEntityId = nil
                return .handled
            }
            if press.key == .escape {
                pendingPoint = nil; arcStartPoint = nil; selectedEntityId = nil
                return .handled
            }
            let nextTool: Tool? = switch press.characters.lowercased() {
            case "v": .select
            case "l": .line
            case "a": .arc
            case "c": .circle
            default: nil
            }
            guard let nextTool else { return .ignored }
            tool = nextTool; pendingPoint = nil; arcStartPoint = nil
            return .handled
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(feature.name).font(.system(size: 14, weight: .semibold))
            Text(feature.sketch?.plane ?? "XY").font(.caption.monospaced()).foregroundStyle(.secondary)
            Divider().frame(height: 22)
            Picker("Tool", selection: $tool) {
                ForEach(Tool.allCases, id: \.self) { tool in Text("\(tool.rawValue) (\(tool.shortcut))").tag(tool) }
            }.pickerStyle(.segmented).frame(width: 260).onChange(of: tool) { pendingPoint = nil; arcStartPoint = nil }
            Menu(activeLoopId == "outer" ? "Outer profile" : activeLoopId.replacingOccurrences(of: "-", with: " ").capitalized) {
                Button("Outer profile") { selectLoop("outer") }
                ForEach(existingHoleLoopIds, id: \.self) { loopId in Button(loopId.replacingOccurrences(of: "-", with: " ").capitalized) { selectLoop(loopId) } }
                Divider()
                Button("New hole loop") { selectLoop(nextHoleLoopId) }
            }.buttonStyle(.bordered)
            Toggle("Construction", isOn: $constructionMode).toggleStyle(.checkbox).font(.caption)
            if let selectedEntityId {
                if let selected = feature.sketch?.entities?.first(where: { $0.id == selectedEntityId }) {
                    Menu("Constrain") {
                        if selected.kind == "line" {
                            Button("Horizontal") { addConstraint(kind: "horizontal", entity: selected) }
                            Button("Vertical") { addConstraint(kind: "vertical", entity: selected) }
                            if let constraint = dimensionConstraint(kind: "length", entityId: selected.id), let value = constraint.value {
                                Button("Edit length…") { dimensionEdit = DimensionEdit(id: constraint.id, kind: "Length", value: value) }
                            } else { Button("Lock current length") { addConstraint(kind: "length", entity: selected) } }
                        }
                        if ["circle", "arc"].contains(selected.kind) {
                            if let constraint = dimensionConstraint(kind: "radius", entityId: selected.id), let value = constraint.value {
                                Button("Edit radius…") { dimensionEdit = DimensionEdit(id: constraint.id, kind: "Radius", value: value) }
                            } else { Button("Lock current radius") { addConstraint(kind: "radius", entity: selected) } }
                        }
                        if let referenceEntityId, referenceEntityId != selected.id, let reference = feature.sketch?.entities?.first(where: { $0.id == referenceEntityId }) {
                            Divider()
                            if reference.kind == "line", selected.kind == "line" {
                                Button("Parallel to \(reference.nameLabel)") { addRelationalConstraint(kind: "parallel", reference: reference, entity: selected) }
                                Button("Perpendicular to \(reference.nameLabel)") { addRelationalConstraint(kind: "perpendicular", reference: reference, entity: selected) }
                                Button("Equal length to \(reference.nameLabel)") { addRelationalConstraint(kind: "equal", reference: reference, entity: selected) }
                                if let constraint = relationalDimensionConstraint(kind: "angle", referenceId: reference.id, entityId: selected.id), let value = constraint.value {
                                    Button("Edit angle to \(reference.nameLabel)…") { dimensionEdit = DimensionEdit(id: constraint.id, kind: "Angle", value: value) }
                                } else if let degrees = angleDegrees(reference: reference, entity: selected) {
                                    Button("Lock \(degrees.formatted(.number.precision(.fractionLength(0...2))))° to \(reference.nameLabel)") { addRelationalConstraint(kind: "angle", reference: reference, entity: selected, value: degrees) }
                                }
                            }
                            if ["circle", "arc"].contains(reference.kind), ["circle", "arc"].contains(selected.kind) {
                                Button("Equal radius to \(reference.nameLabel)") { addRelationalConstraint(kind: "equal", reference: reference, entity: selected) }
                                Button("Tangent to \(reference.nameLabel)") { addRelationalConstraint(kind: "tangent", reference: reference, entity: selected) }
                            }
                            if (reference.kind == "line" && ["circle", "arc"].contains(selected.kind)) || (selected.kind == "line" && ["circle", "arc"].contains(reference.kind)) {
                                Button("Tangent to \(reference.nameLabel)") { addRelationalConstraint(kind: "tangent", reference: reference, entity: selected) }
                            }
                        }
                    }.buttonStyle(.bordered)
                    Menu("Geometry") {
                        Button(referenceEntityId == selected.id ? "Clear reference" : "Set as reference") { referenceEntityId = referenceEntityId == selected.id ? nil : selected.id }
                        if let referenceEntityId, referenceEntityId != selected.id,
                           let reference = feature.sketch?.entities?.first(where: { $0.id == referenceEntityId }), selected.kind == "line", reference.kind == "line" {
                            Menu("Trim or extend to \(reference.nameLabel)") {
                                Button("Trim start") { onTrimExtend(selected.id, reference.id, "start", "trim") }
                                Button("Trim end") { onTrimExtend(selected.id, reference.id, "end", "trim") }
                                Divider()
                                Button("Extend start") { onTrimExtend(selected.id, reference.id, "start", "extend") }
                                Button("Extend end") { onTrimExtend(selected.id, reference.id, "end", "extend") }
                            }
                        }
                        Button(selected.construction ? "Convert to profile" : "Convert to construction") { onToggleConstruction(selectedEntityId) }
                        Divider()
                        Button("Delete geometry", role: .destructive) { onDelete(selectedEntityId); if referenceEntityId == selectedEntityId { referenceEntityId = nil }; self.selectedEntityId = nil }
                    }.buttonStyle(.bordered)
                }
            }
            Spacer()
            if solution.isClosed {
                Button("Extrude 20 \(units)") { onExtrude() }.buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black)
            }
            Button("Finish") { onFinish() }.buttonStyle(.bordered)
        }.padding(.horizontal, 14).frame(height: 48).background(Color.white.opacity(0.035))
    }

    private var statusBar: some View {
        HStack {
            Label(solution.isClosed ? "Closed profile" : "Open profile", systemImage: solution.isClosed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(solution.isClosed ? Color.mint : Color.orange)
            Text("\(solution.entities.count) entities")
            Text("\(profileLoopCount) loops")
            Text("\(solution.constraintCount) constraints · \(solution.degreesOfFreedom) DOF")
            if let error = solution.errors.last { Text(error).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Text("Grid 1 \(units) · snaps enabled").foregroundStyle(.secondary)
        }.font(.system(size: 9, design: .monospaced)).padding(.horizontal, 12).frame(height: 30).background(Color.black.opacity(0.2))
    }

    private func handleTap(_ location: CGPoint, transform: SketchCanvasTransform) {
        let raw = transform.model(location), point = snapped(raw, transform: transform)
        switch tool {
        case .line:
            if let start = pendingPoint {
                guard simd_distance(start, point) > 0.000_001 else { return }
                onAdd(CADSketchEntity(id: nextId(prefix: "line"), kind: "line", params: ["x1": start.x, "y1": start.y, "x2": point.x, "y2": point.y], construction: constructionMode, loopId: activeLoopId))
                pendingPoint = point
            } else { pendingPoint = point }
        case .arc:
            if let center = pendingPoint, let start = arcStartPoint {
                let radius = simd_distance(center, start); guard radius > 0.1 else { return }
                let startAngle = atan2(start.y - center.y, start.x - center.x)
                let endAngle = atan2(point.y - center.y, point.x - center.x)
                guard abs(endAngle - startAngle) > 0.000_1 else { return }
                onAdd(CADSketchEntity(id: nextId(prefix: "arc"), kind: "arc", params: ["cx": center.x, "cy": center.y, "radius": radius, "start_angle": startAngle, "end_angle": endAngle, "ccw": 1], construction: constructionMode, loopId: activeLoopId))
                pendingPoint = nil; arcStartPoint = nil
            } else if pendingPoint != nil { arcStartPoint = point }
            else { pendingPoint = point }
        case .circle:
            if let center = pendingPoint {
                let radius = simd_distance(center, point); guard radius > 0.1 else { return }
                onAdd(CADSketchEntity(id: nextId(prefix: "circle"), kind: "circle", params: ["cx": center.x, "cy": center.y, "radius": radius], construction: constructionMode, loopId: activeLoopId))
                pendingPoint = nil
            } else { pendingPoint = point }
        case .select:
            selectedEntityId = nearestEntity(to: raw, tolerance: 8 / transform.scale)
        }
    }

    private func snapped(_ point: SIMD2<Double>, transform: SketchCanvasTransform) -> SIMD2<Double> {
        let candidates = (feature.sketch?.entities ?? []).flatMap { entity -> [SIMD2<Double>] in
            if ["line", "arc"].contains(entity.kind) { return [CADProfileSketch.endpoint(entity, start: true), CADProfileSketch.endpoint(entity, start: false)].compactMap { $0 } }
            return []
        }
        if let nearest = candidates.min(by: { simd_distance($0, point) < simd_distance($1, point) }), simd_distance(nearest, point) * transform.scale <= 10 { return nearest }
        return SIMD2(point.x.rounded(), point.y.rounded())
    }

    private var toolHint: String {
        switch tool {
        case .line: "Click connected endpoints · click the first point to close"
        case .arc: arcStartPoint == nil ? (pendingPoint == nil ? "Click arc center" : "Click arc start") : "Click arc end"
        case .circle: "Click center, then radius"
        case .select: "Click geometry to select"
        }
    }

    private func nextId(prefix: String) -> String {
        let existing = Set((feature.sketch?.entities ?? []).map(\.id)); var suffix = 1
        while existing.contains("\(prefix)-\(suffix)") { suffix += 1 }
        return "\(prefix)-\(suffix)"
    }

    private var existingHoleLoopIds: [String] { Array(Set((feature.sketch?.entities ?? []).map(\.profileLoopId).filter { $0 != "outer" })).sorted() }
    private var profileLoopCount: Int { Set(solution.entities.map(\.profileLoopId)).count }
    private var nextHoleLoopId: String {
        let existing = Set(existingHoleLoopIds); var suffix = 1
        while existing.contains("hole-\(suffix)") { suffix += 1 }
        return "hole-\(suffix)"
    }
    private func selectLoop(_ loopId: String) { activeLoopId = loopId; pendingPoint = nil; arcStartPoint = nil }

    private func addConstraint(kind: String, entity: CADSketchEntity) {
        let value: Double? = switch kind {
        case "length": CADProfileSketch.endpoint(entity, start: true).flatMap { start in CADProfileSketch.endpoint(entity, start: false).map { simd_distance(start, $0) } }
        case "radius": entity.params["radius"]
        default: nil
        }
        let existing = Set((feature.sketch?.constraints ?? []).map(\.id)); var suffix = 1
        while existing.contains("\(kind)-\(suffix)") { suffix += 1 }
        onAddConstraint(CADSketchConstraint(id: "\(kind)-\(suffix)", kind: kind, entities: [entity.id], value: value))
    }

    private func addRelationalConstraint(kind: String, reference: CADSketchEntity, entity: CADSketchEntity, value: Double? = nil) {
        let existing = Set((feature.sketch?.constraints ?? []).map(\.id)); var suffix = 1
        while existing.contains("\(kind)-\(suffix)") { suffix += 1 }
        onAddConstraint(CADSketchConstraint(id: "\(kind)-\(suffix)", kind: kind, entities: [reference.id, entity.id], value: value))
    }

    private func dimensionConstraint(kind: String, entityId: String) -> CADSketchConstraint? {
        feature.sketch?.constraints.first { $0.kind == kind && $0.entities == [entityId] }
    }

    private func relationalDimensionConstraint(kind: String, referenceId: String, entityId: String) -> CADSketchConstraint? {
        feature.sketch?.constraints.first { $0.kind == kind && $0.entities == [referenceId, entityId] }
    }

    private func angleDegrees(reference: CADSketchEntity, entity: CADSketchEntity) -> Double? {
        guard let referenceStart = CADProfileSketch.endpoint(reference, start: true), let referenceEnd = CADProfileSketch.endpoint(reference, start: false),
              let entityStart = CADProfileSketch.endpoint(entity, start: true), let entityEnd = CADProfileSketch.endpoint(entity, start: false) else { return nil }
        let referenceVector = referenceEnd - referenceStart, entityVector = entityEnd - entityStart
        let denominator = simd_length(referenceVector) * simd_length(entityVector)
        guard denominator > 0.000_001 else { return nil }
        let cosine = max(-1, min(1, simd_dot(referenceVector, entityVector) / denominator))
        let degrees = acos(cosine) * 180 / .pi
        return degrees > 0.000_1 && degrees < 179.999_9 ? degrees : nil
    }

    private func drawDimensions(context: inout GraphicsContext, transform: SketchCanvasTransform) {
        for constraint in feature.sketch?.constraints ?? [] {
            guard ["length", "radius", "angle"].contains(constraint.kind), let value = constraint.value,
                  let entityId = constraint.entities.last, let entity = feature.sketch?.entities?.first(where: { $0.id == entityId }) else { continue }
            let anchor: SIMD2<Double>?
            if constraint.kind == "length", let start = CADProfileSketch.endpoint(entity, start: true), let end = CADProfileSketch.endpoint(entity, start: false) { anchor = (start + end) / 2 + SIMD2(0, 1.5) }
            else if let cx = entity.params["cx"], let cy = entity.params["cy"], let radius = entity.params["radius"] { anchor = SIMD2(cx, cy + radius + 1.5) }
            else if constraint.kind == "angle", let start = CADProfileSketch.endpoint(entity, start: true), let end = CADProfileSketch.endpoint(entity, start: false) {
                let direction = end - start, length = simd_length(direction)
                let normal = length > 0.000_001 ? SIMD2(-direction.y, direction.x) / length : SIMD2(0, 1)
                anchor = (start + end) / 2 + normal * 1.5
            }
            else { anchor = nil }
            if let anchor {
                let suffix = constraint.kind == "angle" ? "°" : " \(units)"
                context.draw(Text("\(value.formatted(.number.precision(.fractionLength(0...2))))\(suffix)").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.yellow), at: transform.view(anchor))
            }
        }
    }

    private func nearestEntity(to point: SIMD2<Double>, tolerance: Double) -> String? {
        (feature.sketch?.entities ?? []).compactMap { entity -> (String, Double)? in
            if entity.kind == "circle", let cx = entity.params["cx"], let cy = entity.params["cy"], let radius = entity.params["radius"] {
                return (entity.id, abs(simd_distance(point, SIMD2(cx, cy)) - radius))
            }
            guard let a = CADProfileSketch.endpoint(entity, start: true), let b = CADProfileSketch.endpoint(entity, start: false) else { return nil }
            let ab = b - a, denominator = simd_length_squared(ab), t = denominator > 0 ? max(0, min(1, simd_dot(point - a, ab) / denominator)) : 0
            return (entity.id, simd_distance(point, a + ab * t))
        }.filter { $0.1 <= tolerance }.min { $0.1 < $1.1 }?.0
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize, transform: SketchCanvasTransform) {
        let spacing = max(transform.scale, 8), center = transform.view(.zero)
        var path = Path()
        var x = center.x.truncatingRemainder(dividingBy: spacing); while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += spacing }
        var y = center.y.truncatingRemainder(dividingBy: spacing); while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += spacing }
        context.stroke(path, with: .color(.white.opacity(0.045)), lineWidth: 0.5)
    }

    private func drawAxes(context: inout GraphicsContext, size: CGSize, transform: SketchCanvasTransform) {
        let origin = transform.view(.zero); var path = Path()
        path.move(to: CGPoint(x: 0, y: origin.y)); path.addLine(to: CGPoint(x: size.width, y: origin.y)); path.move(to: CGPoint(x: origin.x, y: 0)); path.addLine(to: CGPoint(x: origin.x, y: size.height))
        context.stroke(path, with: .color(.mint.opacity(0.35)), lineWidth: 1)
    }

    private func draw(entity: CADSketchEntity, context: inout GraphicsContext, transform: SketchCanvasTransform) {
        var path = Path()
        if entity.kind == "line", let a = CADProfileSketch.endpoint(entity, start: true), let b = CADProfileSketch.endpoint(entity, start: false) {
            path.move(to: transform.view(a)); path.addLine(to: transform.view(b))
        } else if entity.kind == "circle", let cx = entity.params["cx"], let cy = entity.params["cy"], let radius = entity.params["radius"] {
            let center = transform.view(SIMD2(cx, cy)), r = radius * transform.scale
            path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        } else if entity.kind == "arc", let cx = entity.params["cx"], let cy = entity.params["cy"], let radius = entity.params["radius"], let start = entity.params["start_angle"], let end = entity.params["end_angle"] {
            let center = transform.view(SIMD2(cx, cy)); path.addArc(center: center, radius: radius * transform.scale, startAngle: .radians(-start), endAngle: .radians(-end), clockwise: entity.params["ccw"] == 0)
        }
        let selected = entity.id == selectedEntityId, reference = entity.id == referenceEntityId, activeLoop = entity.profileLoopId == activeLoopId
        context.stroke(path, with: .color(selected ? .orange : reference ? .blue : entity.construction || !activeLoop ? .gray : .mint), style: StrokeStyle(lineWidth: selected || reference ? 2.5 : activeLoop ? 1.8 : 1.2, dash: entity.construction ? [5, 4] : []))
    }
}

private extension CADSketchEntity {
    var nameLabel: String { id.replacingOccurrences(of: "-", with: " ") }
}

private struct DimensionEdit: Identifiable {
    let id: String
    let kind: String
    let value: Double
}

private struct DimensionEditor: View {
    let edit: DimensionEdit
    let units: String
    let onSave: (Double) -> Void
    let onCancel: () -> Void
    @State private var text: String

    init(edit: DimensionEdit, units: String, onSave: @escaping (Double) -> Void, onCancel: @escaping () -> Void) {
        self.edit = edit; self.units = units; self.onSave = onSave; self.onCancel = onCancel
        _text = State(initialValue: edit.value.formatted(.number.precision(.fractionLength(0...3))))
    }

    private var value: Double? {
        Double(text).flatMap { value in
            guard value.isFinite, value > 0, edit.kind != "Angle" || value < 180 else { return nil }
            return value
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit \(edit.kind.lowercased())").font(.title3.weight(.semibold))
            HStack {
                TextField(edit.kind, text: $text).textFieldStyle(.roundedBorder).frame(width: 180)
                Text(edit.kind == "Angle" ? "°" : units).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Apply") { if let value { onSave(value) } }.buttonStyle(.borderedProminent).disabled(value == nil).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 340)
    }
}

private struct SketchCanvasTransform {
    let size: CGSize
    let scale: Double
    let center: CGPoint

    init(size: CGSize, solution: CADProfileSketchSolution) {
        self.size = size
        let span = simd.max(solution.boundsMaximum - solution.boundsMinimum, SIMD2<Double>(40, 30))
        scale = max(2, min(12, min(Double(size.width - 100) / span.x, Double(size.height - 100) / span.y)))
        center = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    func view(_ point: SIMD2<Double>) -> CGPoint { CGPoint(x: center.x + point.x * scale, y: center.y - point.y * scale) }
    func model(_ point: CGPoint) -> SIMD2<Double> { SIMD2((point.x - center.x) / scale, (center.y - point.y) / scale) }
}
