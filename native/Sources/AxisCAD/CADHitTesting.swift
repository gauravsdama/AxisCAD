import Foundation
import simd

struct CADBounds: Equatable, Sendable {
    var minimum: SIMD3<Float>
    var maximum: SIMD3<Float>
}

struct CADFeatureBounds: Equatable, Sendable {
    var featureId: String
    var bounds: CADBounds
}

struct CADSurfaceHit: Equatable, Sendable {
    var featureId: String
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var distance: Float
    var triangleIndex: Int
    var topologyFaceId: Int? = nil
    var topologyEdgeId: Int? = nil
    var topologyEdgeFaceIds: [Int]? = nil
}

struct CADTopologyEdgeHit: Equatable, Sendable {
    var edge: CADKernelTopologyEdge
    var position: SIMD3<Float>
    var screenDistance: CGFloat
}

enum CADHitTester {
    static func nearestTopologyEdge(mesh: CADRenderMesh, screenPoint: CGPoint, viewportSize: CGSize, yaw: Float, pitch: Float, distance: Float, adjacentTo faceId: Int?, tolerance: CGFloat = 8) -> CADTopologyEdgeHit? {
        var closest: CADTopologyEdgeHit?
        for edge in mesh.topologyEdges where faceId.map({ edge.faceIds.contains(UInt32($0)) }) ?? true {
            for offset in stride(from: 0, to: edge.positions.count - 5, by: 6) {
                let a = SIMD3(edge.positions[offset], edge.positions[offset + 1], edge.positions[offset + 2])
                let b = SIMD3(edge.positions[offset + 3], edge.positions[offset + 4], edge.positions[offset + 5])
                guard let screenA = CADCameraMath.project(modelPoint: a, viewportSize: viewportSize, yaw: yaw, pitch: pitch, distance: distance),
                      let screenB = CADCameraMath.project(modelPoint: b, viewportSize: viewportSize, yaw: yaw, pitch: pitch, distance: distance) else { continue }
                let delta = CGPoint(x: screenB.x - screenA.x, y: screenB.y - screenA.y)
                let lengthSquared = delta.x * delta.x + delta.y * delta.y
                let t = lengthSquared > 0.0001 ? min(1, max(0, ((screenPoint.x - screenA.x) * delta.x + (screenPoint.y - screenA.y) * delta.y) / lengthSquared)) : 0
                let projected = CGPoint(x: screenA.x + delta.x * t, y: screenA.y + delta.y * t)
                let screenDistance = hypot(screenPoint.x - projected.x, screenPoint.y - projected.y)
                if screenDistance <= tolerance, closest == nil || screenDistance < closest!.screenDistance {
                    closest = CADTopologyEdgeHit(edge: edge, position: a + (b - a) * Float(t), screenDistance: screenDistance)
                }
            }
        }
        return closest
    }

    static func firstSurfaceHit(meshes: [CADRenderMesh], origin: SIMD3<Float>, direction: SIMD3<Float>) -> CADSurfaceHit? {
        var closest: CADSurfaceHit?
        for mesh in meshes {
            for index in stride(from: 0, to: mesh.vertices.count - 2, by: 3) {
                let a = SIMD3(mesh.vertices[index].position.x, mesh.vertices[index].position.y, mesh.vertices[index].position.z)
                let b = SIMD3(mesh.vertices[index + 1].position.x, mesh.vertices[index + 1].position.y, mesh.vertices[index + 1].position.z)
                let c = SIMD3(mesh.vertices[index + 2].position.x, mesh.vertices[index + 2].position.y, mesh.vertices[index + 2].position.z)
                guard let distance = triangleIntersection(origin: origin, direction: direction, a: a, b: b, c: c), distance >= 0,
                      closest == nil || distance < closest!.distance else { continue }
                let cross = simd_cross(b - a, c - a)
                let normal = simd_length_squared(cross) > 0.000_001 ? simd_normalize(cross) : .zero
                let triangleIndex = index / 3
                let rawFaceId = triangleIndex < mesh.faceIds.count ? mesh.faceIds[triangleIndex] : UInt32.max
                closest = CADSurfaceHit(
                    featureId: mesh.featureId, position: origin + direction * distance,
                    normal: normal, distance: distance, triangleIndex: triangleIndex,
                    topologyFaceId: rawFaceId == UInt32.max ? nil : Int(rawFaceId)
                )
            }
        }
        return closest
    }

    static func triangleIntersection(origin: SIMD3<Float>, direction: SIMD3<Float>, a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>) -> Float? {
        let epsilon: Float = 0.000_001
        let edge1 = b - a, edge2 = c - a
        let h = simd_cross(direction, edge2)
        let determinant = simd_dot(edge1, h)
        guard abs(determinant) > epsilon else { return nil }
        let inverse = 1 / determinant
        let s = origin - a
        let u = inverse * simd_dot(s, h)
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(s, edge1)
        let v = inverse * simd_dot(direction, q)
        guard v >= 0, u + v <= 1 else { return nil }
        let distance = inverse * simd_dot(edge2, q)
        return distance > epsilon ? distance : nil
    }

    static func featureBounds(document: CADDocument) -> [CADFeatureBounds] {
        var result: [CADFeatureBounds] = []
        let profile = document.features.first { $0.id == "sketch-base" }
        let pad = document.features.first { $0.id == "pad-base" }
        if pad?.visible != false, profile?.visible != false {
            let width = Float(profile?.params["width"] ?? 86)
            let height = Float(profile?.params["height"] ?? 54)
            let depth = Float(pad?.params["length"] ?? 6)
            result.append(CADFeatureBounds(featureId: "pad-base", bounds: CADBounds(
                minimum: SIMD3(-width / 2, -height / 2, -depth / 2),
                maximum: SIMD3(width / 2, height / 2, depth / 2)
            )))
        }
        for feature in document.features where feature.visible {
            let boundsStart = result.count
            let center = SIMD3(Float(feature.params["x"] ?? 0), Float(feature.params["y"] ?? 0), Float(feature.params["z"] ?? 0))
            if feature.kind == "box" {
                let half = SIMD3(Float(feature.params["width"] ?? 30), Float(feature.params["height"] ?? 24), Float(feature.params["depth"] ?? 16)) / 2
                result.append(CADFeatureBounds(featureId: feature.id, bounds: CADBounds(minimum: center - half, maximum: center + half)))
            } else if feature.kind == "cylinder" {
                let radius = Float(feature.params["radius"] ?? 8)
                let half = SIMD3(radius, radius, Float(feature.params["height"] ?? 22) / 2)
                result.append(CADFeatureBounds(featureId: feature.id, bounds: CADBounds(minimum: center - half, maximum: center + half)))
            } else if feature.kind == "cone" {
                let radius = Float(max(feature.params["radius_bottom"] ?? 10, feature.params["radius_top"] ?? 4))
                let half = SIMD3(radius, radius, Float(feature.params["height"] ?? 24) / 2)
                result.append(CADFeatureBounds(featureId: feature.id, bounds: CADBounds(minimum: center - half, maximum: center + half)))
            } else if feature.kind == "sphere" {
                let radius = Float(feature.params["radius"] ?? 10), half = SIMD3<Float>(repeating: radius)
                result.append(CADFeatureBounds(featureId: feature.id, bounds: CADBounds(minimum: center - half, maximum: center + half)))
            } else if feature.kind == "torus" {
                let outer = Float((feature.params["major_radius"] ?? 14) + (feature.params["tube_radius"] ?? 4))
                let half = SIMD3(outer, outer, Float(feature.params["tube_radius"] ?? 4))
                result.append(CADFeatureBounds(featureId: feature.id, bounds: CADBounds(minimum: center - half, maximum: center + half)))
            }
            if result.count > boundsStart,
               (feature.params["rotation_x"] ?? 0) != 0 || (feature.params["rotation_y"] ?? 0) != 0 || (feature.params["rotation_z"] ?? 0) != 0 {
                let bounds = result[boundsStart].bounds, radius = simd_length((bounds.maximum - bounds.minimum) / 2)
                let conservative = SIMD3<Float>(repeating: radius)
                result[boundsStart].bounds = CADBounds(minimum: center - conservative, maximum: center + conservative)
            }
        }
        return result
    }

    static func firstHit(document: CADDocument, origin: SIMD3<Float>, direction: SIMD3<Float>) -> String? {
        featureBounds(document: document)
            .compactMap { candidate -> (String, Float)? in
                guard let distance = intersectionDistance(origin: origin, direction: direction, bounds: candidate.bounds) else { return nil }
                return (candidate.featureId, distance)
            }
            .min { $0.1 < $1.1 }?.0
    }

    static func intersectionDistance(origin: SIMD3<Float>, direction: SIMD3<Float>, bounds: CADBounds) -> Float? {
        var near: Float = 0
        var far = Float.greatestFiniteMagnitude
        for axis in 0..<3 {
            if abs(direction[axis]) < 0.000_001 {
                if origin[axis] < bounds.minimum[axis] || origin[axis] > bounds.maximum[axis] { return nil }
                continue
            }
            var first = (bounds.minimum[axis] - origin[axis]) / direction[axis]
            var second = (bounds.maximum[axis] - origin[axis]) / direction[axis]
            if first > second { swap(&first, &second) }
            near = max(near, first)
            far = min(far, second)
            if near > far { return nil }
        }
        return far >= 0 ? near : nil
    }
}

enum CADCameraMath {
    static func matrices(viewportSize: CGSize, yaw: Float, pitch: Float, distance: Float, target: SIMD3<Float> = .zero, orthographic: Bool = false) -> (model: float4x4, view: float4x4, projection: float4x4) {
        // The SwiftUI-hosted MTKView can report its transient backing texture
        // in a rotated coordinate space during layout. Use the workspace's
        // stable presentation aspect for projection; the drawable is still
        // resized to its backing resolution by InteractiveMetalView.
        let measuredAspect = Float(max(viewportSize.width, 1) / max(viewportSize.height, 1))
        let aspect: Float = measuredAspect < 0.5 || measuredAspect > 3 ? 1.35 : measuredAspect
        let targetInRenderSpace = target / 40
        let horizontal = cos(pitch)
        let orbitDirection = simd_normalize(SIMD3(sin(yaw) * horizontal, -cos(yaw) * horizontal, sin(pitch)))
        let eye = targetInRenderSpace + orbitDirection * distance
        return (
            float4x4(scale: 1 / 40),
            float4x4(lookAt: eye, target: targetInRenderSpace, up: SIMD3(0, 0, 1)),
            orthographic
                ? float4x4(orthographicHalfHeight: max(1.0, distance * sin(0.76 * 0.5)), aspect: aspect, near: 0.1, far: 2_000)
                : float4x4(perspectiveFov: 0.76, aspect: aspect, near: 0.1, far: 2_000)
        )
    }

    static func ray(screenPoint: CGPoint, viewportSize: CGSize, yaw: Float, pitch: Float, distance: Float) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        let matrices = matrices(viewportSize: viewportSize, yaw: yaw, pitch: pitch, distance: distance)
        let inverse = simd_inverse(matrices.projection * matrices.view * matrices.model)
        let x = Float(screenPoint.x / viewportSize.width) * 2 - 1
        let y = Float(screenPoint.y / viewportSize.height) * 2 - 1
        var near = inverse * SIMD4(x, y, 0, 1)
        var far = inverse * SIMD4(x, y, 1, 1)
        guard abs(near.w) > 0.000_001, abs(far.w) > 0.000_001 else { return nil }
        near /= near.w
        far /= far.w
        let origin = SIMD3(near.x, near.y, near.z)
        return (origin, simd_normalize(SIMD3(far.x - near.x, far.y - near.y, far.z - near.z)))
    }

    static func project(modelPoint: SIMD3<Float>, viewportSize: CGSize, yaw: Float, pitch: Float, distance: Float) -> CGPoint? {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        let matrices = matrices(viewportSize: viewportSize, yaw: yaw, pitch: pitch, distance: distance)
        let clip = matrices.projection * matrices.view * matrices.model * SIMD4(modelPoint, 1)
        guard abs(clip.w) > 0.000_001 else { return nil }
        let normalized = clip / clip.w
        return CGPoint(
            x: (CGFloat(normalized.x) + 1) * viewportSize.width / 2,
            y: (CGFloat(normalized.y) + 1) * viewportSize.height / 2
        )
    }
}

enum CADTransformAxis: String, CaseIterable, Equatable, Sendable {
    case x, y, z

    var vector: SIMD3<Float> {
        switch self {
        case .x: SIMD3(1, 0, 0)
        case .y: SIMD3(0, 1, 0)
        case .z: SIMD3(0, 0, 1)
        }
    }
}

enum CADTransformGizmoMode: String, CaseIterable, Equatable, Sendable {
    case translate
    case rotate
    case scale
}

enum CADTransformGizmoMath {
    static let handleLength: Float = 16
    static let rotationRadius: Float = 20
    static let transformableKinds: Set<String> = ["box", "cylinder", "cone", "sphere", "torus", "extrude_feature", "pocket_feature", "revolve_feature", "sweep_feature", "loft_feature", "boolean_union", "boolean_difference", "boolean_intersection", "edge_fillet", "edge_chamfer", "shell_feature", "linear_pattern", "circular_pattern", "body_transform", "assembly_instance"]

    static func isTransformable(_ feature: CADFeature?) -> Bool {
        feature.map { transformableKinds.contains($0.kind) } ?? false
    }

    static func center(document: CADDocument, selectedFeatureId: String?) -> SIMD3<Float>? {
        guard let selectedFeatureId,
              let feature = document.features.first(where: { $0.id == selectedFeatureId }),
              ["box", "cylinder", "cone", "sphere", "torus"].contains(feature.kind),
              feature.params["x"] != nil, feature.params["y"] != nil, feature.params["z"] != nil else { return nil }
        return SIMD3(Float(feature.params["x"]!), Float(feature.params["y"]!), Float(feature.params["z"]!))
    }

    static func hitAxis(at point: CGPoint, center: SIMD3<Float>, viewportSize: CGSize, yaw: Float, pitch: Float, distance: Float, threshold: CGFloat = 9) -> CADTransformAxis? {
        CADTransformAxis.allCases.compactMap { axis -> (CADTransformAxis, CGFloat)? in
            guard let start = CADCameraMath.project(modelPoint: center + axis.vector * 3, viewportSize: viewportSize, yaw: yaw, pitch: pitch, distance: distance),
                  let end = CADCameraMath.project(modelPoint: center + axis.vector * handleLength, viewportSize: viewportSize, yaw: yaw, pitch: pitch, distance: distance) else { return nil }
            let separation = pointToSegmentDistance(point, start, end)
            return separation <= threshold ? (axis, separation) : nil
        }.min { $0.1 < $1.1 }?.0
    }

    static func translation(axis: CADTransformAxis, dragStart: CGPoint, current: CGPoint, center: SIMD3<Float>, viewportSize: CGSize, yaw: Float, pitch: Float, distance: Float) -> Float? {
        guard let origin = CADCameraMath.project(modelPoint: center, viewportSize: viewportSize, yaw: yaw, pitch: pitch, distance: distance),
              let endpoint = CADCameraMath.project(modelPoint: center + axis.vector * handleLength, viewportSize: viewportSize, yaw: yaw, pitch: pitch, distance: distance) else { return nil }
        let direction = CGVector(dx: endpoint.x - origin.x, dy: endpoint.y - origin.y)
        let projectedLength = hypot(direction.dx, direction.dy)
        guard projectedLength > 2 else { return nil }
        let unit = CGVector(dx: direction.dx / projectedLength, dy: direction.dy / projectedLength)
        let drag = CGVector(dx: current.x - dragStart.x, dy: current.y - dragStart.y)
        return Float(drag.dx * unit.dx + drag.dy * unit.dy) * handleLength / Float(projectedLength)
    }

    static func scaleFactor(axis: CADTransformAxis, dragStart: CGPoint, current: CGPoint, center: SIMD3<Float>, viewportSize: CGSize, yaw: Float, pitch: Float, distance: Float) -> Float? {
        guard let delta = translation(axis: axis, dragStart: dragStart, current: current, center: center, viewportSize: viewportSize, yaw: yaw, pitch: pitch, distance: distance) else { return nil }
        return max(0.01, 1 + delta / handleLength)
    }

    static func ringPoint(axis: CADTransformAxis, angle: Float, center: SIMD3<Float>) -> SIMD3<Float> {
        let (first, second) = ringBasis(axis)
        return center + (first * cos(angle) + second * sin(angle)) * rotationRadius
    }

    static func hitRotationAxis(at point: CGPoint, center: SIMD3<Float>, viewportSize: CGSize, yaw: Float, pitch: Float, distance: Float, threshold: CGFloat = 8) -> CADTransformAxis? {
        CADTransformAxis.allCases.compactMap { axis -> (CADTransformAxis, CGFloat)? in
            var closest = CGFloat.greatestFiniteMagnitude
            for index in 0..<64 {
                let startAngle = Float(index) * 2 * .pi / 64, endAngle = Float(index + 1) * 2 * .pi / 64
                guard let start = CADCameraMath.project(modelPoint: ringPoint(axis: axis, angle: startAngle, center: center), viewportSize: viewportSize, yaw: yaw, pitch: pitch, distance: distance),
                      let end = CADCameraMath.project(modelPoint: ringPoint(axis: axis, angle: endAngle, center: center), viewportSize: viewportSize, yaw: yaw, pitch: pitch, distance: distance) else { continue }
                closest = min(closest, pointToSegmentDistance(point, start, end))
            }
            return closest <= threshold ? (axis, closest) : nil
        }.min { $0.1 < $1.1 }?.0
    }

    static func rotationDegrees(axis: CADTransformAxis, dragStart: CGPoint, current: CGPoint, center: SIMD3<Float>, viewportSize: CGSize, yaw: Float, pitch: Float, distance: Float) -> Float? {
        guard let startRay = CADCameraMath.ray(screenPoint: dragStart, viewportSize: viewportSize, yaw: yaw, pitch: pitch, distance: distance),
              let currentRay = CADCameraMath.ray(screenPoint: current, viewportSize: viewportSize, yaw: yaw, pitch: pitch, distance: distance),
              let startPoint = planeIntersection(ray: startRay, center: center, normal: axis.vector),
              let currentPoint = planeIntersection(ray: currentRay, center: center, normal: axis.vector) else { return nil }
        let startVector = startPoint - center, currentVector = currentPoint - center
        guard simd_length_squared(startVector) > 0.000_001, simd_length_squared(currentVector) > 0.000_001 else { return nil }
        let first = simd_normalize(startVector), second = simd_normalize(currentVector)
        return atan2(simd_dot(axis.vector, simd_cross(first, second)), simd_dot(first, second)) * 180 / .pi
    }

    private static func ringBasis(_ axis: CADTransformAxis) -> (SIMD3<Float>, SIMD3<Float>) {
        switch axis {
        case .x: (SIMD3(0, 1, 0), SIMD3(0, 0, 1))
        case .y: (SIMD3(0, 0, 1), SIMD3(1, 0, 0))
        case .z: (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        }
    }

    private static func planeIntersection(ray: (origin: SIMD3<Float>, direction: SIMD3<Float>), center: SIMD3<Float>, normal: SIMD3<Float>) -> SIMD3<Float>? {
        let denominator = simd_dot(ray.direction, normal)
        guard abs(denominator) > 0.000_01 else { return nil }
        let distance = simd_dot(center - ray.origin, normal) / denominator
        guard distance > 0 else { return nil }
        return ray.origin + ray.direction * distance
    }

    private static func pointToSegmentDistance(_ point: CGPoint, _ start: CGPoint, _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.000_001 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }
}
