import Foundation
import simd

enum STLExporter {
    static func data(document: CADDocument, kernelMeshes: [CADKernelRenderMesh] = []) -> Data {
        let vertices = CADKernel.active.renderMesh(document: document, selectedFeatureId: nil)
            + kernelMeshes.filter { $0.revision == document.revision }.flatMap { $0.renderMesh(selected: false).vertices }
        var output = Data(repeating: 0, count: 80)
        var triangleCount = UInt32(vertices.count / 3).littleEndian
        withUnsafeBytes(of: &triangleCount) { output.append(contentsOf: $0) }

        for index in stride(from: 0, to: vertices.count, by: 3) {
            let a = vertices[index].position.xyz
            let b = vertices[index + 1].position.xyz
            let c = vertices[index + 2].position.xyz
            var normal = simd_normalize(simd_cross(b - a, c - a))
            if !normal.x.isFinite { normal = .zero }
            append(normal, to: &output)
            append(a, to: &output)
            append(b, to: &output)
            append(c, to: &output)
            var attributeCount: UInt16 = 0
            withUnsafeBytes(of: &attributeCount) { output.append(contentsOf: $0) }
        }
        return output
    }

    private static func append(_ vector: SIMD3<Float>, to output: inout Data) {
        for component in [vector.x, vector.y, vector.z] {
            var littleEndian = component.bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndian) { output.append(contentsOf: $0) }
        }
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
