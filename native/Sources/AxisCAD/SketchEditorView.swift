import SwiftUI

private let sketchMint = Color(red: 0.40, green: 0.93, blue: 0.71)
private let sketchBlue = Color(red: 0.37, green: 0.68, blue: 0.98)

struct SketchEditorView: View {
    let initial: SketchSolution
    let units: String
    let onCommit: (Double, Double, Double, Double) -> Void

    @State private var width: Double
    @State private var height: Double
    @State private var holeDiameter: Double
    @State private var holeOffset: Double

    init(solution: SketchSolution, units: String, onCommit: @escaping (Double, Double, Double, Double) -> Void) {
        initial = solution
        self.units = units
        self.onCommit = onCommit
        _width = State(initialValue: solution.width)
        _height = State(initialValue: solution.height)
        _holeDiameter = State(initialValue: solution.holeDiameter)
        _holeOffset = State(initialValue: solution.holeOffset)
    }

    private var solution: SketchSolution {
        SketchSolver.solve(width: width, height: height, holeDiameter: holeDiameter, holeOffset: holeOffset, constraintCount: initial.constraintCount)
    }

    var body: some View {
        GeometryReader { geometry in
            let transform = SketchTransform(size: geometry.size, modelWidth: width, modelHeight: height)
            ZStack {
                Color(red: 0.038, green: 0.052, blue: 0.058)
                sketchCanvas(transform: transform)
                interactionHandles(transform: transform)
                statusRail
                dimensionRail
            }
            .clipped()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Constrained mounting plate sketch")
    }

    private func sketchCanvas(transform: SketchTransform) -> some View {
        Canvas { context, size in
            drawGrid(context: &context, size: size, transform: transform)

            var axes = Path()
            axes.move(to: CGPoint(x: 0, y: transform.center.y))
            axes.addLine(to: CGPoint(x: size.width, y: transform.center.y))
            axes.move(to: CGPoint(x: transform.center.x, y: 0))
            axes.addLine(to: CGPoint(x: transform.center.x, y: size.height))
            context.stroke(axes, with: .color(Color.white.opacity(0.12)), lineWidth: 1)

            let rect = transform.screenRect(width: width, height: height)
            context.stroke(Path(rect), with: .color(sketchMint), lineWidth: 2)
            for hole in solution.holes {
                let center = transform.screen(hole.center)
                let radius = hole.radius * transform.scale
                let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.stroke(Path(ellipseIn: circle), with: .color(sketchMint), lineWidth: 2)
                var cross = Path()
                cross.move(to: CGPoint(x: center.x - 5, y: center.y)); cross.addLine(to: CGPoint(x: center.x + 5, y: center.y))
                cross.move(to: CGPoint(x: center.x, y: center.y - 5)); cross.addLine(to: CGPoint(x: center.x, y: center.y + 5))
                context.stroke(cross, with: .color(sketchBlue.opacity(0.8)), lineWidth: 1)
            }

            drawDimension(context: &context, from: CGPoint(x: rect.minX, y: rect.minY - 24), to: CGPoint(x: rect.maxX, y: rect.minY - 24), label: format(width), vertical: false)
            drawDimension(context: &context, from: CGPoint(x: rect.maxX + 28, y: rect.minY), to: CGPoint(x: rect.maxX + 28, y: rect.maxY), label: format(height), vertical: true)
        }
    }

    private func interactionHandles(transform: SketchTransform) -> some View {
        ZStack {
            let corner = transform.screen(CGPoint(x: width / 2, y: height / 2))
            handle(at: corner, label: "Resize profile")
                .gesture(DragGesture(coordinateSpace: .named("sketch")).onChanged { value in
                    let model = transform.model(value.location)
                    width = max(20, abs(model.x) * 2)
                    height = max(20, abs(model.y) * 2)
                    clampHoles()
                }.onEnded { _ in commit() })

            let northEast = CGPoint(x: width / 2 - holeOffset, y: height / 2 - holeOffset)
            let holeCenter = transform.screen(northEast)
            handle(at: holeCenter, label: "Move symmetric holes")
                .gesture(DragGesture(coordinateSpace: .named("sketch")).onChanged { value in
                    let model = transform.model(value.location)
                    let fromRight = width / 2 - abs(model.x)
                    let fromTop = height / 2 - abs(model.y)
                    holeOffset = max(holeDiameter / 2 + 1, min(fromRight, fromTop))
                    clampHoles()
                }.onEnded { _ in commit() })

            let radiusHandle = transform.screen(CGPoint(x: northEast.x + holeDiameter / 2, y: northEast.y))
            handle(at: radiusHandle, label: "Set equal hole diameter", size: 9, color: sketchBlue)
                .gesture(DragGesture(coordinateSpace: .named("sketch")).onChanged { value in
                    let model = transform.model(value.location)
                    holeDiameter = max(1, abs(model.x - northEast.x) * 2)
                    clampHoles()
                }.onEnded { _ in commit() })
        }
        .coordinateSpace(name: "sketch")
    }

    private var statusRail: some View {
        VStack {
            HStack(spacing: 12) {
                Label("XY plane", systemImage: "square.dashed")
                Text("CENTERED PROFILE")
                Spacer()
                Label(solution.isFullyConstrained ? "Fully constrained" : "Needs attention", systemImage: solution.isFullyConstrained ? "lock.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(solution.isFullyConstrained ? sketchMint : .orange)
                Text("\(solution.constraintCount) CONSTRAINTS")
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(12)
            Spacer()
        }
    }

    private var dimensionRail: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                dimensionField("Width", value: $width)
                dimensionField("Height", value: $height)
                dimensionField("Hole Ø", value: $holeDiameter)
                dimensionField("Edge offset", value: $holeOffset)
                Spacer()
                if let error = solution.errors.first { Text(error).foregroundStyle(.orange).lineLimit(1) }
                Text("Drag handles\nto reshape")
                    .foregroundStyle(.secondary).multilineTextAlignment(.trailing).fixedSize()
            }
            .font(.system(size: 10))
            .padding(.horizontal, 14)
            .frame(height: 58)
            .background(Color.black.opacity(0.28))
        }
    }

    private func dimensionField(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 3) {
                TextField(label, value: value, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder).frame(width: 54).onSubmit(commit)
                Text(units).font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 75, alignment: .leading)
    }

    private func handle(at point: CGPoint, label: String, size: CGFloat = 13, color: Color = sketchMint) -> some View {
        Circle().fill(Color(red: 0.038, green: 0.052, blue: 0.058)).stroke(color, lineWidth: 2)
            .frame(width: size, height: size).position(point).contentShape(Circle().inset(by: -8))
            .accessibilityLabel(label)
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize, transform: SketchTransform) {
        var minor = Path()
        let step = max(12, transform.scale * 5)
        var x = transform.center.x.truncatingRemainder(dividingBy: step)
        while x < size.width { minor.move(to: CGPoint(x: x, y: 0)); minor.addLine(to: CGPoint(x: x, y: size.height)); x += step }
        var y = transform.center.y.truncatingRemainder(dividingBy: step)
        while y < size.height { minor.move(to: CGPoint(x: 0, y: y)); minor.addLine(to: CGPoint(x: size.width, y: y)); y += step }
        context.stroke(minor, with: .color(Color.white.opacity(0.035)), lineWidth: 0.5)
    }

    private func drawDimension(context: inout GraphicsContext, from: CGPoint, to: CGPoint, label: String, vertical: Bool) {
        var path = Path(); path.move(to: from); path.addLine(to: to)
        context.stroke(path, with: .color(sketchBlue), lineWidth: 1)
        let midpoint = CGPoint(x: (from.x + to.x) / 2 + (vertical ? 12 : 0), y: (from.y + to.y) / 2 + (vertical ? 0 : -9))
        context.draw(Text("\(label) \(units)").font(.system(size: 10, design: .monospaced)).foregroundColor(sketchBlue), at: midpoint)
    }

    private func clampHoles() {
        let maximum = max(holeDiameter / 2 + 1, min(width, height) / 2 - holeDiameter / 2 - 1)
        holeOffset = min(maximum, max(holeDiameter / 2 + 1, holeOffset))
        holeDiameter = min(holeDiameter, max(1, min(width, height) - holeOffset * 2 - 2))
    }

    private func commit() {
        guard solution.errors.isEmpty else { return }
        onCommit(width, height, holeDiameter, holeOffset)
    }

    private func format(_ value: Double) -> String { value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value) }
}

private struct SketchTransform {
    let center: CGPoint
    let scale: Double

    init(size: CGSize, modelWidth: Double, modelHeight: Double) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        scale = max(0.1, min((size.width - 150) / max(modelWidth, 1), (size.height - 120) / max(modelHeight, 1)))
    }

    func screen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: center.x + point.x * scale, y: center.y - point.y * scale)
    }

    func model(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - center.x) / scale, y: (center.y - point.y) / scale)
    }

    func screenRect(width: Double, height: Double) -> CGRect {
        CGRect(x: center.x - width * scale / 2, y: center.y - height * scale / 2, width: width * scale, height: height * scale)
    }
}
