import Foundation

protocol CADKernelAdapter {
    var identifier: String { get }
    var providesBRepValidation: Bool { get }
    func renderMesh(document: CADDocument, selectedFeatureId: String?) -> [GPUVertex]
    func renderMeshes(document: CADDocument, selectedFeatureId: String?) -> [CADRenderMesh]
    func validate(document: CADDocument) -> [String]
}

struct NativeMeshKernel: CADKernelAdapter {
    let identifier = "native-mesh"
    let providesBRepValidation = false

    func renderMesh(document: CADDocument, selectedFeatureId: String?) -> [GPUVertex] {
        BracketMeshBuilder.vertices(document: document, selectedFeatureId: selectedFeatureId)
    }

    func renderMeshes(document: CADDocument, selectedFeatureId: String?) -> [CADRenderMesh] {
        BracketMeshBuilder.meshes(document: document, selectedFeatureId: selectedFeatureId)
    }

    func validate(document: CADDocument) -> [String] {
        SketchSolver.solve(document: document).errors
    }
}

enum CADKernel {
    static let active: any CADKernelAdapter = NativeMeshKernel()
}
