import MetalKit
import SwiftUI
import simd

struct GPUVertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
    var color: SIMD4<Float>
}

private struct CADRenderUniforms {
    var mvp: float4x4
    var model: float4x4
    var frameOffset: SIMD4<Float>
    var sectionPlane: SIMD4<Float>
    var sectionEnabled: SIMD4<Float>
}

extension CADSectionPlane {
    var clipEquation: SIMD4<Float> {
        let axisVector: SIMD3<Float> = switch axis { case "x": SIMD3(1, 0, 0); case "y": SIMD3(0, 1, 0); default: SIMD3(0, 0, 1) }
        let direction = flipped ? -axisVector : axisVector
        return SIMD4(direction, Float(offset) * (flipped ? -1 : 1))
    }
}

struct CADRenderMesh: Sendable {
    var featureId: String
    var vertices: [GPUVertex]
    var faceIds: [UInt32] = []
    var topologyEdges: [CADKernelTopologyEdge] = []
}

enum CADCameraPreset: String, Sendable {
    case fit, isometric, front, top, right, reviewOverview, reviewRecline, reviewCockpit, reviewBase
}

enum CADExplodedView {
    static func offset(for instanceId: String, in document: CADDocument, distance: Double) -> SIMD3<Float> {
        let instances = document.features.filter { $0.kind == "assembly_instance" }
        guard distance > 0, let ordinal = instances.firstIndex(where: { $0.id == instanceId }), !instances.isEmpty else { return .zero }
        let center = instances.reduce(SIMD3<Double>.zero) { sum, feature in sum + SIMD3(feature.params["x"] ?? 0, feature.params["y"] ?? 0, feature.params["z"] ?? 0) } / Double(instances.count)
        let instance = instances[ordinal]
        var direction = SIMD3(instance.params["x"] ?? 0, instance.params["y"] ?? 0, instance.params["z"] ?? 0) - center
        if simd_length_squared(direction) < 0.000_001 {
            let angle = Double(ordinal) * 2.399_963_229_728_653
            direction = SIMD3(cos(angle), sin(angle), ordinal.isMultiple(of: 2) ? 0.45 : -0.45)
        }
        return SIMD3<Float>(simd_normalize(direction) * distance)
    }
}

struct CADCameraRequest: Equatable, Sendable {
    var id: Int
    var preset: CADCameraPreset
}

enum BracketMeshBuilder {
    static func vertices(document: CADDocument, selectedFeatureId: String?) -> [GPUVertex] {
        meshes(document: document, selectedFeatureId: selectedFeatureId).flatMap(\.vertices)
    }

    static func meshes(document: CADDocument, selectedFeatureId: String?) -> [CADRenderMesh] {
        let sketch = document.features.first { $0.id == "sketch-base" }
        let pad = document.features.first { $0.id == "pad-base" }
        let holes = document.features.first { $0.id == "pocket-holes" }
        let width = Float(sketch?.params["width"] ?? 86)
        let height = Float(sketch?.params["height"] ?? 54)
        let depth = Float(pad?.params["length"] ?? 6)
        let diameter = Float(holes?.params["diameter"] ?? 5)
        let offset = Float(holes?.params["offset"] ?? 12)
        let selected = ["sketch-base", "pad-base", "pocket-holes"].contains(selectedFeatureId ?? "")
        var result: [CADRenderMesh] = []
        if sketch?.visible != false, pad?.visible != false {
            let color = selected ? SIMD4<Float>(0.40, 0.82, 0.67, 1) : SIMD4<Float>(0.48, 0.68, 0.63, 1)
            let baseVertices = holes?.visible == false
                ? solidBox(width: width, height: height, depth: depth, center: .zero, color: color)
                : perforatedPlate(width: width, height: height, depth: depth, holeRadius: diameter / 2, offset: offset, color: color)
            result.append(CADRenderMesh(featureId: holes?.visible == false ? "pad-base" : "pocket-holes", vertices: baseVertices))
        }
        for feature in document.features where feature.visible {
            let meshStart = result.count
            let highlight = feature.id == selectedFeatureId
            let featureColor = highlight ? SIMD4<Float>(0.35, 0.96, 0.67, 1) : SIMD4<Float>(0.50, 0.62, 0.88, 1)
            // Assembly instances are posed occurrences of a hidden source
            // part.  Rendering only the source catalogue left assemblies as
            // blank/cropped placeholders even though the model tree and Fit
            // bounds contained the real chair.
            let source = feature.kind == "assembly_instance"
                ? feature.inputFeatureIds?.first.flatMap { id in document.features.first { $0.id == id } }
                : feature
            guard let source else { continue }
            let isInstance = feature.kind == "assembly_instance"
            let centerX = Float(source.params["x"] ?? 0) + Float(isInstance ? feature.params["x"] ?? 0 : 0)
            let centerY = Float(source.params["y"] ?? 0) + Float(isInstance ? feature.params["y"] ?? 0 : 0)
            let centerZ = Float(source.params["z"] ?? (isInstance ? 0 : 14)) + Float(isInstance ? feature.params["z"] ?? 0 : 0)
            let center = SIMD3<Float>(centerX, centerY, centerZ)
            if source.kind == "box" {
                result.append(CADRenderMesh(featureId: feature.id, vertices: solidBox(
                    width: Float(source.params["width"] ?? 30), height: Float(source.params["height"] ?? 24), depth: Float(source.params["depth"] ?? 16), center: center, color: featureColor)))
            } else if source.kind == "cylinder" {
                result.append(CADRenderMesh(featureId: feature.id, vertices: cylinder(
                    radius: Float(source.params["radius"] ?? 8), height: Float(source.params["height"] ?? 22), center: center, color: featureColor)))
            } else if source.kind == "cone" {
                result.append(CADRenderMesh(featureId: feature.id, vertices: cone(
                    bottomRadius: Float(source.params["radius_bottom"] ?? 10), topRadius: Float(source.params["radius_top"] ?? 4), height: Float(source.params["height"] ?? 24), center: center, color: featureColor)))
            } else if source.kind == "sphere" {
                result.append(CADRenderMesh(featureId: feature.id, vertices: sphere(
                    radius: Float(source.params["radius"] ?? 10), center: center, color: featureColor)))
            } else if source.kind == "torus" {
                result.append(CADRenderMesh(featureId: feature.id, vertices: torus(
                    majorRadius: Float(source.params["major_radius"] ?? 14), tubeRadius: Float(source.params["tube_radius"] ?? 4), center: center, color: featureColor)))
            }
            if result.count > meshStart {
                if isInstance {
                    result[meshStart].vertices = scaled(result[meshStart].vertices, around: center, by: SIMD3(
                        Float(feature.params["scale_x"] ?? 1), Float(feature.params["scale_y"] ?? 1), Float(feature.params["scale_z"] ?? 1)
                    ))
                }
                result[meshStart].vertices = oriented(result[meshStart].vertices, around: center,
                    xDegrees: Float(source.params["rotation_x"] ?? 0) + Float(isInstance ? feature.params["rotation_x"] ?? 0 : 0),
                    yDegrees: Float(source.params["rotation_y"] ?? 0) + Float(isInstance ? feature.params["rotation_y"] ?? 0 : 0),
                    zDegrees: Float(source.params["rotation_z"] ?? 0) + Float(isInstance ? feature.params["rotation_z"] ?? 0 : 0))
            }
        }
        return result
    }

    private static func perforatedPlate(width: Float, height: Float, depth: Float, holeRadius: Float, offset: Float, color: SIMD4<Float>) -> [GPUVertex] {
        let x = width / 2, y = height / 2, z = depth / 2
        let cells: [(minX: Float, maxX: Float, minY: Float, maxY: Float, center: SIMD2<Float>)] = [
            (-x, 0, 0, y, SIMD2(-x + offset, y - offset)),
            (0, x, 0, y, SIMD2(x - offset, y - offset)),
            (-x, 0, -y, 0, SIMD2(-x + offset, -y + offset)),
            (0, x, -y, 0, SIMD2(x - offset, -y + offset))
        ]
        var vertices = sideWalls(width: width, height: height, depth: depth, color: color)
        let segments = 48

        for cell in cells {
            for index in 0..<segments {
                let a = Float(index) / Float(segments) * .pi * 2
                let b = Float(index + 1) / Float(segments) * .pi * 2
                let innerA2 = cell.center + SIMD2(cos(a), sin(a)) * holeRadius
                let innerB2 = cell.center + SIMD2(cos(b), sin(b)) * holeRadius
                let outerA2 = outerPoint(angle: a, cell: cell)
                let outerB2 = outerPoint(angle: b, cell: cell)
                let topInnerA = SIMD3(innerA2.x, innerA2.y, z), topInnerB = SIMD3(innerB2.x, innerB2.y, z)
                let topOuterA = SIMD3(outerA2.x, outerA2.y, z), topOuterB = SIMD3(outerB2.x, outerB2.y, z)
                let bottomInnerA = SIMD3(innerA2.x, innerA2.y, -z), bottomInnerB = SIMD3(innerB2.x, innerB2.y, -z)
                let bottomOuterA = SIMD3(outerA2.x, outerA2.y, -z), bottomOuterB = SIMD3(outerB2.x, outerB2.y, -z)

                vertices += triangle(topInnerA, topOuterA, topOuterB, [0,0,1], color)
                vertices += triangle(topInnerA, topOuterB, topInnerB, [0,0,1], color)
                vertices += triangle(bottomInnerA, bottomOuterB, bottomOuterA, [0,0,-1], color)
                vertices += triangle(bottomInnerA, bottomInnerB, bottomOuterB, [0,0,-1], color)

                let inwardA = SIMD3(-cos(a), -sin(a), 0)
                let inwardB = SIMD3(-cos(b), -sin(b), 0)
                vertices.append(vertex(topInnerA, inwardA, color * SIMD4(0.72, 0.72, 0.72, 1)))
                vertices.append(vertex(bottomInnerB, inwardB, color * SIMD4(0.72, 0.72, 0.72, 1)))
                vertices.append(vertex(bottomInnerA, inwardA, color * SIMD4(0.72, 0.72, 0.72, 1)))
                vertices.append(vertex(topInnerA, inwardA, color * SIMD4(0.72, 0.72, 0.72, 1)))
                vertices.append(vertex(topInnerB, inwardB, color * SIMD4(0.72, 0.72, 0.72, 1)))
                vertices.append(vertex(bottomInnerB, inwardB, color * SIMD4(0.72, 0.72, 0.72, 1)))
            }
        }
        return vertices
    }

    private static func outerPoint(angle: Float, cell: (minX: Float, maxX: Float, minY: Float, maxY: Float, center: SIMD2<Float>)) -> SIMD2<Float> {
        let direction = SIMD2(cos(angle), sin(angle))
        let tx: Float = abs(direction.x) < 0.00001 ? .greatestFiniteMagnitude : (direction.x > 0 ? cell.maxX - cell.center.x : cell.minX - cell.center.x) / direction.x
        let ty: Float = abs(direction.y) < 0.00001 ? .greatestFiniteMagnitude : (direction.y > 0 ? cell.maxY - cell.center.y : cell.minY - cell.center.y) / direction.y
        return cell.center + direction * min(tx, ty)
    }

    private static func sideWalls(width: Float, height: Float, depth: Float, color: SIMD4<Float>) -> [GPUVertex] {
        let x = width / 2, y = height / 2, z = depth / 2
        let p: [SIMD3<Float>] = [
            [-x,-y,-z], [x,-y,-z], [x,y,-z], [-x,y,-z],
            [-x,-y,z], [x,-y,z], [x,y,z], [-x,y,z]
        ]
        let faces: [([Int], SIMD3<Float>)] = [
            ([0,4,7, 0,7,3], [-1,0,0]), ([5,1,2, 5,2,6], [1,0,0]),
            ([3,7,6, 3,6,2], [0,1,0]), ([0,1,5, 0,5,4], [0,-1,0])
        ]
        return faces.flatMap { indices, normal in indices.map { vertex(p[$0], normal, color) } }
    }

    private static func solidBox(width: Float, height: Float, depth: Float, center: SIMD3<Float>, color: SIMD4<Float>) -> [GPUVertex] {
        let x = width / 2, y = height / 2, z = depth / 2
        let p: [SIMD3<Float>] = [
            center + SIMD3(-x,-y,-z), center + SIMD3(x,-y,-z), center + SIMD3(x,y,-z), center + SIMD3(-x,y,-z),
            center + SIMD3(-x,-y,z), center + SIMD3(x,-y,z), center + SIMD3(x,y,z), center + SIMD3(-x,y,z)
        ]
        let faces: [([Int], SIMD3<Float>)] = [
            ([4,5,6, 4,6,7], [0,0,1]), ([1,0,3, 1,3,2], [0,0,-1]),
            ([0,4,7, 0,7,3], [-1,0,0]), ([5,1,2, 5,2,6], [1,0,0]),
            ([3,7,6, 3,6,2], [0,1,0]), ([0,1,5, 0,5,4], [0,-1,0])
        ]
        return faces.flatMap { indices, normal in indices.map { vertex(p[$0], normal, color) } }
    }

    private static func cylinder(radius: Float, height: Float, center: SIMD3<Float>, color: SIMD4<Float>) -> [GPUVertex] {
        let segments = 64, bottomZ = center.z - height / 2, topZ = center.z + height / 2
        var vertices: [GPUVertex] = []
        for index in 0..<segments {
            let a = Float(index) / Float(segments) * .pi * 2
            let b = Float(index + 1) / Float(segments) * .pi * 2
            let bottomA = SIMD3(center.x + cos(a) * radius, center.y + sin(a) * radius, bottomZ)
            let bottomB = SIMD3(center.x + cos(b) * radius, center.y + sin(b) * radius, bottomZ)
            let topA = SIMD3(bottomA.x, bottomA.y, topZ), topB = SIMD3(bottomB.x, bottomB.y, topZ)
            vertices += triangle(SIMD3(center.x, center.y, topZ), topA, topB, [0,0,1], color)
            vertices += triangle(SIMD3(center.x, center.y, bottomZ), bottomB, bottomA, [0,0,-1], color)
            let normalA = SIMD3(cos(a), sin(a), 0), normalB = SIMD3(cos(b), sin(b), 0)
            vertices.append(vertex(bottomA, normalA, color)); vertices.append(vertex(topA, normalA, color)); vertices.append(vertex(topB, normalB, color))
            vertices.append(vertex(bottomA, normalA, color)); vertices.append(vertex(topB, normalB, color)); vertices.append(vertex(bottomB, normalB, color))
        }
        return vertices
    }

    private static func cone(bottomRadius: Float, topRadius: Float, height: Float, center: SIMD3<Float>, color: SIMD4<Float>) -> [GPUVertex] {
        let segments = 64, bottomZ = center.z - height / 2, topZ = center.z + height / 2
        let slope = (bottomRadius - topRadius) / max(height, 0.0001)
        var vertices: [GPUVertex] = []
        for index in 0..<segments {
            let a = Float(index) / Float(segments) * .pi * 2, b = Float(index + 1) / Float(segments) * .pi * 2
            let bottomA = SIMD3(center.x + cos(a) * bottomRadius, center.y + sin(a) * bottomRadius, bottomZ)
            let bottomB = SIMD3(center.x + cos(b) * bottomRadius, center.y + sin(b) * bottomRadius, bottomZ)
            let topA = SIMD3(center.x + cos(a) * topRadius, center.y + sin(a) * topRadius, topZ)
            let topB = SIMD3(center.x + cos(b) * topRadius, center.y + sin(b) * topRadius, topZ)
            if bottomRadius > 0 { vertices += triangle(SIMD3(center.x, center.y, bottomZ), bottomB, bottomA, [0,0,-1], color) }
            if topRadius > 0 { vertices += triangle(SIMD3(center.x, center.y, topZ), topA, topB, [0,0,1], color) }
            let normalA = simd_normalize(SIMD3(cos(a), sin(a), slope)), normalB = simd_normalize(SIMD3(cos(b), sin(b), slope))
            vertices.append(vertex(bottomA, normalA, color)); vertices.append(vertex(topA, normalA, color)); vertices.append(vertex(topB, normalB, color))
            vertices.append(vertex(bottomA, normalA, color)); vertices.append(vertex(topB, normalB, color)); vertices.append(vertex(bottomB, normalB, color))
        }
        return vertices
    }

    private static func sphere(radius: Float, center: SIMD3<Float>, color: SIMD4<Float>) -> [GPUVertex] {
        let latitudeSegments = 24, longitudeSegments = 48
        var vertices: [GPUVertex] = []
        for latitude in 0..<latitudeSegments {
            let v0 = Float(latitude) / Float(latitudeSegments), v1 = Float(latitude + 1) / Float(latitudeSegments)
            let phi0 = v0 * .pi - .pi / 2, phi1 = v1 * .pi - .pi / 2
            for longitude in 0..<longitudeSegments {
                let u0 = Float(longitude) / Float(longitudeSegments) * .pi * 2, u1 = Float(longitude + 1) / Float(longitudeSegments) * .pi * 2
                let n00 = SIMD3(cos(phi0) * cos(u0), cos(phi0) * sin(u0), sin(phi0))
                let n10 = SIMD3(cos(phi0) * cos(u1), cos(phi0) * sin(u1), sin(phi0))
                let n01 = SIMD3(cos(phi1) * cos(u0), cos(phi1) * sin(u0), sin(phi1))
                let n11 = SIMD3(cos(phi1) * cos(u1), cos(phi1) * sin(u1), sin(phi1))
                if latitude > 0 {
                    vertices.append(vertex(center + n00 * radius, n00, color)); vertices.append(vertex(center + n10 * radius, n10, color)); vertices.append(vertex(center + n11 * radius, n11, color))
                }
                if latitude < latitudeSegments - 1 {
                    vertices.append(vertex(center + n00 * radius, n00, color)); vertices.append(vertex(center + n11 * radius, n11, color)); vertices.append(vertex(center + n01 * radius, n01, color))
                }
            }
        }
        return vertices
    }

    private static func torus(majorRadius: Float, tubeRadius: Float, center: SIMD3<Float>, color: SIMD4<Float>) -> [GPUVertex] {
        let majorSegments = 64, tubeSegments = 24
        var vertices: [GPUVertex] = []
        func sample(_ u: Float, _ v: Float) -> (SIMD3<Float>, SIMD3<Float>) {
            let normal = SIMD3(cos(u) * cos(v), sin(u) * cos(v), sin(v))
            let point = center + SIMD3(cos(u) * (majorRadius + tubeRadius * cos(v)), sin(u) * (majorRadius + tubeRadius * cos(v)), tubeRadius * sin(v))
            return (point, normal)
        }
        for major in 0..<majorSegments {
            let u0 = Float(major) / Float(majorSegments) * .pi * 2, u1 = Float(major + 1) / Float(majorSegments) * .pi * 2
            for tube in 0..<tubeSegments {
                let v0 = Float(tube) / Float(tubeSegments) * .pi * 2, v1 = Float(tube + 1) / Float(tubeSegments) * .pi * 2
                let a = sample(u0, v0), b = sample(u1, v0), c = sample(u1, v1), d = sample(u0, v1)
                vertices.append(vertex(a.0, a.1, color)); vertices.append(vertex(b.0, b.1, color)); vertices.append(vertex(c.0, c.1, color))
                vertices.append(vertex(a.0, a.1, color)); vertices.append(vertex(c.0, c.1, color)); vertices.append(vertex(d.0, d.1, color))
            }
        }
        return vertices
    }

    private static func oriented(_ vertices: [GPUVertex], around center: SIMD3<Float>, xDegrees: Float, yDegrees: Float, zDegrees: Float) -> [GPUVertex] {
        guard xDegrees != 0 || yDegrees != 0 || zDegrees != 0 else { return vertices }
        let x = xDegrees * .pi / 180, y = yDegrees * .pi / 180, z = zDegrees * .pi / 180
        func rotate(_ input: SIMD3<Float>) -> SIMD3<Float> {
            var value = input
            value = SIMD3(value.x, value.y * cos(x) - value.z * sin(x), value.y * sin(x) + value.z * cos(x))
            value = SIMD3(value.x * cos(y) + value.z * sin(y), value.y, -value.x * sin(y) + value.z * cos(y))
            return SIMD3(value.x * cos(z) - value.y * sin(z), value.x * sin(z) + value.y * cos(z), value.z)
        }
        return vertices.map { source in
            var vertex = source
            let point = SIMD3(source.position.x, source.position.y, source.position.z)
            let normal = SIMD3(source.normal.x, source.normal.y, source.normal.z)
            let rotatedPoint = center + rotate(point - center), rotatedNormal = simd_normalize(rotate(normal))
            vertex.position = SIMD4(rotatedPoint, 1); vertex.normal = SIMD4(rotatedNormal, 0)
            return vertex
        }
    }

    private static func scaled(_ vertices: [GPUVertex], around center: SIMD3<Float>, by scale: SIMD3<Float>) -> [GPUVertex] {
        guard scale != SIMD3(repeating: 1) else { return vertices }
        return vertices.map { source in
            var vertex = source
            let point = SIMD3(source.position.x, source.position.y, source.position.z)
            vertex.position = SIMD4(center + (point - center) * scale, 1)
            // A non-uniform scale needs inverse-normal scaling before the
            // lighting normal is normalized again.
            let normal = SIMD3(source.normal.x, source.normal.y, source.normal.z)
            vertex.normal = SIMD4(simd_normalize(normal / simd.max(scale, SIMD3(repeating: 0.0001))), 0)
            return vertex
        }
    }

    private static func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ normal: SIMD3<Float>, _ color: SIMD4<Float>) -> [GPUVertex] {
        [vertex(a, normal, color), vertex(b, normal, color), vertex(c, normal, color)]
    }

    private static func vertex(_ position: SIMD3<Float>, _ normal: SIMD3<Float>, _ color: SIMD4<Float>) -> GPUVertex {
        GPUVertex(position: SIMD4(position, 1), normal: SIMD4(normal, 0), color: color)
    }
}

final class InteractiveMetalView: MTKView {
    weak var sceneRenderer: CADRenderer?
    var onSelect: ((CADSurfaceHit?) -> Void)?
    var onMove: ((String, Double, Double, Double) -> Void)?
    var onRotate: ((String, Double, Double, Double) -> Void)?
    var onScale: ((String, Double, Double, Double) -> Void)?
    private var lastPoint: NSPoint?
    private var startPoint: NSPoint?
    private var isManipulating = false

    private var didDrag = false

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastPoint = point
        startPoint = point
        didDrag = false
        if let axis = sceneRenderer?.pickGizmoAxis(at: point, viewportSize: bounds.size) {
            isManipulating = sceneRenderer?.beginManipulation(axis: axis) ?? false
        } else {
            isManipulating = event.modifierFlags.contains(.option) && (sceneRenderer?.beginManipulation() ?? false)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let lastPoint {
            didDrag = didDrag || hypot(point.x - (startPoint?.x ?? point.x), point.y - (startPoint?.y ?? point.y)) > 3
            if isManipulating, let startPoint {
                sceneRenderer?.previewManipulation(from: startPoint, to: point, viewportSize: bounds.size)
            } else if event.modifierFlags.contains(.shift) {
                // Trackpad-friendly pan: hold Shift while click-dragging.
                sceneRenderer?.pan(by: SIMD2(Float(point.x - lastPoint.x), Float(point.y - lastPoint.y)), viewportSize: bounds.size)
            } else {
                sceneRenderer?.yaw += Float(point.x - lastPoint.x) * 0.008
                sceneRenderer?.pitch += Float(point.y - lastPoint.y) * 0.008
            }
            setNeedsDisplay(bounds)
        }
        lastPoint = point
    }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isManipulating {
            if didDrag, let result = sceneRenderer?.endManipulation() {
                if result.mode == .rotate {
                    onRotate?(result.featureId, Double(result.rotation.x), Double(result.rotation.y), Double(result.rotation.z))
                } else if result.mode == .scale {
                    onScale?(result.featureId, Double(result.scale.x), Double(result.scale.y), Double(result.scale.z))
                } else {
                    onMove?(result.featureId, Double(result.position.x), Double(result.position.y), Double(result.position.z))
                }
            } else {
                _ = sceneRenderer?.endManipulation()
            }
        } else if !didDrag {
            onSelect?(sceneRenderer?.pick(at: point, viewportSize: bounds.size))
        }
        lastPoint = nil
        startPoint = nil
        isManipulating = false
    }
    override func scrollWheel(with event: NSEvent) {
        sceneRenderer?.distance = min(250, max(2.2, (sceneRenderer?.distance ?? 4.4) + Float(event.scrollingDeltaY) * 0.08))
        setNeedsDisplay(bounds)
    }

    override func magnify(with event: NSEvent) {
        // Pinch-to-zoom makes trackpad navigation feel native. Positive
        // magnification moves the camera closer to the current focal point.
        guard let renderer = sceneRenderer else { return }
        renderer.distance = min(250, max(2.2, renderer.distance * exp(-Float(event.magnification) * 1.4)))
        setNeedsDisplay(bounds)
    }
}

struct MetalViewport: NSViewRepresentable {
    let document: CADDocument
    let selectedFeatureId: String?
    let selectedSurface: CADSelectionSurface?
    let sectionPlane: CADSectionPlane?
    let measurementProbe: CADMeasurementProbe?
    let isolatedFeatureId: String?
    let explodedDistance: Double
    let showsTransformGizmo: Bool
    let gizmoMode: CADTransformGizmoMode
    let uniformScale: Bool
    let kernelMeshes: [CADKernelRenderMesh]
    let cameraRequest: CADCameraRequest
    let onSelect: (CADSurfaceHit?) -> Void
    let onMove: (String, Double, Double, Double) -> Void
    let onRotate: (String, Double, Double, Double) -> Void
    let onScale: (String, Double, Double, Double) -> Void

    func makeCoordinator() -> CADRendererHolder { CADRendererHolder() }

    func makeNSView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else { return MTKView() }
        let view = InteractiveMetalView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.055, green: 0.075, blue: 0.08, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        let renderer = CADRenderer(device: device, view: view)
        renderer.update(document: document, selectedFeatureId: selectedFeatureId, selectedSurface: selectedSurface, sectionPlane: sectionPlane, measurementProbe: measurementProbe, isolatedFeatureId: isolatedFeatureId, explodedDistance: explodedDistance, showsTransformGizmo: showsTransformGizmo, gizmoMode: gizmoMode, uniformScale: uniformScale, kernelMeshes: kernelMeshes)
        renderer.applyCamera(cameraRequest.preset, document: document)
        context.coordinator.renderer = renderer
        // Force the first SwiftUI update to fit the fully restored document.
        // At view construction the store can still contain its empty bootstrap
        // document; marking the request as already handled trapped the camera
        // at its close-up default once the saved assembly arrived.
        context.coordinator.lastCameraRequestId = -1
        context.coordinator.lastCameraDocumentRevision = document.revision
        view.sceneRenderer = renderer
        view.onSelect = onSelect
        view.onMove = onMove
        view.onRotate = onRotate
        view.onScale = onScale
        view.delegate = renderer
        // The first renderable MTK drawable is created after this method.
        // Reapply Fit on the next run-loop turn so the real drawable aspect
        // ratio, rather than SwiftUI's bootstrap size, drives the framing.
        DispatchQueue.main.async { renderer.applyCamera(cameraRequest.preset, document: document) }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.update(document: document, selectedFeatureId: selectedFeatureId, selectedSurface: selectedSurface, sectionPlane: sectionPlane, measurementProbe: measurementProbe, isolatedFeatureId: isolatedFeatureId, explodedDistance: explodedDistance, showsTransformGizmo: showsTransformGizmo, gizmoMode: gizmoMode, uniformScale: uniformScale, kernelMeshes: kernelMeshes)
        if context.coordinator.lastCameraRequestId != cameraRequest.id || context.coordinator.lastCameraDocumentRevision != document.revision {
            context.coordinator.renderer?.applyCamera(cameraRequest.preset, document: document)
            context.coordinator.lastCameraRequestId = cameraRequest.id
            context.coordinator.lastCameraDocumentRevision = document.revision
        }
        if let interactive = view as? InteractiveMetalView {
            interactive.onSelect = onSelect
            interactive.onMove = onMove
            interactive.onRotate = onRotate
            interactive.onScale = onScale
        }
    }
}

final class CADRendererHolder {
    var renderer: CADRenderer?
    var lastCameraRequestId = -1
    var lastCameraDocumentRevision = -1
}

struct CADManipulationCommit: Equatable, Sendable {
    var featureId: String
    var mode: CADTransformGizmoMode
    var position: SIMD3<Float>
    var rotation: SIMD3<Float>
    var scale: SIMD3<Float>
}

private struct CADManipulationState {
    var featureId: String
    var mode: CADTransformGizmoMode
    var position: SIMD3<Float>
    var rotation: SIMD3<Float>
    var scale: SIMD3<Float>
    var axis: CADTransformAxis?
}

final class CADRenderer: NSObject, MTKViewDelegate {
    var yaw: Float = -0.55
    var pitch: Float = 0.55
    // Start conservatively far enough away that a restored assembly can never
    // open with the camera embedded inside a part. Fit then refines this once
    // the document and kernel meshes have finished loading.
    var distance: Float = 100
    private var cameraTarget = SIMD3<Float>.zero
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let overlayDepthState: MTLDepthStencilState
    private weak var view: MTKView?
    private var vertexBuffer: MTLBuffer?
    private var vertexCount = 0
    private var overlayBuffer: MTLBuffer?
    private var overlayVertexCount = 0
    private let lock = NSLock()
    private var document = CADDocument.seed
    private var selectedFeatureId: String?
    private var selectedSurface: CADSelectionSurface?
    private var sectionPlane: CADSectionPlane?
    private var measurementProbe: CADMeasurementProbe?
    private var isolatedFeatureId: String?
    private var explodedDistance = 0.0
    private var showsTransformGizmo = true
    private var gizmoMode = CADTransformGizmoMode.translate
    private var uniformScale = true
    private var kernelMeshes: [CADKernelRenderMesh] = []
    private var manipulationStart: CADManipulationState?
    private var manipulationPreview: SIMD3<Float>?
    private var manipulationPreviewRotation: SIMD3<Float>?
    private var manipulationPreviewScale: SIMD3<Float>?
    private var manipulationPivot: SIMD3<Float>?
    private var pendingCameraFit = true
    private var lastCameraPreset: CADCameraPreset = .reviewOverview
    private var lastFittedDrawableSize = CGSize.zero

    init(device: MTLDevice, view: MTKView) {
        queue = device.makeCommandQueue()!
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float4 position; float4 normal; float4 color; };
        struct Uniforms { float4x4 mvp; float4x4 model; float4 frameOffset; float4 sectionPlane; float4 sectionEnabled; };
        struct Varying { float4 position [[position]]; float3 normal; float4 color; float clipDistance; float sectionEnabled; };
        vertex Varying vertex_main(const device Vertex *vertices [[buffer(0)]], constant Uniforms &u [[buffer(1)]], uint id [[vertex_id]]) {
            Varying out; Vertex v = vertices[id]; float4 world = u.model * v.position; out.position = u.mvp * v.position; out.position.xy += u.frameOffset.xy * out.position.w; out.normal = normalize((u.model * v.normal).xyz); out.color = v.color; out.clipDistance = dot(world.xyz, u.sectionPlane.xyz) - u.sectionPlane.w; out.sectionEnabled = u.sectionEnabled.x; return out;
        }
        fragment float4 fragment_main(Varying in [[stage_in]]) {
            if (in.sectionEnabled > 0.5 && in.clipDistance > 0.0) discard_fragment();
            float3 light = normalize(float3(-0.35, 0.75, 0.8));
            float diffuse = 0.28 + max(dot(normalize(in.normal), light), 0.0) * 0.78;
            float rim = pow(1.0 - abs(normalize(in.normal).z), 2.0) * 0.12;
            return float4(in.color.rgb * diffuse + rim, in.color.a);
        }
        """
        let library = try! device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertex_main")
        descriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
        let depth = MTLDepthStencilDescriptor(); depth.depthCompareFunction = .less; depth.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depth)!
        let overlayDepth = MTLDepthStencilDescriptor(); overlayDepth.depthCompareFunction = .always; overlayDepth.isDepthWriteEnabled = false
        overlayDepthState = device.makeDepthStencilState(descriptor: overlayDepth)!
        self.view = view
        super.init()
    }

    func update(document: CADDocument, selectedFeatureId: String?, selectedSurface: CADSelectionSurface?, sectionPlane: CADSectionPlane?, measurementProbe: CADMeasurementProbe?, isolatedFeatureId: String?, explodedDistance: Double, showsTransformGizmo: Bool, gizmoMode: CADTransformGizmoMode, uniformScale: Bool, kernelMeshes: [CADKernelRenderMesh]) {
        if self.document.id != document.id || self.document.revision != document.revision { pendingCameraFit = true }
        self.document = document
        self.selectedFeatureId = selectedFeatureId
        self.selectedSurface = selectedSurface
        self.sectionPlane = sectionPlane
        self.measurementProbe = measurementProbe?.revision == document.revision ? measurementProbe : nil
        self.isolatedFeatureId = isolatedFeatureId
        self.explodedDistance = explodedDistance
        self.showsTransformGizmo = showsTransformGizmo
        self.gizmoMode = gizmoMode
        self.uniformScale = uniformScale
        self.kernelMeshes = kernelMeshes
        manipulationStart = nil
        manipulationPreview = nil
        manipulationPreviewRotation = nil
        manipulationPreviewScale = nil
        manipulationPivot = nil
        updateMesh(document: document, selectedFeatureId: selectedFeatureId)
    }

    private func updateMesh(document: CADDocument, selectedFeatureId: String?) {
        var meshes = renderMeshes(document: document, selectedFeatureId: selectedFeatureId)
        if let selectedSurface, let meshIndex = meshes.firstIndex(where: { $0.featureId == selectedSurface.featureId }) {
            let selectedTriangles: [Int]
            if selectedSurface.topologyEdgeId != nil {
                selectedTriangles = []
            } else if let faceId = selectedSurface.topologyFaceId, !meshes[meshIndex].faceIds.isEmpty {
                selectedTriangles = meshes[meshIndex].faceIds.indices.filter { meshes[meshIndex].faceIds[$0] == UInt32(faceId) }
            } else {
                selectedTriangles = [selectedSurface.triangleIndex]
            }
            for triangle in selectedTriangles {
                let start = triangle * 3
                guard start >= 0, start + 2 < meshes[meshIndex].vertices.count else { continue }
                for index in start...(start + 2) { meshes[meshIndex].vertices[index].color = SIMD4(1.0, 0.55, 0.16, 1) }
            }
        }
        let vertices = meshes.flatMap(\.vertices)
        let overlayVertices = overlayVertices(document: document)
        lock.lock()
        vertexBuffer = queue.device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<GPUVertex>.stride)
        vertexCount = vertices.count
        overlayBuffer = overlayVertices.isEmpty ? nil : queue.device.makeBuffer(bytes: overlayVertices, length: overlayVertices.count * MemoryLayout<GPUVertex>.stride)
        overlayVertexCount = overlayVertices.count
        lock.unlock()
        // The document can be restored after the Metal view exists. Fit only
        // after a non-empty mesh has actually been built, never against the
        // empty bootstrap document.
        if pendingCameraFit, !vertices.isEmpty {
            pendingCameraFit = false
            DispatchQueue.main.async { [weak self] in self?.applyCamera(self?.lastCameraPreset ?? .reviewOverview, document: document) }
        }
        view?.setNeedsDisplay(view?.bounds ?? .zero)
    }


    private func measurementOverlayVertices() -> [GPUVertex] {
        guard let probe = measurementProbe else { return [] }
        let yellow = SIMD4<Float>(1.0, 0.82, 0.12, 1.0), normal = SIMD4<Float>(0, 0, 1, 0)
        func point(_ value: CADSelectionVector) -> SIMD3<Float> { SIMD3(value.x, value.y, value.z) }
        func vertex(_ value: SIMD3<Float>) -> GPUVertex { GPUVertex(position: SIMD4(value, 1), normal: normal, color: yellow) }
        func cross(_ center: SIMD3<Float>) -> [GPUVertex] {
            let radius: Float = 1.2
            return [
                vertex(center + SIMD3(-radius, 0, 0)), vertex(center + SIMD3(radius, 0, 0)),
                vertex(center + SIMD3(0, -radius, 0)), vertex(center + SIMD3(0, radius, 0)),
                vertex(center + SIMD3(0, 0, -radius)), vertex(center + SIMD3(0, 0, radius))
            ]
        }
        let start = point(probe.start)
        guard let endValue = probe.end else { return cross(start) }
        let end = point(endValue)
        return [vertex(start), vertex(end)] + cross(start) + cross(end)
    }

    private func overlayVertices(document: CADDocument) -> [GPUVertex] {
        measurementOverlayVertices() + selectedTopologyEdgeOverlayVertices(document: document) + transformGizmoVertices(document: document)
    }

    private func selectedTopologyEdgeOverlayVertices(document: CADDocument) -> [GPUVertex] {
        guard let selectedSurface, let edgeId = selectedSurface.topologyEdgeId,
              let mesh = renderMeshes(document: document, selectedFeatureId: nil).first(where: { $0.featureId == selectedSurface.featureId }),
              let edge = mesh.topologyEdges.first(where: { $0.id == UInt32(edgeId) }) else { return [] }
        let color = SIMD4<Float>(1.0, 0.55, 0.16, 1), normal = SIMD4<Float>(0, 0, 1, 0)
        var vertices: [GPUVertex] = []
        for offset in stride(from: 0, to: edge.positions.count - 5, by: 6) {
            let start = SIMD4<Float>(edge.positions[offset], edge.positions[offset + 1], edge.positions[offset + 2], 1)
            let end = SIMD4<Float>(edge.positions[offset + 3], edge.positions[offset + 4], edge.positions[offset + 5], 1)
            vertices.append(GPUVertex(position: start, normal: normal, color: color))
            vertices.append(GPUVertex(position: end, normal: normal, color: color))
        }
        return vertices
    }

    private func transformGizmoVertices(document: CADDocument) -> [GPUVertex] {
        guard showsTransformGizmo, let center = gizmoCenter(document: document) else { return [] }
        let normal = SIMD4<Float>(0, 0, 1, 0)
        func color(_ axis: CADTransformAxis) -> SIMD4<Float> {
            if manipulationStart?.axis == axis { return SIMD4(1, 0.82, 0.12, 1) }
            switch axis {
            case .x: return SIMD4(1, 0.22, 0.20, 1)
            case .y: return SIMD4(0.25, 0.92, 0.38, 1)
            case .z: return SIMD4(0.24, 0.56, 1, 1)
            }
        }
        func vertex(_ point: SIMD3<Float>, _ color: SIMD4<Float>) -> GPUVertex {
            GPUVertex(position: SIMD4(point, 1), normal: normal, color: color)
        }
        if gizmoMode == .rotate {
            return CADTransformAxis.allCases.flatMap { axis -> [GPUVertex] in
                let axisColor = color(axis)
                return (0..<64).flatMap { index -> [GPUVertex] in
                    let first = Float(index) * 2 * .pi / 64, second = Float(index + 1) * 2 * .pi / 64
                    return [
                        vertex(CADTransformGizmoMath.ringPoint(axis: axis, angle: first, center: center), axisColor),
                        vertex(CADTransformGizmoMath.ringPoint(axis: axis, angle: second, center: center), axisColor)
                    ]
                }
            }
        }
        return CADTransformAxis.allCases.flatMap { axis -> [GPUVertex] in
            let axisColor = color(axis), direction = axis.vector
            let end = center + direction * CADTransformGizmoMath.handleLength
            let side: SIMD3<Float> = axis == .x ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
            let arrowBase = end - direction * 3
            if gizmoMode == .scale {
                let secondSide = simd_normalize(simd_cross(direction, side))
                return [
                    vertex(center, axisColor), vertex(end, axisColor),
                    vertex(end - side * 1.5, axisColor), vertex(end + side * 1.5, axisColor),
                    vertex(end - secondSide * 1.5, axisColor), vertex(end + secondSide * 1.5, axisColor)
                ]
            }
            return [
                vertex(center, axisColor), vertex(end, axisColor),
                vertex(end, axisColor), vertex(arrowBase + side * 1.3, axisColor),
                vertex(end, axisColor), vertex(arrowBase - side * 1.3, axisColor)
            ]
        }
    }

    func pick(at point: CGPoint, viewportSize: CGSize) -> CADSurfaceHit? {
        guard let ray = CADCameraMath.ray(screenPoint: point, viewportSize: viewportSize, yaw: yaw, pitch: pitch, distance: distance) else { return nil }
        let meshes = renderMeshes(document: document, selectedFeatureId: nil)
        guard var hit = CADHitTester.firstSurfaceHit(meshes: meshes, origin: ray.origin, direction: ray.direction),
              let mesh = meshes.first(where: { $0.featureId == hit.featureId }) else { return nil }
        let closest = CADHitTester.nearestTopologyEdge(mesh: mesh, screenPoint: point, viewportSize: viewportSize, yaw: yaw, pitch: pitch, distance: distance, adjacentTo: hit.topologyFaceId)
        if let closest {
            hit.topologyEdgeId = Int(closest.edge.id)
            hit.topologyEdgeFaceIds = closest.edge.faceIds.map(Int.init)
            hit.position = closest.position
        }
        return hit
    }

    func pickGizmoAxis(at point: CGPoint, viewportSize: CGSize) -> CADTransformAxis? {
        guard showsTransformGizmo, let center = gizmoCenter(document: document) else { return nil }
        return gizmoMode == .rotate
            ? CADTransformGizmoMath.hitRotationAxis(at: point, center: center, viewportSize: viewportSize, yaw: yaw, pitch: pitch, distance: distance)
            : CADTransformGizmoMath.hitAxis(at: point, center: center, viewportSize: viewportSize, yaw: yaw, pitch: pitch, distance: distance)
    }

    func beginManipulation(axis: CADTransformAxis? = nil) -> Bool {
        guard let selectedFeatureId,
              let feature = document.features.first(where: { $0.id == selectedFeatureId }),
              CADTransformGizmoMath.isTransformable(feature) else { return false }
        let center = gizmoCenter(document: document) ?? .zero
        manipulationStart = CADManipulationState(
            featureId: selectedFeatureId, mode: axis == nil ? .translate : gizmoMode,
            position: SIMD3(Float(feature.params["x"] ?? 0), Float(feature.params["y"] ?? 0), Float(feature.params["z"] ?? 0)),
            rotation: SIMD3(Float(feature.params["rotation_x"] ?? 0), Float(feature.params["rotation_y"] ?? 0), Float(feature.params["rotation_z"] ?? 0)),
            scale: SIMD3(Float(feature.params["scale_x"] ?? 1), Float(feature.params["scale_y"] ?? 1), Float(feature.params["scale_z"] ?? 1)), axis: axis)
        manipulationPivot = center
        manipulationPreview = manipulationStart?.position
        manipulationPreviewRotation = manipulationStart?.rotation
        manipulationPreviewScale = manipulationStart?.scale
        return true
    }

    func previewManipulation(from start: CGPoint, to current: CGPoint, viewportSize: CGSize) {
        guard let manipulationStart, viewportSize.height > 0 else { return }
        var nextPosition = manipulationStart.position, nextRotation = manipulationStart.rotation, nextScale = manipulationStart.scale
        if manipulationStart.mode == .rotate, let axis = manipulationStart.axis {
            let degrees = CADTransformGizmoMath.rotationDegrees(axis: axis, dragStart: start, current: current, center: manipulationPivot ?? manipulationStart.position, viewportSize: viewportSize, yaw: yaw, pitch: pitch, distance: distance) ?? 0
            switch axis {
            case .x: nextRotation.x += degrees
            case .y: nextRotation.y += degrees
            case .z: nextRotation.z += degrees
            }
        } else if manipulationStart.mode == .scale, let axis = manipulationStart.axis {
            let factor = CADTransformGizmoMath.scaleFactor(axis: axis, dragStart: start, current: current, center: manipulationPivot ?? manipulationStart.position, viewportSize: viewportSize, yaw: yaw, pitch: pitch, distance: distance) ?? 1
            if uniformScale {
                nextScale = manipulationStart.scale * factor
            } else {
                switch axis {
                case .x: nextScale.x = manipulationStart.scale.x * factor
                case .y: nextScale.y = manipulationStart.scale.y * factor
                case .z: nextScale.z = manipulationStart.scale.z * factor
                }
            }
        } else if let axis = manipulationStart.axis {
            let translation = CADTransformGizmoMath.translation(axis: axis, dragStart: start, current: current, center: manipulationPivot ?? manipulationStart.position, viewportSize: viewportSize, yaw: yaw, pitch: pitch, distance: distance) ?? 0
            nextPosition = manipulationStart.position + axis.vector * translation
        } else {
            let millimetersPerPixel = max(0.02, distance * 40 * tan(0.76 / 2) * 2 / Float(viewportSize.height))
            let inverseRotation = simd_inverse(float4x4(rotationY: yaw) * float4x4(rotationX: pitch))
            let cameraRight = SIMD3(inverseRotation.columns.0.x, inverseRotation.columns.0.y, inverseRotation.columns.0.z)
            let cameraUp = SIMD3(inverseRotation.columns.1.x, inverseRotation.columns.1.y, inverseRotation.columns.1.z)
            let delta = cameraRight * (Float(current.x - start.x) * millimetersPerPixel) + cameraUp * (Float(current.y - start.y) * millimetersPerPixel)
            nextPosition = manipulationStart.position + SIMD3(delta.x, delta.y, 0)
        }
        manipulationPreview = nextPosition
        manipulationPreviewRotation = nextRotation
        manipulationPreviewScale = nextScale
        var preview = document
        if let index = preview.features.firstIndex(where: { $0.id == manipulationStart.featureId }) {
            preview.features[index].params["x"] = Double(nextPosition.x)
            preview.features[index].params["y"] = Double(nextPosition.y)
            preview.features[index].params["z"] = Double(nextPosition.z)
            preview.features[index].params["rotation_x"] = Double(nextRotation.x)
            preview.features[index].params["rotation_y"] = Double(nextRotation.y)
            preview.features[index].params["rotation_z"] = Double(nextRotation.z)
            preview.features[index].params["scale_x"] = Double(nextScale.x)
            preview.features[index].params["scale_y"] = Double(nextScale.y)
            preview.features[index].params["scale_z"] = Double(nextScale.z)
            updateMesh(document: preview, selectedFeatureId: selectedFeatureId)
        }
    }

    func endManipulation() -> CADManipulationCommit? {
        defer { manipulationStart = nil; manipulationPreview = nil; manipulationPreviewRotation = nil; manipulationPreviewScale = nil; manipulationPivot = nil }
        guard let start = manipulationStart, let position = manipulationPreview, let rotation = manipulationPreviewRotation, let scale = manipulationPreviewScale else { return nil }
        return CADManipulationCommit(featureId: start.featureId, mode: start.mode, position: position, rotation: rotation, scale: scale)
    }

    func applyCamera(_ preset: CADCameraPreset, document: CADDocument) {
        lastCameraPreset = preset
        switch preset {
        case .fit: break
        case .isometric: yaw = -0.55; pitch = 0.55
        case .front: yaw = 0; pitch = 0
        case .top: yaw = 0; pitch = -.pi / 2
        case .right: yaw = -.pi / 2; pitch = 0
        case .reviewOverview: yaw = -0.55; pitch = 0.55
        case .reviewRecline: yaw = -2.15; pitch = 0.35
        case .reviewCockpit: yaw = -0.15; pitch = 0.52
        case .reviewBase: yaw = -0.72; pitch = 1.12
        }
        let renderedPoints = renderMeshes(document: document, selectedFeatureId: nil).flatMap(\.vertices).map { SIMD3($0.position.x, $0.position.y, $0.position.z) }.filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        // A freshly opened large assembly may still be loading its kernel
        // meshes.  Fit must nevertheless work immediately from native feature
        // dimensions instead of leaving the camera inside the model.
        let envelopePoints = approximateFitPoints(document: document)
        // Once native assembly instances are available their actual posed
        // vertices are the only trustworthy fit envelope (rotation and
        // non-uniform upholstery scaling are already applied).
        let points = renderedPoints.isEmpty ? envelopePoints : renderedPoints
        if let first = points.first {
            let minimum = points.dropFirst().reduce(first) { simd.min($0, $1) }
            let maximum = points.dropFirst().reduce(first) { simd.max($0, $1) }
            cameraTarget = (minimum + maximum) / 2
            let radius = (points.map { simd_distance($0, cameraTarget) }.max() ?? 1) / 40
            let aspect: Float = 1.35
            let verticalHalfFov: Float = 0.76 / 2
            let horizontalHalfFov = atan(tan(verticalHalfFov) * aspect)
            // Keep a recognisable margin around tall workstation assemblies;
            // the interactive zoom range remains available to tighten it.
            distance = min(240, max(2.2, radius / sin(min(verticalHalfFov, horizontalHalfFov)) * 2.0))
        }
        view?.setNeedsDisplay(view?.bounds ?? .zero)
    }

    private func approximateFitPoints(document: CADDocument) -> [SIMD3<Float>] {
        document.features.filter(\.visible).flatMap { feature -> [SIMD3<Float>] in
            let source = feature.kind == "assembly_instance" ? feature.inputFeatureIds?.first.flatMap { id in document.features.first { $0.id == id } } : feature
            guard let source else { return [] }
            let position = SIMD3<Float>(Float(source.params["x"] ?? 0) + Float(feature.kind == "assembly_instance" ? feature.params["x"] ?? 0 : 0), Float(source.params["y"] ?? 0) + Float(feature.kind == "assembly_instance" ? feature.params["y"] ?? 0 : 0), Float(source.params["z"] ?? 0) + Float(feature.kind == "assembly_instance" ? feature.params["z"] ?? 0 : 0))
            let scale = SIMD3<Float>(Float(feature.kind == "assembly_instance" ? feature.params["scale_x"] ?? 1 : 1), Float(feature.kind == "assembly_instance" ? feature.params["scale_y"] ?? 1 : 1), Float(feature.kind == "assembly_instance" ? feature.params["scale_z"] ?? 1 : 1))
            let rawSize: SIMD3<Float>
            switch source.kind {
            case "box": rawSize = SIMD3(Float(source.params["width"] ?? 30), Float(source.params["height"] ?? 24), Float(source.params["depth"] ?? 16))
            case "cylinder": let r = Float(source.params["radius"] ?? 8); rawSize = SIMD3(r * 2, r * 2, Float(source.params["height"] ?? 22))
            case "sphere": let r = Float(source.params["radius"] ?? 10); rawSize = SIMD3(repeating: r * 2)
            case "torus": let r = Float((source.params["major_radius"] ?? 14) + (source.params["tube_radius"] ?? 4)); rawSize = SIMD3(r * 2, r * 2, Float(source.params["tube_radius"] ?? 4) * 2)
            default: return []
            }
            let half = rawSize * scale / 2
            return [position - half, position + half]
        }
    }

    func pan(by screenDelta: SIMD2<Float>, viewportSize: CGSize) {
        guard viewportSize.height > 0 else { return }
        let rotation = float4x4(rotationY: yaw) * float4x4(rotationX: pitch)
        let inverseRotation = simd_inverse(rotation)
        let right = SIMD3(inverseRotation.columns.0.x, inverseRotation.columns.0.y, inverseRotation.columns.0.z)
        let up = SIMD3(inverseRotation.columns.1.x, inverseRotation.columns.1.y, inverseRotation.columns.1.z)
        let millimetersPerPixel = max(0.02, distance * 40 * tan(0.76 / 2) * 2 / Float(viewportSize.height))
        cameraTarget -= right * screenDelta.x * millimetersPerPixel
        cameraTarget += up * screenDelta.y * millimetersPerPixel
    }

    private func renderMeshes(document: CADDocument, selectedFeatureId: String?) -> [CADRenderMesh] {
        let nativeMeshes = CADKernel.active.renderMeshes(document: document, selectedFeatureId: selectedFeatureId)
        // The native assembly path is authoritative for editable occurrences.
        // Avoid drawing a stale worker mesh over it: those meshes do not carry
        // the current per-instance pose and were the cause of giant clipped
        // surfaces in assembly review.
        let workerMeshes = document.features.contains(where: { $0.kind == "assembly_instance" })
            ? []
            : kernelMeshes.filter { $0.revision == document.revision }.map { posedKernelMesh($0, document: document, selected: $0.featureId == selectedFeatureId) }
        let rawMeshes = nativeMeshes + workerMeshes
        let meshes = rawMeshes.map { source -> CADRenderMesh in
            guard let feature = document.features.first(where: { $0.id == source.featureId }) else { return source }
            var result = source
            if explodedDistance > 0, feature.kind == "assembly_instance" {
                let offset = CADExplodedView.offset(for: feature.id, in: document, distance: explodedDistance)
                result.vertices = result.vertices.map { vertex in var copy = vertex; copy.position += SIMD4(offset, 0); return copy }
                result.topologyEdges = result.topologyEdges.map { edge in
                    var copy = edge
                    for index in stride(from: 0, to: copy.positions.count - 2, by: 3) {
                        copy.positions[index] += offset.x; copy.positions[index + 1] += offset.y; copy.positions[index + 2] += offset.z
                    }
                    if copy.anchor.count == 3 { copy.anchor[0] += offset.x; copy.anchor[1] += offset.y; copy.anchor[2] += offset.z }
                    return copy
                }
            }
            guard source.featureId != selectedFeatureId else { return result }
            let materialFeature = feature.kind == "assembly_instance" ? feature.inputFeatureIds?.first.flatMap { id in document.features.first { $0.id == id } } : feature
            let material = CADMaterialPreset.resolve(materialFeature)
            guard material != .unassigned else { return result }
            let color = SIMD4<Float>(material.color, 1)
            result.vertices = result.vertices.map { vertex in var copy = vertex; copy.color = color; return copy }
            return result
        }
        return isolatedFeatureId.map { id in meshes.filter { $0.featureId == id } } ?? meshes
    }

    private func gizmoCenter(document: CADDocument) -> SIMD3<Float>? {
        if let primitiveCenter = CADTransformGizmoMath.center(document: document, selectedFeatureId: selectedFeatureId) { return primitiveCenter }
        guard let selectedFeatureId,
              CADTransformGizmoMath.isTransformable(document.features.first(where: { $0.id == selectedFeatureId })),
              let mesh = renderMeshes(document: document, selectedFeatureId: nil).first(where: { $0.featureId == selectedFeatureId }),
              let first = mesh.vertices.first.map({ SIMD3($0.position.x, $0.position.y, $0.position.z) }) else { return nil }
        let points = mesh.vertices.dropFirst().map { SIMD3($0.position.x, $0.position.y, $0.position.z) }
        let minimum = points.reduce(first) { simd.min($0, $1) }, maximum = points.reduce(first) { simd.max($0, $1) }
        return (minimum + maximum) / 2
    }

    private func posedKernelMesh(_ source: CADKernelRenderMesh, document: CADDocument, selected: Bool) -> CADRenderMesh {
        var mesh = source.renderMesh(selected: selected)
        guard let original = self.document.features.first(where: { $0.id == source.featureId }),
              let next = document.features.first(where: { $0.id == source.featureId }) else { return mesh }
        let originalPosition = SIMD3(Float(original.params["x"] ?? 0), Float(original.params["y"] ?? 0), Float(original.params["z"] ?? 0))
        let nextPosition = SIMD3(Float(next.params["x"] ?? 0), Float(next.params["y"] ?? 0), Float(next.params["z"] ?? 0))
        let originalRotation = SIMD3(Float(original.params["rotation_x"] ?? 0), Float(original.params["rotation_y"] ?? 0), Float(original.params["rotation_z"] ?? 0)) * (.pi / 180)
        let nextRotation = SIMD3(Float(next.params["rotation_x"] ?? 0), Float(next.params["rotation_y"] ?? 0), Float(next.params["rotation_z"] ?? 0)) * (.pi / 180)
        let originalScale = SIMD3(Float(original.params["scale_x"] ?? 1), Float(original.params["scale_y"] ?? 1), Float(original.params["scale_z"] ?? 1))
        let nextScale = SIMD3(Float(next.params["scale_x"] ?? 1), Float(next.params["scale_y"] ?? 1), Float(next.params["scale_z"] ?? 1))
        guard originalPosition != nextPosition || originalRotation != nextRotation || originalScale != nextScale,
              let first = mesh.vertices.first.map({ SIMD3($0.position.x, $0.position.y, $0.position.z) }) else { return mesh }
        let points = mesh.vertices.dropFirst().map { SIMD3($0.position.x, $0.position.y, $0.position.z) }
        let center = (points.reduce(first) { simd.min($0, $1) } + points.reduce(first) { simd.max($0, $1) }) / 2
        let originalMatrix = float4x4(rotationZ: originalRotation.z) * float4x4(rotationY: originalRotation.y) * float4x4(rotationX: originalRotation.x) * float4x4(scale: originalScale)
        let nextMatrix = float4x4(rotationZ: nextRotation.z) * float4x4(rotationY: nextRotation.y) * float4x4(rotationX: nextRotation.x) * float4x4(scale: nextScale)
        let poseDelta = nextMatrix * simd_inverse(originalMatrix), normalMatrix = simd_transpose(simd_inverse(poseDelta)), translationDelta = nextPosition - originalPosition
        mesh.vertices = mesh.vertices.map { sourceVertex in
            var vertex = sourceVertex
            let point = SIMD3(sourceVertex.position.x, sourceVertex.position.y, sourceVertex.position.z)
            let normal = SIMD3(sourceVertex.normal.x, sourceVertex.normal.y, sourceVertex.normal.z)
            let rotatedPoint = poseDelta * SIMD4(point - center, 1)
            let rotatedNormal = normalMatrix * SIMD4(normal, 0)
            vertex.position = SIMD4(center + SIMD3(rotatedPoint.x, rotatedPoint.y, rotatedPoint.z) + translationDelta, 1)
            vertex.normal = SIMD4(simd_normalize(SIMD3(rotatedNormal.x, rotatedNormal.y, rotatedNormal.z)), 0)
            return vertex
        }
        mesh.topologyEdges = mesh.topologyEdges.map { edge in
            var copy = edge
            for index in stride(from: 0, to: copy.positions.count - 2, by: 3) {
                let sourcePoint = SIMD3(copy.positions[index], copy.positions[index + 1], copy.positions[index + 2])
                let transformed = poseDelta * SIMD4(sourcePoint - center, 1)
                let point = center + SIMD3(transformed.x, transformed.y, transformed.z) + translationDelta
                copy.positions[index] = point.x; copy.positions[index + 1] = point.y; copy.positions[index + 2] = point.z
            }
            if copy.anchor.count == 3 {
                let sourceAnchor = SIMD3(copy.anchor[0], copy.anchor[1], copy.anchor[2])
                let transformed = poseDelta * SIMD4(sourceAnchor - center, 1)
                let anchor = center + SIMD3(transformed.x, transformed.y, transformed.z) + translationDelta
                copy.anchor = [anchor.x, anchor.y, anchor.z]
            }
            return copy
        }
        return mesh
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.width > 8, size.height > 8 else { return }
        let sizeChanged = abs(size.width - lastFittedDrawableSize.width) > 2 || abs(size.height - lastFittedDrawableSize.height) > 2
        guard sizeChanged else { view.setNeedsDisplay(view.bounds); return }
        lastFittedDrawableSize = size
        // SwiftUI creates the MTKView before it receives its final drawable
        // size. Re-fitting here prevents an opening camera derived from the
        // temporary 1×1 / rotated backing surface from becoming permanent.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyCamera(self.lastCameraPreset, document: self.document)
        }
        view.setNeedsDisplay(view.bounds)
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor, let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        // Orthographic is the stable navigation baseline for the 3D workspace:
        // direct views remain readable and a large assembly cannot cross a
        // perspective near-plane while SwiftUI is resizing the MTK drawable.
        let matrices = CADCameraMath.matrices(viewportSize: view.bounds.size, yaw: yaw, pitch: pitch, distance: distance, target: cameraTarget, orthographic: true)
        let clipEquation = sectionPlane?.clipEquation ?? SIMD4<Float>(0, 0, 1, 0)
        var uniforms = CADRenderUniforms(mvp: matrices.projection * matrices.view * matrices.model, model: matrices.model, frameOffset: SIMD4(0, 0, 0, 0),
            sectionPlane: clipEquation, sectionEnabled: SIMD4(sectionPlane == nil ? 0 : 1, 0, 0, 0))
        lock.lock(); let buffer = vertexBuffer; let count = vertexCount; let measurementBuffer = overlayBuffer; let measurementCount = overlayVertexCount; lock.unlock()
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout.size(ofValue: uniforms), index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
        if let measurementBuffer, measurementCount > 0 {
            var overlayUniforms = CADRenderUniforms(mvp: matrices.projection * matrices.view * matrices.model, model: matrices.model, frameOffset: SIMD4(0, 0, 0, 0),
                sectionPlane: clipEquation, sectionEnabled: SIMD4<Float>(0, 0, 0, 0))
            encoder.setDepthStencilState(overlayDepthState)
            encoder.setVertexBuffer(measurementBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&overlayUniforms, length: MemoryLayout.size(ofValue: overlayUniforms), index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: measurementCount)
        }
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }
}

extension float4x4 {
    init(translation: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(translation, 1)
    }
    init(rotationX angle: Float) {
        self.init(SIMD4(1,0,0,0), SIMD4(0,cos(angle),sin(angle),0), SIMD4(0,-sin(angle),cos(angle),0), SIMD4(0,0,0,1))
    }
    init(rotationY angle: Float) {
        self.init(SIMD4(cos(angle),0,-sin(angle),0), SIMD4(0,1,0,0), SIMD4(sin(angle),0,cos(angle),0), SIMD4(0,0,0,1))
    }
    init(rotationZ angle: Float) {
        self.init(SIMD4(cos(angle),sin(angle),0,0), SIMD4(-sin(angle),cos(angle),0,0), SIMD4(0,0,1,0), SIMD4(0,0,0,1))
    }
    init(scale: Float) {
        self.init(SIMD4(scale,0,0,0), SIMD4(0,scale,0,0), SIMD4(0,0,scale,0), SIMD4(0,0,0,1))
    }
    init(scale: SIMD3<Float>) {
        self.init(SIMD4(scale.x,0,0,0), SIMD4(0,scale.y,0,0), SIMD4(0,0,scale.z,0), SIMD4(0,0,0,1))
    }
    init(lookAt eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) {
        let forward = simd_normalize(eye - target)
        var right = simd_cross(up, forward)
        if simd_length_squared(right) < 0.00001 { right = SIMD3(1, 0, 0) }
        right = simd_normalize(right)
        let correctedUp = simd_cross(forward, right)
        self.init(
            SIMD4(right.x, right.y, right.z, 0),
            SIMD4(correctedUp.x, correctedUp.y, correctedUp.z, 0),
            SIMD4(forward.x, forward.y, forward.z, 0),
            SIMD4(-simd_dot(right, eye), -simd_dot(correctedUp, eye), -simd_dot(forward, eye), 1)
        )
    }
    init(perspectiveFov fov: Float, aspect: Float, near: Float, far: Float) {
        let y = 1 / tan(fov * 0.5), x = y / aspect, z = far / (near - far)
        self.init(SIMD4(x,0,0,0), SIMD4(0,y,0,0), SIMD4(0,0,z,-1), SIMD4(0,0,z * near,0))
    }
    init(orthographicHalfHeight halfHeight: Float, aspect: Float, near: Float, far: Float) {
        let halfWidth = halfHeight * max(aspect, 0.01)
        self.init(
            SIMD4(1 / halfWidth, 0, 0, 0),
            SIMD4(0, 1 / halfHeight, 0, 0),
            SIMD4(0, 0, 1 / (near - far), 0),
            SIMD4(0, 0, near / (near - far), 1)
        )
    }
}
