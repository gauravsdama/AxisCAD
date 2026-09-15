import Foundation
import simd

struct CADMeasurement: Equatable, Sendable {
    var size: SIMD3<Double>
    var minimum: SIMD3<Double>
    var maximum: SIMD3<Double>
    var surfaceArea: Double
    var volume: Double
    var triangleCount: Int

    static func measure(document: CADDocument, kernelMeshes: [CADKernelRenderMesh] = []) -> CADMeasurement {
        let vertices = CADKernel.active.renderMesh(document: document, selectedFeatureId: nil)
            + kernelMeshes.filter { $0.revision == document.revision }.flatMap { $0.renderMesh(selected: false).vertices }
        guard let first = vertices.first else {
            return CADMeasurement(size: .zero, minimum: .zero, maximum: .zero, surfaceArea: 0, volume: 0, triangleCount: 0)
        }
        var minimum = SIMD3<Double>(Double(first.position.x), Double(first.position.y), Double(first.position.z))
        var maximum = minimum
        var area = 0.0
        var signedVolume = 0.0
        for vertex in vertices {
            let point = SIMD3<Double>(Double(vertex.position.x), Double(vertex.position.y), Double(vertex.position.z))
            minimum = simd.min(minimum, point)
            maximum = simd.max(maximum, point)
        }
        for index in stride(from: 0, to: vertices.count - 2, by: 3) {
            let a = point(vertices[index]), b = point(vertices[index + 1]), c = point(vertices[index + 2])
            area += simd_length(simd_cross(b - a, c - a)) / 2
            signedVolume += simd_dot(a, simd_cross(b, c)) / 6
        }
        return CADMeasurement(size: maximum - minimum, minimum: minimum, maximum: maximum, surfaceArea: area, volume: abs(signedVolume), triangleCount: vertices.count / 3)
    }

    private static func point(_ vertex: GPUVertex) -> SIMD3<Double> {
        SIMD3(Double(vertex.position.x), Double(vertex.position.y), Double(vertex.position.z))
    }
}
