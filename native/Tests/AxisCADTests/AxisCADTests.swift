import Foundation
import simd
import Testing
@testable import AxisCAD

@MainActor
struct AxisCADTests {
    @Test func kernelProcessControllerStopsCancelledAndTimedOutWorkers() throws {
        let cancelledProcess = Process()
        cancelledProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        cancelledProcess.arguments = ["10"]
        let cancelled = KernelProcessController()
        #expect(cancelled.attach(cancelledProcess))
        try cancelledProcess.run()
        cancelled.cancel()
        cancelledProcess.waitUntilExit()
        #expect(cancelled.wasCancelled)
        #expect(cancelledProcess.terminationStatus != 0)
        cancelled.detach()

        let timedProcess = Process()
        timedProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        timedProcess.arguments = ["10"]
        let timed = KernelProcessController()
        #expect(timed.attach(timedProcess))
        try timedProcess.run()
        timed.timeOut()
        timedProcess.waitUntilExit()
        #expect(timed.didTimeOut)
        #expect(timedProcess.terminationStatus != 0)
        timed.detach()
    }

    @Test func parameterEditIsRevisionedAndPersisted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        try store.setParameter(featureId: "pocket-holes", key: "diameter", value: 6)
        #expect(store.document.revision == 19)
        #expect(store.document.features.first { $0.id == "pocket-holes" }?.params["diameter"] == 6)
        let decoded = try JSONDecoder().decode(CADDocument.self, from: Data(contentsOf: store.documentURL))
        #expect(decoded == store.document)
    }

    @Test func projectSaveTracksDestinationDirtyStateAndSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        #expect(store.projectURL == nil)
        #expect(store.hasUnsavedChanges)

        let project = root.appendingPathComponent("bracket.axiscad")
        try store.exportJSON(to: project)
        #expect(store.projectURL == project.standardizedFileURL)
        #expect(!store.hasUnsavedChanges)

        try store.setParameter(featureId: "pad-base", key: "length", value: 8)
        #expect(store.hasUnsavedChanges)
        try store.saveProject()
        #expect(!store.hasUnsavedChanges)
        let saved = try JSONDecoder().decode(CADDocument.self, from: Data(contentsOf: project))
        #expect(saved.revision == store.document.revision)
        #expect(saved.features.first { $0.id == "pad-base" }?.params["length"] == 8)

        let resumed = DocumentStore(dataDirectory: root)
        #expect(resumed.projectURL == project.standardizedFileURL)
        #expect(!resumed.hasUnsavedChanges)
        try resumed.newDocument()
        #expect(resumed.projectURL == nil)
        #expect(resumed.hasUnsavedChanges)
    }

    @Test func undoRestoresPriorGeometry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        try store.setParameter(featureId: "sketch-base", key: "width", value: 100)
        store.undo()
        #expect(store.document.features.first { $0.id == "sketch-base" }?.params["width"] == 86)
    }

    @Test func promptAndDirectEditsShareTheSameModel() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        store.applyPrompt("make the mounting holes 7 mm")
        #expect(store.document.features.first { $0.id == "pocket-holes" }?.params["diameter"] == 7)
        #expect(store.document.operations.first?.author == "ai")
    }

    @Test func metalMeshRespondsToParameters() {
        let base = BracketMeshBuilder.vertices(document: .seed, selectedFeatureId: nil)
        var changed = CADDocument.seed
        changed.features[0].params["width"] = 120
        let wider = BracketMeshBuilder.vertices(document: changed, selectedFeatureId: nil)
        let baseExtent = base.map(\.position.x).max() ?? 0
        let widerExtent = wider.map(\.position.x).max() ?? 0
        #expect(widerExtent > baseExtent)
        #expect(base.count == wider.count)
    }

    @Test func binarySTLContainsMillimeterGeometryAndTriangleCount() throws {
        let data = STLExporter.data(document: .seed)
        #expect(data.count > 84)
        let triangleCount = data[80..<84].withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        #expect(Int(triangleCount) == BracketMeshBuilder.vertices(document: .seed, selectedFeatureId: nil).count / 3)
        #expect(data.count == 84 + Int(triangleCount) * 50)
    }

    @Test func primitivesAreEditableVisibleAndUndoable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        let baseVertexCount = BracketMeshBuilder.vertices(document: store.document, selectedFeatureId: nil).count
        store.addPrimitive(kind: "box")
        let box = try #require(store.document.features.first { $0.kind == "box" })
        #expect(BracketMeshBuilder.vertices(document: store.document, selectedFeatureId: box.id).count > baseVertexCount)
        try store.setParameter(featureId: box.id, key: "width", value: 42)
        try store.setParameter(featureId: box.id, key: "x", value: -18)
        #expect(store.document.features.first { $0.id == box.id }?.params["x"] == -18)
        store.setVisibility(featureId: box.id, visible: false)
        #expect(BracketMeshBuilder.vertices(document: store.document, selectedFeatureId: box.id).count == baseVertexCount)
        store.undo()
        #expect(store.document.features.first { $0.id == box.id }?.visible == true)
    }

    @Test func selectedBodiesReportClearanceAndInterferenceWithoutEditing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        store.addPrimitive(kind: "box"); let first = try #require(store.selectedFeature)
        store.addPrimitive(kind: "box"); let second = try #require(store.selectedFeature)
        try store.setParameter(featureId: second.id, key: "x", value: 50)
        try store.setParameter(featureId: second.id, key: "y", value: 1)
        try store.setParameter(featureId: second.id, key: "z", value: 1)
        store.selectedFeatureId = first.id
        let revision = store.document.revision
        await store.checkClearance(to: second.id)
        let clear = try #require(store.clearanceResult)
        #expect(clear.classification == "clear")
        #expect(abs(clear.distance - 20) < 0.001)
        #expect(store.document.revision == revision)

        try store.setParameter(featureId: second.id, key: "x", value: 10)
        store.selectedFeatureId = first.id
        await store.checkClearance(to: second.id)
        let interference = try #require(store.clearanceResult)
        #expect(interference.classification == "interference")
        #expect(interference.intersecting)
        #expect(interference.distance < 0)
    }

    @Test func advancedPrimitivesRenderPickMeasureTransformAndValidate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        for kind in ["cone", "sphere", "torus"] { store.addPrimitive(kind: kind) }
        let advanced = store.document.features.filter { ["cone", "sphere", "torus"].contains($0.kind) }
        #expect(advanced.count == 3)
        for feature in advanced {
            let mesh = try #require(CADKernel.active.renderMeshes(document: store.document, selectedFeatureId: feature.id).first { $0.featureId == feature.id })
            #expect(mesh.vertices.count >= 300)
            #expect(mesh.vertices.count.isMultiple(of: 3))
            #expect(CADHitTester.featureBounds(document: store.document).contains { $0.featureId == feature.id })
        }
        let torus = try #require(advanced.first { $0.kind == "torus" })
        let revision = store.document.revision
        try store.setTransform(featureId: torus.id, x: 32, y: -8, z: 20)
        #expect(store.document.revision == revision + 1)
        let flatTorus = try #require(CADKernel.active.renderMeshes(document: store.document, selectedFeatureId: nil).first { $0.featureId == torus.id })
        let flatZ = (flatTorus.vertices.map(\.position.z).max() ?? 0) - (flatTorus.vertices.map(\.position.z).min() ?? 0)
        try store.setParameter(featureId: torus.id, key: "rotation_x", value: 90)
        let uprightTorus = try #require(CADKernel.active.renderMeshes(document: store.document, selectedFeatureId: nil).first { $0.featureId == torus.id })
        let uprightZ = (uprightTorus.vertices.map(\.position.z).max() ?? 0) - (uprightTorus.vertices.map(\.position.z).min() ?? 0)
        #expect(uprightZ > flatZ * 3)
        #expect(store.validate().isEmpty)
        #expect(CADMeasurement.measure(document: store.document).maximum.x >= 50)
        #expect(throws: CADValidationError.self) { try store.setParameter(featureId: torus.id, key: "major_radius", value: 2) }
    }

    @Test func dependencyAwareBooleanStreamsKernelMeshIntoMetalContract() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        store.addPrimitive(kind: "box"); let box = try #require(store.selectedFeature)
        store.addPrimitive(kind: "cylinder"); let cylinder = try #require(store.selectedFeature)
        try store.createBoolean(operation: "union", leftFeatureId: box.id, rightFeatureId: cylinder.id)
        let boolean = try #require(store.selectedFeature)
        #expect(boolean.kind == "boolean_union")
        #expect(boolean.inputFeatureIds == [box.id, cylinder.id])
        #expect(store.document.features.first { $0.id == box.id }?.visible == false)
        #expect(store.document.features.first { $0.id == cylinder.id }?.visible == false)
        await store.refreshKernelMeshes()
        let payload = try #require(store.kernelRenderMeshes.first { $0.featureId == boolean.id })
        #expect(payload.revision == store.document.revision)
        #expect(payload.indices.count > 30)
        #expect(payload.faceIds?.count == payload.indices.count / 3)
        #expect(payload.faceIds?.contains { $0 != UInt32.max } == true)
        #expect(payload.renderMesh(selected: true).vertices.count == payload.indices.count)
        let measurement = CADMeasurement.measure(document: store.document, kernelMeshes: store.kernelRenderMeshes)
        #expect(measurement.triangleCount >= payload.indices.count / 3)
        let stl = STLExporter.data(document: store.document, kernelMeshes: store.kernelRenderMeshes)
        let stlTriangles = stl[80..<84].withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        #expect(Int(stlTriangles) == measurement.triangleCount)
        store.deleteFeature(featureId: box.id)
        #expect(store.document.features.contains { $0.id == box.id })
        #expect(store.lastError?.contains("used by") == true)
        store.lastError = nil
        store.deleteFeature(featureId: boolean.id)
        #expect(store.document.features.first { $0.id == box.id }?.visible == true)
        #expect(store.document.features.first { $0.id == cylinder.id }?.visible == true)
    }

    @Test func modifierHistoryFeaturesRebuildThroughExternalKernel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for kind in ["edge_fillet", "edge_chamfer", "shell_feature", "linear_pattern", "circular_pattern"] {
            let store = DocumentStore(dataDirectory: root.appendingPathComponent(kind))
            store.addPrimitive(kind: "box")
            let source = try #require(store.selectedFeature)
            if ["edge_fillet", "edge_chamfer"].contains(kind) {
                store.selectSurface(CADSurfaceHit(
                    featureId: source.id,
                    position: SIMD3(-15, -12, 6),
                    normal: SIMD3(0, 0, -1),
                    distance: 1,
                    triangleIndex: 0,
                    topologyFaceId: 0,
                    topologyEdgeId: 0,
                    topologyEdgeFaceIds: [0, 2]
                ))
            }
            try store.createModifier(kind: kind, inputFeatureId: source.id)
            let modifier = try #require(store.selectedFeature)
            #expect(modifier.kind == kind)
            #expect(modifier.inputFeatureIds == [source.id])
            #expect(store.document.features.first { $0.id == source.id }?.visible == false)
            if ["edge_fillet", "edge_chamfer"].contains(kind) {
                #expect(modifier.params["selector_mode"] == 3)
                #expect(modifier.params["selector_edge_id"] == 0)
                #expect(modifier.params["selector_edge_face_a"] == 0)
                #expect(modifier.params["selector_edge_face_b"] == 2)
                #expect(modifier.params["selector_x"] == -15)
                #expect(modifier.params["selector_face_id"] == 0)
            }
            await store.refreshKernelMeshes()
            let mesh = try #require(store.kernelRenderMeshes.first { $0.featureId == modifier.id })
            #expect(mesh.indices.count > 30)
            if kind == "edge_fillet" {
                try store.setParameter(featureId: source.id, key: "width", value: 40)
                await store.refreshKernelMeshes()
                #expect(store.kernelRenderMeshes.first { $0.featureId == modifier.id }?.indices.isEmpty == false)
            }
            #expect(store.validate().isEmpty)
            store.deleteFeature(featureId: modifier.id)
            #expect(store.document.features.first { $0.id == source.id }?.visible == true)
        }
    }

    @Test func arbitraryProfileSketchExtrudesThroughKernelAndRestoresItsSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        try store.createProfileSketch(name: "Bracket profile", plane: "XY")
        let sketch = try #require(store.selectedFeature)
        let lines = [
            CADSketchEntity(id: "line-1", kind: "line", params: ["x1": -10, "y1": -5, "x2": 10, "y2": -5]),
            CADSketchEntity(id: "line-2", kind: "line", params: ["x1": 10, "y1": -5, "x2": 10, "y2": 5]),
            CADSketchEntity(id: "line-3", kind: "line", params: ["x1": 10, "y1": 5, "x2": -10, "y2": 5])
        ]
        for line in lines { try store.addSketchEntity(sketchId: sketch.id, entity: line) }
        #expect(!CADProfileSketch.solve(feature: try #require(store.selectedFeature)).isClosed)
        #expect(throws: CADValidationError.self) { try store.createExtrusion(sketchId: sketch.id, length: 8) }

        try store.addSketchEntity(
            sketchId: sketch.id,
            entity: CADSketchEntity(id: "line-4", kind: "line", params: ["x1": -10, "y1": 5, "x2": -10, "y2": -5])
        )
        let closedSketch = try #require(store.document.features.first { $0.id == sketch.id })
        #expect(CADProfileSketch.solve(feature: closedSketch).isClosed)
        try store.createExtrusion(sketchId: sketch.id, length: 8, symmetric: true)
        let extrusion = try #require(store.selectedFeature)
        #expect(extrusion.kind == "extrude_feature")
        #expect(extrusion.inputFeatureIds == [sketch.id])
        #expect(extrusion.params["symmetric"] == 1)
        #expect(store.document.features.first { $0.id == sketch.id }?.visible == false)

        await store.refreshKernelMeshes()
        let mesh = try #require(store.kernelRenderMeshes.first { $0.featureId == extrusion.id })
        #expect(mesh.indices.count >= 36)
        #expect(mesh.boundaryEdgeSegments == 0)
        let validation = try await KernelService.validate(documentURL: store.documentURL, featureId: extrusion.id)
        #expect(abs(validation.volume - 1_600) < 0.01)
        #expect(abs((validation.bounds.maximum.z - validation.bounds.minimum.z) - 8) < 0.01)

        store.deleteFeature(featureId: extrusion.id)
        #expect(store.document.features.first { $0.id == sketch.id }?.visible == true)
        #expect(store.selectedFeatureId == sketch.id)
    }

    @Test func circleProfileExtrudesOnAlternatePlane() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        try store.createProfileSketch(name: "Round profile", plane: "XZ")
        let sketch = try #require(store.selectedFeature)
        try store.addSketchEntity(
            sketchId: sketch.id,
            entity: CADSketchEntity(id: "circle-1", kind: "circle", params: ["cx": 2, "cy": -3, "radius": 4])
        )
        #expect(CADProfileSketch.solve(feature: try #require(store.selectedFeature)).isClosed)
        try store.createExtrusion(sketchId: sketch.id, length: 12)
        let extrusion = try #require(store.selectedFeature)
        await store.refreshKernelMeshes()
        let mesh = try #require(store.kernelRenderMeshes.first { $0.featureId == extrusion.id })
        #expect(mesh.indices.count > 30)
        #expect(mesh.boundaryEdgeSegments == 0)
        #expect(store.validate().isEmpty)
    }

    @Test func multiLoopProfileExtrudesKernelHoleAndRemainsParametric() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        try store.createProfileSketch(name: "Washer profile", plane: "XY")
        let sketch = try #require(store.selectedFeature)
        try store.addSketchEntity(sketchId: sketch.id, entity: CADSketchEntity(id: "washer-outer", kind: "circle", params: ["cx": 0, "cy": 0, "radius": 10], loopId: "outer"))
        var invalid = try #require(store.selectedFeature)
        invalid.sketch?.entities?.append(CADSketchEntity(id: "outside-hole", kind: "circle", params: ["cx": 20, "cy": 0, "radius": 4], loopId: "hole-outside"))
        let invalidSolution = CADProfileSketch.solve(feature: invalid)
        #expect(!invalidSolution.isClosed)
        #expect(invalidSolution.errors.contains { $0.contains("must remain completely inside") })
        try store.addSketchEntity(sketchId: sketch.id, entity: CADSketchEntity(id: "washer-hole", kind: "circle", params: ["cx": 0, "cy": 0, "radius": 4], loopId: "hole-1"))
        let solution = CADProfileSketch.solve(feature: try #require(store.selectedFeature))
        #expect(solution.isClosed)
        #expect(Set(solution.entities.map(\.profileLoopId)) == ["outer", "hole-1"])

        try store.createExtrusion(sketchId: sketch.id, length: 5)
        let extrusion = try #require(store.selectedFeature)
        await store.refreshKernelMeshes()
        let mesh = try #require(store.kernelRenderMeshes.first { $0.featureId == extrusion.id })
        #expect(mesh.indices.count > 60)
        let initial = try await KernelService.validate(documentURL: store.documentURL, featureId: extrusion.id)
        #expect(initial.canExportStep)
        #expect(abs(initial.volume - Double.pi * 84 * 5) / (Double.pi * 84 * 5) < 0.01)

        try store.setParameter(featureId: extrusion.id, key: "length", value: 6)
        let resized = try await KernelService.validate(documentURL: store.documentURL, featureId: extrusion.id)
        #expect(abs(resized.volume / initial.volume - 1.2) < 0.01)
    }

    @Test func profileDiagnosticsRejectSelfCrossingsTouchingBoundariesAndOverlappingHoles() {
        let feature = { (entities: [CADSketchEntity]) in
            CADFeature(id: "diagnostic-profile", name: "Diagnostic profile", kind: "profile_sketch", visible: true, params: [:], sketch: CADSketchDefinition(plane: "XY", profile: "custom-profile", constraints: [], entities: entities))
        }
        let bowtie = [
            CADSketchEntity(id: "a", kind: "line", params: ["x1": 0, "y1": 0, "x2": 10, "y2": 10]),
            CADSketchEntity(id: "b", kind: "line", params: ["x1": 10, "y1": 10, "x2": 0, "y2": 10]),
            CADSketchEntity(id: "c", kind: "line", params: ["x1": 0, "y1": 10, "x2": 10, "y2": 0]),
            CADSketchEntity(id: "d", kind: "line", params: ["x1": 10, "y1": 0, "x2": 0, "y2": 0])
        ]
        let crossing = CADProfileSketch.solve(feature: feature(bowtie))
        #expect(!crossing.isClosed)
        #expect(crossing.errors.contains("Loop 'outer' self-intersects or touches itself away from connected endpoints."))

        let outer = CADSketchEntity(id: "outer", kind: "circle", params: ["cx": 0, "cy": 0, "radius": 10], loopId: "outer")
        let touching = CADProfileSketch.solve(feature: feature([outer, CADSketchEntity(id: "touch", kind: "circle", params: ["cx": 6, "cy": 0, "radius": 4], loopId: "hole-touch")]))
        #expect(!touching.isClosed)
        #expect(touching.errors.contains("Hole loop 'hole-touch' intersects or touches the outer loop."))

        let overlapping = CADProfileSketch.solve(feature: feature([
            outer,
            CADSketchEntity(id: "left", kind: "circle", params: ["cx": -3, "cy": 0, "radius": 4], loopId: "hole-left"),
            CADSketchEntity(id: "right", kind: "circle", params: ["cx": 3, "cy": 0, "radius": 4], loopId: "hole-right")
        ]))
        #expect(!overlapping.isClosed)
        #expect(overlapping.errors.contains("Hole loops 'hole-left' and 'hole-right' intersect, touch, or overlap."))
    }

    @Test func sketchDrivenPocketStreamsKernelMeshAndRestoresDependencies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        store.addPrimitive(kind: "box")
        let target = try #require(store.selectedFeature)
        try store.createProfileSketch(name: "Pocket profile", plane: "XY")
        let sketch = try #require(store.selectedFeature)
        try store.addSketchEntity(
            sketchId: sketch.id,
            entity: CADSketchEntity(id: "pocket-circle", kind: "circle", params: ["cx": 0, "cy": 0, "radius": 3])
        )
        try store.createPocket(targetFeatureId: target.id, sketchId: sketch.id, length: 40)
        let pocket = try #require(store.selectedFeature)
        #expect(pocket.kind == "pocket_feature")
        #expect(pocket.inputFeatureIds == [target.id, sketch.id])
        #expect(store.document.features.first { $0.id == target.id }?.visible == false)
        #expect(store.document.features.first { $0.id == sketch.id }?.visible == false)
        await store.refreshKernelMeshes()
        let mesh = try #require(store.kernelRenderMeshes.first { $0.featureId == pocket.id })
        #expect(mesh.indices.count > 36)
        #expect(mesh.boundaryEdgeSegments == 0)
        #expect(store.validate().isEmpty)

        let validated = try await KernelService.validate(documentURL: store.documentURL, featureId: pocket.id)
        #expect(validated.ok)
        #expect(validated.stepRoundtrip.passed)

        store.deleteFeature(featureId: pocket.id)
        #expect(store.document.features.first { $0.id == target.id }?.visible == true)
        #expect(store.document.features.first { $0.id == sketch.id }?.visible == true)
        #expect(store.selectedFeatureId == target.id)
    }

    @Test func offsetProfileRevolvesThroughKernelAndRemainsEditable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        try store.createProfileSketch(name: "Revolve profile", plane: "XY")
        let sketch = try #require(store.selectedFeature)
        let lines = [
            CADSketchEntity(id: "revolve-a", kind: "line", params: ["x1": 5, "y1": -4, "x2": 10, "y2": -4]),
            CADSketchEntity(id: "revolve-b", kind: "line", params: ["x1": 10, "y1": -4, "x2": 10, "y2": 4]),
            CADSketchEntity(id: "revolve-c", kind: "line", params: ["x1": 10, "y1": 4, "x2": 5, "y2": 4]),
            CADSketchEntity(id: "revolve-d", kind: "line", params: ["x1": 5, "y1": 4, "x2": 5, "y2": -4])
        ]
        for line in lines { try store.addSketchEntity(sketchId: sketch.id, entity: line) }
        try store.createRevolve(sketchId: sketch.id, axis: SIMD3(0, 2, 0))
        let revolve = try #require(store.selectedFeature)
        #expect(revolve.kind == "revolve_feature")
        #expect(revolve.params["axis_y"] == 1)
        #expect(revolve.inputFeatureIds == [sketch.id])
        await store.refreshKernelMeshes()
        let mesh = try #require(store.kernelRenderMeshes.first { $0.featureId == revolve.id })
        #expect(mesh.indices.count > 100)
        #expect(mesh.boundaryEdgeSegments == 0)
        let full = try await KernelService.validate(documentURL: store.documentURL, featureId: revolve.id)
        let expectedVolume = Double.pi * 75 * 8
        #expect(abs(full.volume - expectedVolume) / expectedVolume < 0.01)
        #expect(full.canExportStep)
        #expect(full.closedManifoldMesh)
        #expect(full.stepRoundtrip.passed)
        #expect(full.warnings.isEmpty)

        try store.setParameter(featureId: revolve.id, key: "angle", value: 180)
        let half = try await KernelService.validate(documentURL: store.documentURL, featureId: revolve.id)
        #expect(abs(half.volume - full.volume / 2) / (full.volume / 2) < 0.02)
        #expect(half.closedManifoldMesh)
        #expect(half.stepRoundtrip.passed)
        #expect(half.warnings.isEmpty)
        #expect(throws: CADValidationError.self) { try store.setParameter(featureId: revolve.id, key: "angle", value: 400) }
        store.deleteFeature(featureId: revolve.id)
        #expect(store.document.features.first { $0.id == sketch.id }?.visible == true)
        #expect(store.selectedFeatureId == sketch.id)
    }

    @Test func kernelDerivedBodyTransformIsReversibleEditableAndSTEPReady() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        try store.createProfileSketch(name: "Move body profile", plane: "XY")
        let sketch = try #require(store.selectedFeature)
        try store.addSketchEntity(sketchId: sketch.id, entity: CADSketchEntity(id: "move-circle", kind: "circle", params: ["cx": 0, "cy": 0, "radius": 4]))
        try store.createExtrusion(sketchId: sketch.id, length: 10)
        let extrusion = try #require(store.selectedFeature)
        let initial = try await KernelService.validate(documentURL: store.documentURL, featureId: extrusion.id)
        try store.setTransform(featureId: extrusion.id, x: 20, y: -5, z: 3)
        let moved = try #require(store.selectedFeature)
        #expect(moved.kind == "body_transform")
        #expect(moved.inputFeatureIds == [extrusion.id])
        #expect(store.document.features.first { $0.id == extrusion.id }?.visible == false)
        #expect(moved.params["x"] == 20 && moved.params["y"] == -5 && moved.params["z"] == 3)
        try store.setRotation(featureId: moved.id, x: 90, y: 0, z: 0)
        try store.setScale(featureId: moved.id, x: 1.5, y: 1.5, z: 1.5)
        let transformed = try await KernelService.validate(documentURL: store.documentURL, featureId: moved.id)
        #expect(abs(transformed.volume - initial.volume * 3.375) / (initial.volume * 3.375) < 0.001)
        #expect(abs(transformed.centerOfMass.x - 20) < 0.01)
        #expect(abs(transformed.centerOfMass.y + 5) < 0.01)
        #expect(abs(transformed.centerOfMass.z - 8) < 0.01)
        #expect(transformed.canExportStep)
        await store.refreshKernelMeshes()
        #expect(store.kernelRenderMeshes.contains { $0.featureId == moved.id && !$0.indices.isEmpty })
        store.deleteFeature(featureId: moved.id)
        #expect(store.document.features.first { $0.id == extrusion.id }?.visible == true)
        #expect(store.selectedFeatureId == extrusion.id)
    }

    @Test func planarBodySupportsNonUniformKernelScaleAndUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        store.addPrimitive(kind: "box")
        let box = try #require(store.selectedFeature)
        let revision = store.document.revision
        try store.setScale(featureId: box.id, x: 2, y: 0.5, z: 1.5)
        let scaled = try #require(store.selectedFeature)
        #expect(scaled.kind == "body_transform")
        #expect(store.document.revision == revision + 1)
        let result = try await KernelService.validate(documentURL: store.documentURL, featureId: scaled.id)
        #expect(abs(result.volume - 17_280) < 0.01)
        #expect(result.canExportStep)
        store.undo()
        #expect(store.document.features.first { $0.id == box.id }?.visible == true)
        #expect(store.document.features.contains { $0.id == scaled.id } == false)
    }

    @Test func circleProfileSweepsAlongEditableLinePath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        try store.createProfileSketch(name: "Sweep profile", plane: "XY")
        let sketch = try #require(store.selectedFeature)
        try store.addSketchEntity(
            sketchId: sketch.id,
            entity: CADSketchEntity(id: "sweep-circle", kind: "circle", params: ["cx": 0, "cy": 0, "radius": 2])
        )
        try store.createSweep(sketchId: sketch.id, end: SIMD3(0, 0, 40))
        let sweep = try #require(store.selectedFeature)
        #expect(sweep.kind == "sweep_feature")
        #expect(sweep.params["end_z"] == 40)
        #expect(sweep.inputFeatureIds == [sketch.id])
        await store.refreshKernelMeshes()
        let mesh = try #require(store.kernelRenderMeshes.first { $0.featureId == sweep.id })
        #expect(mesh.indices.count >= 36)
        let initial = try await KernelService.validate(documentURL: store.documentURL, featureId: sweep.id)
        let expectedVolume = Double.pi * 4 * 40
        #expect(abs(initial.volume - expectedVolume) / expectedVolume < 0.01)
        #expect(initial.canExportStep)

        try store.setParameter(featureId: sweep.id, key: "end_z", value: 60)
        let extended = try await KernelService.validate(documentURL: store.documentURL, featureId: sweep.id)
        #expect(abs(extended.volume / initial.volume - 1.5) < 0.02)
        #expect(throws: CADValidationError.self) { try store.setParameter(featureId: sweep.id, key: "end_z", value: 0) }
        store.deleteFeature(featureId: sweep.id)
        #expect(store.document.features.first { $0.id == sketch.id }?.visible == true)
        #expect(store.selectedFeatureId == sketch.id)
    }

    @Test func circleProfileSweepsAlongEditableHelixPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        try store.createProfileSketch(name: "Helix profile", plane: "XY")
        let sketch = try #require(store.selectedFeature)
        try store.addSketchEntity(sketchId: sketch.id, entity: CADSketchEntity(id: "helix-circle", kind: "circle", params: ["cx": 0, "cy": 0, "radius": 1.5]))
        try store.createHelixSweep(sketchId: sketch.id, radius: 10, pitch: 8, turns: 4)
        let sweep = try #require(store.selectedFeature)
        #expect(sweep.params["helix_radius"] == 10 && sweep.params["helix_pitch"] == 8 && sweep.params["helix_turns"] == 4)
        await store.refreshKernelMeshes()
        let mesh = try #require(store.kernelRenderMeshes.first { $0.featureId == sweep.id })
        #expect(mesh.indices.count > 500)
        let initial = try await KernelService.validate(documentURL: store.documentURL, featureId: sweep.id)
        #expect(initial.canExportStep)
        #expect(initial.volume > 1_500)
        try store.setParameter(featureId: sweep.id, key: "helix_turns", value: 5)
        let extended = try await KernelService.validate(documentURL: store.documentURL, featureId: sweep.id)
        #expect(abs(extended.volume / initial.volume - 1.25) < 0.03)
        #expect(throws: CADValidationError.self) { try store.setParameter(featureId: sweep.id, key: "helix_radius", value: 0) }
    }

    @Test func circleProfileSweepsAlongEditableSplineGuide() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        try store.createProfileSketch(name: "Spline profile", plane: "XY")
        let sketch = try #require(store.selectedFeature)
        try store.addSketchEntity(sketchId: sketch.id, entity: CADSketchEntity(id: "spline-circle", kind: "circle", params: ["cx": 0, "cy": 0, "radius": 2]))
        let path = [SIMD3<Double>(0, 0, 0), SIMD3(0, 10, 12), SIMD3(10, 10, 26), SIMD3(14, 0, 40)]
        let rail = path.map { $0 + SIMD3<Double>(8, 0, 0) }
        try store.createSplineSweep(sketchId: sketch.id, points: path, frameMode: .fixedUp, guidePoints: rail, startTangent: SIMD3(0, 16, 8), endTangent: SIMD3(12, 0, 8))
        let sweep = try #require(store.selectedFeature)
        #expect(sweep.kind == "sweep_feature")
        #expect(sweep.params["path_point_count"] == 4)
        #expect(sweep.params["path_3_z"] == 40)
        #expect(sweep.params["frame_mode"] == 2)
        #expect(sweep.params["guide_point_count"] == 4)
        #expect(sweep.params["tangent_mode"] == 3)
        #expect(store.document.features.first { $0.id == sketch.id }?.visible == false)
        await store.refreshKernelMeshes()
        let mesh = try #require(store.kernelRenderMeshes.first { $0.featureId == sweep.id })
        #expect(mesh.indices.count > 500)
        let initial = try await KernelService.validate(documentURL: store.documentURL, featureId: sweep.id)
        #expect(initial.canExportStep)
        #expect(initial.boundaryEdgeSegments == 0)
        #expect(initial.volume > 450)

        try store.setParameter(featureId: sweep.id, key: "start_tangent_y", value: 24)
        let retangent = try await KernelService.validate(documentURL: store.documentURL, featureId: sweep.id)
        #expect(abs(retangent.volume - initial.volume) > 1)
        store.undo()
        #expect(store.selectedFeature?.params["start_tangent_y"] == 16)
        try store.setParameter(featureId: sweep.id, key: "path_1_y", value: 18)
        let reshaped = try await KernelService.validate(documentURL: store.documentURL, featureId: sweep.id)
        #expect(abs(reshaped.volume - initial.volume) > 1)
        store.undo()
        #expect(store.selectedFeature?.params["path_1_y"] == 10)
        #expect(throws: CADValidationError.self) { try store.setParameter(featureId: sweep.id, key: "path_point_count", value: 3) }
        store.deleteFeature(featureId: sweep.id)
        #expect(store.document.features.first { $0.id == sketch.id }?.visible == true)
        #expect(store.selectedFeatureId == sketch.id)
    }

    @Test func circleProfileSweepsAlongEditableCompositeLineArcGuide() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        try store.createProfileSketch(name: "Composite profile", plane: "XY")
        let sketch = try #require(store.selectedFeature)
        try store.addSketchEntity(sketchId: sketch.id, entity: CADSketchEntity(id: "composite-circle", kind: "circle", params: ["cx": 0, "cy": 0, "radius": 2]))
        try store.createCompositeSweep(sketchId: sketch.id)
        let sweep = try #require(store.selectedFeature)
        #expect(sweep.kind == "sweep_feature")
        #expect(sweep.params["path_segment_count"] == 3)
        #expect(sweep.params["path_1_kind"] == 1)
        #expect(sweep.params["path_1_mid_x"] == 8)
        #expect(store.document.features.first { $0.id == sketch.id }?.visible == false)
        await store.refreshKernelMeshes()
        let mesh = try #require(store.kernelRenderMeshes.first { $0.featureId == sweep.id })
        #expect(mesh.indices.count > 500)
        let initial = try await KernelService.validate(documentURL: store.documentURL, featureId: sweep.id)
        #expect(initial.canExportStep)
        #expect(initial.boundaryEdgeSegments == 0)
        #expect(initial.closedManifoldMesh)

        try store.setParameter(featureId: sweep.id, key: "path_1_mid_x", value: 12)
        let reshaped = try await KernelService.validate(documentURL: store.documentURL, featureId: sweep.id)
        #expect(abs(reshaped.volume - initial.volume) > 1)
        try store.setParameter(featureId: sweep.id, key: "path_0_end_x", value: 2)
        #expect(store.selectedFeature?.params["path_0_end_x"] == 2)
        #expect(store.selectedFeature?.params["path_1_start_x"] == 2)
        let connected = try await KernelService.validate(documentURL: store.documentURL, featureId: sweep.id)
        #expect(connected.boundaryEdgeSegments == 0)
        store.undo()
        #expect(store.selectedFeature?.params["path_0_end_x"] == 0)
        #expect(store.selectedFeature?.params["path_1_start_x"] == 0)
        store.undo()
        #expect(store.selectedFeature?.params["path_1_mid_x"] == 8)
        #expect(throws: CADValidationError.self) { try store.setParameter(featureId: sweep.id, key: "path_1_kind", value: 0) }
        store.deleteFeature(featureId: sweep.id)
        #expect(store.document.features.first { $0.id == sketch.id }?.visible == true)
        #expect(store.selectedFeatureId == sketch.id)
    }

    @Test func variableProfileSweepRegeneratesThroughEditableScaleStation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        try store.createProfileSketch(name: "Variable profile", plane: "XY")
        let sketch = try #require(store.selectedFeature)
        try store.addSketchEntity(sketchId: sketch.id, entity: CADSketchEntity(id: "variable-circle", kind: "circle", params: ["cx": 0, "cy": 0, "radius": 2]))
        try store.createSweep(sketchId: sketch.id, scaleStations: [CADSweepScaleStation(position: 0.5, scale: 1.5)])
        let sweep = try #require(store.selectedFeature)
        #expect(sweep.params["scale_station_count"] == 1)
        #expect(sweep.params["scale_station_0_position"] == 0.5)
        #expect(sweep.params["scale_station_0_factor"] == 1.5)
        await store.refreshKernelMeshes()
        let mesh = try #require(store.kernelRenderMeshes.first { $0.featureId == sweep.id })
        #expect(mesh.indices.count > 500)
        let initial = try await KernelService.validate(documentURL: store.documentURL, featureId: sweep.id)
        #expect(initial.canExportStep)
        #expect(initial.stepRoundtrip.passed)
        #expect(initial.closedManifoldMesh)
        #expect(initial.boundaryEdgeSegments == 0)

        #expect(throws: CADValidationError.self) { try store.setParameter(featureId: sweep.id, key: "scale_station_0_position", value: 1) }
        #expect(throws: CADValidationError.self) { try store.setParameter(featureId: sweep.id, key: "scale_station_count", value: 2) }
        try store.setParameter(featureId: sweep.id, key: "scale_station_0_factor", value: 2)
        let expanded = try await KernelService.validate(documentURL: store.documentURL, featureId: sweep.id)
        #expect(expanded.volume > initial.volume * 1.35)
        #expect(expanded.closedManifoldMesh)
        store.undo()
        #expect(store.selectedFeature?.params["scale_station_0_factor"] == 1.5)
        store.deleteFeature(featureId: sweep.id)
        #expect(store.document.features.first { $0.id == sketch.id }?.visible == true)
    }

    @Test func morphSweepInterpolatesMixedProfileTopologiesAndRegenerates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)

        try store.createProfileSketch(name: "Round start", plane: "XY")
        let start = try #require(store.selectedFeature)
        try store.addSketchEntity(sketchId: start.id, entity: CADSketchEntity(id: "morph-start-circle", kind: "circle", params: ["cx": 0, "cy": 0, "radius": 2]))

        try store.createProfileSketch(name: "Wide middle", plane: "XY")
        let middle = try #require(store.selectedFeature)
        let corners = [SIMD2(-4.0, -1.0), SIMD2(4.0, -1.0), SIMD2(4.0, 1.0), SIMD2(-4.0, 1.0)]
        for index in corners.indices {
            let a = corners[index], b = corners[(index + 1) % corners.count]
            try store.addSketchEntity(sketchId: middle.id, entity: CADSketchEntity(id: "morph-mid-\(index)", kind: "line", params: ["x1": a.x, "y1": a.y, "x2": b.x, "y2": b.y]))
        }

        try store.createProfileSketch(name: "Round end", plane: "XY")
        let end = try #require(store.selectedFeature)
        try store.addSketchEntity(sketchId: end.id, entity: CADSketchEntity(id: "morph-end-circle", kind: "circle", params: ["cx": 0, "cy": 0, "radius": 3]))

        try store.createSweep(sketchId: start.id, end: SIMD3(0, 0, 40), profileSections: [
            CADSweepProfileSection(sketchId: middle.id, position: 0.5),
            CADSweepProfileSection(sketchId: end.id, position: 1)
        ])
        let sweep = try #require(store.selectedFeature)
        #expect(sweep.name.hasPrefix("Morph sweep"))
        #expect(sweep.inputFeatureIds == [start.id, middle.id, end.id])
        #expect(sweep.params["profile_station_count"] == 2)
        await store.refreshKernelMeshes()
        let mesh = try #require(store.kernelRenderMeshes.first { $0.featureId == sweep.id })
        #expect(mesh.indices.count > 2_000)
        let initial = try await KernelService.validate(documentURL: store.documentURL, featureId: sweep.id)
        #expect(initial.canExportStep)
        #expect(initial.stepRoundtrip.passed)
        #expect(initial.closedManifoldMesh)
        #expect(initial.boundaryEdgeSegments == 0)

        try store.setParameter(featureId: sweep.id, key: "profile_station_0_position", value: 0.3)
        let regenerated = try await KernelService.validate(documentURL: store.documentURL, featureId: sweep.id)
        #expect(abs(regenerated.volume - initial.volume) > 5)
        #expect(throws: CADValidationError.self) { try store.setParameter(featureId: sweep.id, key: "profile_station_1_position", value: 0.9) }
        #expect(throws: CADValidationError.self) { try store.setParameter(featureId: sweep.id, key: "profile_station_count", value: 3) }
        store.deleteFeature(featureId: sweep.id)
        for sourceId in [start.id, middle.id, end.id] {
            #expect(store.document.features.first { $0.id == sourceId }?.visible == true)
        }
    }

    @Test func assemblyInstancesSolveMatesRenderSTEPAndReportInterference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        store.addPrimitive(kind: "box")
        let source = try #require(store.selectedFeature)
        try store.setParameter(featureId: source.id, key: "width", value: 10)
        try store.setParameter(featureId: source.id, key: "height", value: 10)
        try store.setParameter(featureId: source.id, key: "depth", value: 10)
        try store.setMaterial(featureId: source.id, preset: .aluminum6061)
        try store.createAssemblyInstance(sourceFeatureId: source.id, name: "Base block")
        let base = try #require(store.selectedFeature)
        try store.createAssemblyInstance(sourceFeatureId: source.id, name: "Follower block", position: SIMD3(30, 0, 0))
        let follower = try #require(store.selectedFeature)
        #expect(store.assemblyInstances.count == 2)
        let baseExplode = CADExplodedView.offset(for: base.id, in: store.document, distance: 35)
        let followerExplode = CADExplodedView.offset(for: follower.id, in: store.document, distance: 35)
        #expect(abs(Double(simd_length(baseExplode)) - 35) < 0.001)
        #expect(abs(Double(simd_length(followerExplode)) - 35) < 0.001)
        #expect(simd_distance(baseExplode, followerExplode) > 60)
        #expect(store.document.features.first { $0.id == source.id }?.visible == false)
        try store.createFixedMate(instanceId: base.id)
        try store.createCoincidentMate(referenceInstanceId: base.id, movingInstanceId: follower.id, offset: SIMD3(20, 0, 0))
        let mate = try #require(store.selectedFeature)
        #expect(store.document.features.first { $0.id == base.id }?.params["fixed"] == 1)
        #expect(store.document.features.first { $0.id == follower.id }?.params["x"] == 20)
        #expect(store.drivingMate(for: follower.id)?.id == mate.id)
        #expect(throws: CADValidationError.self) { try store.setTransform(featureId: base.id, x: 1, y: 0, z: 0) }
        #expect(throws: CADValidationError.self) { try store.setTransform(featureId: follower.id, x: 25, y: 0, z: 0) }

        await store.refreshKernelMeshes()
        #expect(store.kernelRenderMeshes.contains { $0.featureId == base.id })
        #expect(store.kernelRenderMeshes.contains { $0.featureId == follower.id })
        #expect(store.material(for: follower) == .aluminum6061)
        #expect(store.assemblyMassSummary.assignedInstanceCount == 2)
        #expect(store.assemblyMassSummary.totalInstanceCount == 2)
        #expect(abs(store.assemblyMassSummary.totalMassGrams - 5.4) < 0.05)
        let validation = try await KernelService.validate(documentURL: store.documentURL, featureId: follower.id)
        #expect(validation.canExportStep)
        #expect(validation.stepRoundtrip.passed)
        #expect(validation.closedManifoldMesh)
        store.selectedFeatureId = follower.id
        await store.checkClearance(to: base.id)
        let clear = try #require(store.clearanceResult)
        #expect(clear.classification == "clear")
        #expect(abs(clear.distance - 10) < 0.01)

        try store.setParameter(featureId: mate.id, key: "offset_x", value: 5)
        #expect(store.document.features.first { $0.id == follower.id }?.params["x"] == 5)
        store.selectedFeatureId = follower.id
        await store.checkClearance(to: base.id)
        let interference = try #require(store.clearanceResult)
        #expect(interference.classification == "interference")
        #expect(interference.intersecting)

        store.deleteFeature(featureId: mate.id)
        #expect(throws: CADValidationError.self) { try store.createDistanceMate(referenceInstanceId: base.id, movingInstanceId: follower.id, axis: .zero, distance: 25) }
        try store.createDistanceMate(referenceInstanceId: base.id, movingInstanceId: follower.id, axis: SIMD3(0, 1, 0), distance: 25)
        let distanceMate = try #require(store.selectedFeature)
        #expect(distanceMate.params["mate_type"] == 2)
        #expect(store.document.features.first { $0.id == follower.id }?.params["x"] == 0)
        #expect(store.document.features.first { $0.id == follower.id }?.params["y"] == 25)
        try store.setParameter(featureId: distanceMate.id, key: "distance", value: 15)
        #expect(store.document.features.first { $0.id == follower.id }?.params["y"] == 15)
        store.undo()
        #expect(store.document.features.first { $0.id == follower.id }?.params["y"] == 25)
        #expect(store.validate().isEmpty)
        let motionRevision = store.document.revision
        try store.configureMotionStudy(mateId: distanceMate.id, parameter: "distance", minimum: 5, maximum: 30, progress: 0.5)
        #expect(store.motionStudy?.value == 17.5)
        #expect(abs((store.motionPreviewDocument.features.first { $0.id == follower.id }?.params["y"] ?? 0) - 17.5) < 0.001)
        #expect(store.document.features.first { $0.id == follower.id }?.params["y"] == 25)
        store.toggleMotionPlayback()
        let beforeMotionProgress = store.motionStudy?.progress ?? 0
        store.advanceMotion()
        #expect((store.motionStudy?.progress ?? 0) > beforeMotionProgress)
        store.toggleMotionPlayback()
        store.clearMotionStudy()
        #expect(store.motionStudy == nil)
        #expect(store.document.revision == motionRevision)
        let assemblySTEP = root.appendingPathComponent("assembly.step")
        let exportedAssembly = try await KernelService.exportAssemblyStep(documentURL: store.documentURL, to: assemblySTEP)
        #expect(exportedAssembly.instanceCount == 2)
        #expect(exportedAssembly.bodyCount == 2)
        #expect(exportedAssembly.stepRoundtrip.passed)
        #expect(abs(exportedAssembly.volume - 2_000) < 0.1)
        #expect((try Data(contentsOf: assemblySTEP)).starts(with: Data("ISO-10303-21".utf8)))
        store.deleteFeature(featureId: distanceMate.id)
        try store.createPlaneMate(referenceInstanceId: base.id, movingInstanceId: follower.id, referenceNormal: SIMD3(0, 0, 1), movingNormal: SIMD3(1, 0, 0), distance: 20)
        let planeMate = try #require(store.selectedFeature)
        #expect(planeMate.params["mate_type"] == 3)
        #expect(abs((store.document.features.first { $0.id == follower.id }?.params["z"] ?? 0) - 20) < 0.001)
        #expect(abs((store.document.features.first { $0.id == follower.id }?.params["rotation_y"] ?? 0) + 90) < 0.001)
        #expect(throws: CADValidationError.self) { try store.setRotation(featureId: follower.id, x: 0, y: 0, z: 0) }
        #expect(throws: CADValidationError.self) { try store.setParameter(featureId: planeMate.id, key: "distance", value: -1) }
        try store.setParameter(featureId: planeMate.id, key: "spin", value: 45)
        #expect(store.document.features.first { $0.id == planeMate.id }?.params["spin"] == 45)
        #expect(store.validate().isEmpty)
        store.deleteFeature(featureId: planeMate.id)
        try store.createConcentricMate(referenceInstanceId: base.id, movingInstanceId: follower.id, referenceAxis: SIMD3(0, 0, 1), movingAxis: SIMD3(1, 0, 0), axialOffset: 30)
        let concentricMate = try #require(store.selectedFeature)
        #expect(concentricMate.params["mate_type"] == 4)
        #expect(abs((store.document.features.first { $0.id == follower.id }?.params["z"] ?? 0) - 30) < 0.001)
        #expect(abs((store.document.features.first { $0.id == follower.id }?.params["rotation_y"] ?? 0) + 90) < 0.001)
        #expect(throws: CADValidationError.self) { try store.setTransform(featureId: follower.id, x: 0, y: 0, z: 0) }
        #expect(throws: CADValidationError.self) { try store.setRotation(featureId: follower.id, x: 0, y: 0, z: 0) }
        try store.setParameter(featureId: concentricMate.id, key: "axial_offset", value: -10)
        try store.setParameter(featureId: concentricMate.id, key: "spin", value: 30)
        #expect(abs((store.document.features.first { $0.id == follower.id }?.params["z"] ?? 0) + 10) < 0.001)
        #expect(store.validate().isEmpty)
        let concentricValidation = try await KernelService.validate(documentURL: store.documentURL, featureId: follower.id)
        #expect(concentricValidation.stepRoundtrip.passed)
        store.deleteFeature(featureId: concentricMate.id)
        try store.createDistanceMate(referenceInstanceId: base.id, movingInstanceId: follower.id, axis: SIMD3(1, 0, 0), distance: 20)
        let composedDistance = try #require(store.selectedFeature)
        try store.createAngleMate(referenceInstanceId: base.id, movingInstanceId: follower.id, referenceNormal: SIMD3(0, 0, 1), movingNormal: SIMD3(0, 0, 1), hingeAxis: SIMD3(1, 0, 0), angle: 90)
        let angleMate = try #require(store.selectedFeature)
        let composedFollower = try #require(store.document.features.first { $0.id == follower.id })
        #expect(store.drivingMates(for: follower.id).count == 2)
        #expect(store.assemblyDegreesOfFreedom(for: composedFollower) == 1)
        #expect(abs((composedFollower.params["x"] ?? 0) - 20) < 0.001)
        #expect(abs((composedFollower.params["rotation_x"] ?? 0) - 90) < 0.001)
        #expect(throws: CADValidationError.self) { try store.createAngleMate(referenceInstanceId: base.id, movingInstanceId: follower.id) }
        #expect(throws: CADValidationError.self) { try store.setTransform(featureId: follower.id, x: 0, y: 0, z: 0) }
        #expect(throws: CADValidationError.self) { try store.setRotation(featureId: follower.id, x: 0, y: 0, z: 0) }
        try store.setParameter(featureId: angleMate.id, key: "angle", value: 45)
        #expect(abs((store.document.features.first { $0.id == follower.id }?.params["rotation_x"] ?? 0) - 45) < 0.001)
        #expect(store.validate().isEmpty)
        let composedValidation = try await KernelService.validate(documentURL: store.documentURL, featureId: follower.id)
        #expect(composedValidation.stepRoundtrip.passed)
        store.deleteFeature(featureId: angleMate.id)
        store.deleteFeature(featureId: composedDistance.id)
        let fixedMate = try #require(store.assemblyMates.first)
        store.deleteFeature(featureId: fixedMate.id)
        store.deleteFeature(featureId: follower.id)
        #expect(store.document.features.first { $0.id == source.id }?.visible == false)
        store.deleteFeature(featureId: base.id)
        #expect(store.document.features.first { $0.id == source.id }?.visible == true)
    }

    @Test func retainedSTEPImportRendersValidatesAndReexports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        store.addPrimitive(kind: "box")
        let source = try #require(store.selectedFeature)
        try store.setParameter(featureId: source.id, key: "width", value: 10)
        try store.setParameter(featureId: source.id, key: "height", value: 10)
        try store.setParameter(featureId: source.id, key: "depth", value: 10)
        let sourceSTEP = root.appendingPathComponent("source.step")
        let exported = try await KernelService.exportStep(documentURL: store.documentURL, featureId: source.id, to: sourceSTEP)
        #expect(exported.validation.stepRoundtrip.passed)
        let revision = store.document.revision
        let imported = try await store.importSTEP(from: sourceSTEP)
        let feature = try #require(imported.first)
        #expect(imported.count == 1)
        #expect(feature.kind == "imported_step")
        #expect(feature.params["body_number"] == 1)
        #expect(feature.assetPath.map { FileManager.default.fileExists(atPath: $0) } == true)
        #expect(store.document.revision == revision + 1)
        await store.refreshKernelMeshes()
        #expect(store.kernelRenderMeshes.contains { $0.featureId == feature.id && !$0.indices.isEmpty })
        let validation = try await KernelService.validate(documentURL: store.documentURL, featureId: feature.id)
        #expect(validation.ok)
        #expect(validation.canExportStep)
        #expect(validation.stepRoundtrip.passed)
        #expect(abs(validation.volume - 1_000) < 0.1)
        let reexportURL = root.appendingPathComponent("reexport.step")
        let reexported = try await KernelService.exportStep(documentURL: store.documentURL, featureId: feature.id, to: reexportURL)
        #expect(reexported.validation.stepRoundtrip.passed)
        #expect((try Data(contentsOf: reexportURL)).starts(with: Data("ISO-10303-21".utf8)))
        let projectURL = root.appendingPathComponent("portable.axiscad")
        try store.exportJSON(to: projectURL)
        let portable = try JSONDecoder().decode(CADDocument.self, from: Data(contentsOf: projectURL))
        let portablePath = try #require(portable.features.first { $0.id == feature.id }?.assetPath)
        #expect(!portablePath.hasPrefix("/"))
        #expect(FileManager.default.fileExists(atPath: projectURL.deletingLastPathComponent().appendingPathComponent(portablePath).path))
        let reopened = DocumentStore(dataDirectory: root.appendingPathComponent("reopened"))
        try reopened.openDocument(from: projectURL)
        let reopenedFeature = try #require(reopened.document.features.first { $0.id == feature.id })
        #expect(reopenedFeature.assetPath?.hasPrefix(reopened.dataDirectory.path) == true)
        let reopenedValidation = try await KernelService.validate(documentURL: reopened.documentURL, featureId: feature.id)
        #expect(reopenedValidation.stepRoundtrip.passed)
        #expect(abs(reopenedValidation.volume - 1_000) < 0.1)
    }

    @Test func offsetProfilesLoftAndRebuildWhenSectionMoves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        try store.createProfileSketch(name: "Lower section", plane: "XY", offset: 0)
        let lower = try #require(store.selectedFeature)
        try store.addSketchEntity(sketchId: lower.id, entity: CADSketchEntity(id: "lower-circle", kind: "circle", params: ["cx": 0, "cy": 0, "radius": 5]))
        try store.createProfileSketch(name: "Upper section", plane: "XY", offset: 20)
        let upper = try #require(store.selectedFeature)
        try store.addSketchEntity(sketchId: upper.id, entity: CADSketchEntity(id: "upper-circle", kind: "circle", params: ["cx": 0, "cy": 0, "radius": 2]))
        try store.createLoft(sketchIds: [lower.id, upper.id])
        let loft = try #require(store.selectedFeature)
        #expect(loft.kind == "loft_feature")
        #expect(loft.inputFeatureIds == [lower.id, upper.id])
        #expect(store.document.features.first { $0.id == lower.id }?.visible == false)
        #expect(store.document.features.first { $0.id == upper.id }?.visible == false)
        await store.refreshKernelMeshes()
        let mesh = try #require(store.kernelRenderMeshes.first { $0.featureId == loft.id })
        #expect(mesh.indices.count >= 36)
        let initial = try await KernelService.validate(documentURL: store.documentURL, featureId: loft.id)
        #expect(initial.volume > 400 && initial.volume < 1_200)
        #expect(initial.canExportStep)

        try store.setParameter(featureId: upper.id, key: "offset", value: 30)
        let extended = try await KernelService.validate(documentURL: store.documentURL, featureId: loft.id)
        #expect(abs(extended.volume / initial.volume - 1.5) < 0.03)
        store.deleteFeature(featureId: loft.id)
        #expect(store.document.features.first { $0.id == lower.id }?.visible == true)
        #expect(store.document.features.first { $0.id == upper.id }?.visible == true)
        #expect(store.selectedFeatureId == lower.id)
    }

    @Test func codexPromptConstrainsTheAgentToMCPGeometryTools() {
        let prompt = CodexService.agentPrompt(for: "make the box 40 mm wide")
        #expect(prompt.contains("axis_cad_get_document"))
        #expect(prompt.contains("axis_cad_validate_document"))
        #expect(prompt.contains("axis_cad_create_profile_sketch"))
        #expect(prompt.contains("axis_cad_create_extrusion"))
        #expect(prompt.contains("axis_cad_create_pocket"))
        #expect(prompt.contains("axis_cad_create_revolve"))
        #expect(prompt.contains("axis_cad_create_sweep"))
        #expect(prompt.contains("axis_cad_create_spline_sweep"))
        #expect(prompt.contains("axis_cad_create_helix_sweep"))
        #expect(prompt.contains("axis_cad_create_loft"))
        #expect(prompt.contains("axis_cad_get_view"))
        #expect(prompt.contains("axis_cad_set_section"))
        #expect(prompt.contains("axis_cad_set_isolate"))
        #expect(prompt.contains("axis_cad_set_measurement"))
        #expect(prompt.contains("axis_cad_rotate_feature"))
        #expect(prompt.contains("axis_cad_create_body_transform"))
        #expect(prompt.contains("axis_cad_scale_feature"))
        #expect(prompt.contains("axis_cad_set_material"))
        #expect(prompt.contains("axis_cad_get_bom"))
        #expect(prompt.contains("axis_cad_set_motion_study"))
        #expect(prompt.contains("axis_cad_import_step"))
        #expect(prompt.contains("axis_cad_add_sketch_constraint"))
        #expect(prompt.contains("axis_cad_trim_extend_sketch_line"))
        #expect(prompt.contains("Do not edit the shared JSON with shell commands"))
        #expect(prompt.contains("make the box 40 mm wide"))
    }

    @Test func constrainedSketchSolvesSymmetricHolesAndRejectsConflicts() throws {
        let solved = SketchSolver.solve(width: 96, height: 60, holeDiameter: 6, holeOffset: 14)
        #expect(solved.isFullyConstrained)
        #expect(solved.holes.count == 4)
        #expect(solved.holes[0].center.x == -34)
        #expect(solved.holes[0].center.y == 16)

        let conflict = SketchSolver.solve(width: 40, height: 30, holeDiameter: 12, holeOffset: 5)
        #expect(!conflict.isFullyConstrained)
        #expect(!conflict.errors.isEmpty)
    }

    @Test func generalSketchConstraintsSolvePersistAndCleanUpWithEntities() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        try store.createProfileSketch(name: "Constraint sketch", plane: "XY")
        let sketchId = try #require(store.selectedFeatureId)
        try store.addSketchEntity(sketchId: sketchId, entity: CADSketchEntity(id: "line-a", kind: "line", params: ["x1": 0, "y1": 0, "x2": 9, "y2": 2]))
        try store.addSketchEntity(sketchId: sketchId, entity: CADSketchEntity(id: "line-b", kind: "line", params: ["x1": 12, "y1": 3, "x2": 14, "y2": 10]))
        try store.addSketchConstraint(sketchId: sketchId, constraint: CADSketchConstraint(id: "horizontal-a", kind: "horizontal", entities: ["line-a"]))
        try store.addSketchConstraint(sketchId: sketchId, constraint: CADSketchConstraint(id: "join-lines", kind: "coincident", entities: ["line-a:end", "line-b:start"]))
        try store.addSketchConstraint(sketchId: sketchId, constraint: CADSketchConstraint(id: "vertical-b", kind: "vertical", entities: ["line-b"]))
        try store.addSketchConstraint(sketchId: sketchId, constraint: CADSketchConstraint(id: "length-a", kind: "length", entities: ["line-a"], value: 9))

        var feature = try #require(store.document.features.first { $0.id == sketchId })
        var solution = CADProfileSketch.solve(feature: feature)
        #expect(solution.constraintCount == 4)
        #expect(solution.degreesOfFreedom == 3)
        let lineA = try #require(feature.sketch?.entities?.first { $0.id == "line-a" })
        let lineB = try #require(feature.sketch?.entities?.first { $0.id == "line-b" })
        #expect(lineA.params["y2"] == 0)
        #expect(lineB.params["x1"] == 9 && lineB.params["x2"] == 9)
        #expect(simd_distance(try #require(CADProfileSketch.endpoint(lineA, start: false)), try #require(CADProfileSketch.endpoint(lineB, start: true))) < 0.001)

        try store.addSketchEntity(sketchId: sketchId, entity: CADSketchEntity(id: "line-c", kind: "line", params: ["x1": 20, "y1": 0, "x2": 24, "y2": 7]))
        try store.addSketchConstraint(sketchId: sketchId, constraint: CADSketchConstraint(id: "parallel-c", kind: "parallel", entities: ["line-a", "line-c"]))
        try store.addSketchConstraint(sketchId: sketchId, constraint: CADSketchConstraint(id: "equal-c", kind: "equal", entities: ["line-a", "line-c"]))
        try store.addSketchEntity(sketchId: sketchId, entity: CADSketchEntity(id: "line-d", kind: "line", params: ["x1": -10, "y1": 0, "x2": -6, "y2": 3]))
        try store.addSketchConstraint(sketchId: sketchId, constraint: CADSketchConstraint(id: "perpendicular-d", kind: "perpendicular", entities: ["line-a", "line-d"]))

        feature = try #require(store.document.features.first { $0.id == sketchId })
        solution = CADProfileSketch.solve(feature: feature)
        #expect(solution.constraintCount == 7)
        #expect(solution.degreesOfFreedom == 8)
        let lineC = try #require(feature.sketch?.entities?.first { $0.id == "line-c" })
        let lineD = try #require(feature.sketch?.entities?.first { $0.id == "line-d" })
        let directionA = try #require(CADProfileSketch.endpoint(lineA, start: false)) - (try #require(CADProfileSketch.endpoint(lineA, start: true)))
        let directionC = try #require(CADProfileSketch.endpoint(lineC, start: false)) - (try #require(CADProfileSketch.endpoint(lineC, start: true)))
        let directionD = try #require(CADProfileSketch.endpoint(lineD, start: false)) - (try #require(CADProfileSketch.endpoint(lineD, start: true)))
        #expect(abs(directionA.x * directionC.y - directionA.y * directionC.x) < 0.001)
        #expect(abs(simd_length(directionA) - simd_length(directionC)) < 0.001)
        #expect(abs(simd_dot(simd_normalize(directionA), simd_normalize(directionD))) < 0.001)

        try store.addSketchEntity(sketchId: sketchId, entity: CADSketchEntity(id: "guide-arc", kind: "arc", params: ["cx": 0, "cy": 0, "radius": 4, "start_angle": 0, "end_angle": Double.pi / 2, "ccw": 1]))
        try store.addSketchConstraint(sketchId: sketchId, constraint: CADSketchConstraint(id: "tangent-guide", kind: "tangent", entities: ["line-d", "guide-arc"]))
        try store.toggleSketchEntityConstruction(sketchId: sketchId, entityId: "guide-arc")
        feature = try #require(store.document.features.first { $0.id == sketchId })
        let guideArc = try #require(feature.sketch?.entities?.first { $0.id == "guide-arc" })
        #expect(guideArc.construction == true)
        let arcEnd = try #require(CADProfileSketch.endpoint(guideArc, start: false))
        let lineDStart = try #require(CADProfileSketch.endpoint(lineD, start: true)), lineDEnd = try #require(CADProfileSketch.endpoint(lineD, start: false))
        let lineDVector = lineDEnd - lineDStart
        let guideCenter = SIMD2(try #require(guideArc.params["cx"]), try #require(guideArc.params["cy"]))
        let guideDistance = abs(lineDVector.x * (lineDStart.y - guideCenter.y) - (lineDStart.x - guideCenter.x) * lineDVector.y) / simd_length(lineDVector)
        #expect(abs(guideDistance - 4) < 0.001)
        #expect(simd_distance(arcEnd, guideCenter + SIMD2(0, 4)) < 0.001)

        try store.deleteSketchEntity(sketchId: sketchId, entityId: "guide-arc")

        try store.updateSketchConstraintValue(sketchId: sketchId, constraintId: "length-a", value: 11)
        feature = try #require(store.document.features.first { $0.id == sketchId })
        let resizedA = try #require(feature.sketch?.entities?.first { $0.id == "line-a" })
        let resizedB = try #require(feature.sketch?.entities?.first { $0.id == "line-b" })
        let resizedC = try #require(feature.sketch?.entities?.first { $0.id == "line-c" })
        #expect(abs(simd_distance(try #require(CADProfileSketch.endpoint(resizedA, start: true)), try #require(CADProfileSketch.endpoint(resizedA, start: false))) - 11) < 0.001)
        #expect(abs(simd_distance(try #require(CADProfileSketch.endpoint(resizedC, start: true)), try #require(CADProfileSketch.endpoint(resizedC, start: false))) - 11) < 0.001)
        #expect(resizedB.params["x1"] == 11 && resizedB.params["x2"] == 11)

        try store.deleteSketchConstraint(sketchId: sketchId, constraintId: "vertical-b")
        try store.deleteSketchEntity(sketchId: sketchId, entityId: "line-b")
        feature = try #require(store.document.features.first { $0.id == sketchId })
        solution = CADProfileSketch.solve(feature: feature)
        #expect(feature.sketch?.constraints.map(\.id).sorted() == ["equal-c", "horizontal-a", "length-a", "parallel-c", "perpendicular-d"])
        #expect(solution.constraintCount == 5)
        store.undo()
        #expect(store.document.features.first { $0.id == sketchId }?.sketch?.entities?.contains { $0.id == "line-b" } == true)
    }

    @Test func coupledConstraintChainsConvergeBeyondLegacyPassLimit() throws {
        var entities: [CADSketchEntity] = []
        for index in 0..<12 {
            let params: [String: Double] = [
                "x1": Double(index * 10), "y1": Double(index),
                "x2": Double(index * 10 + 4), "y2": Double(index + 2)
            ]
            entities.append(CADSketchEntity(id: "chain-\(index)", kind: "line", params: params))
        }
        let constraints = (0..<11).reversed().map { index in
            CADSketchConstraint(
                id: "join-\(index)", kind: "coincident",
                entities: ["chain-\(index):start", "chain-\(index + 1):start"]
            )
        }
        let solved = try CADProfileSketch.solving(constraints, entities: entities)
        for entity in solved {
            let start = try #require(CADProfileSketch.endpoint(entity, start: true))
            #expect(simd_distance(start, .zero) < 0.001)
        }
        do {
            _ = try CADProfileSketch.solving([
                CADSketchConstraint(id: "missing-link", kind: "coincident", entities: ["chain-0:start", "missing:start"])
            ], entities: entities)
            Issue.record("Expected the invalid coupled constraint to fail")
        } catch let CADValidationError.constraintConflict(detail) {
            #expect(detail.contains("missing-link"))
        }
    }

    @Test func coupledConstraintOrderProducesTheSameSolvedGeometry() throws {
        var entities: [CADSketchEntity] = []
        for index in 0..<6 {
            let params: [String: Double] = [
                "x1": Double(index * 5), "y1": Double(index),
                "x2": Double(index * 5 + 3), "y2": Double(index + 1)
            ]
            entities.append(CADSketchEntity(id: "line-\(index)", kind: "line", params: params))
        }
        var constraints: [CADSketchConstraint] = []
        for index in 0..<5 {
            constraints.append(CADSketchConstraint(id: "join-\(index)", kind: "coincident", entities: ["line-\(index):start", "line-\(index + 1):start"]))
        }
        let forward = try CADProfileSketch.solving(constraints, entities: entities)
        let reversed = try CADProfileSketch.solving(Array(constraints.reversed()), entities: entities)
        for (left, right) in zip(forward, reversed) {
            let leftPoint = try #require(CADProfileSketch.endpoint(left, start: true))
            let rightPoint = try #require(CADProfileSketch.endpoint(right, start: true))
            #expect(simd_distance(leftPoint, rightPoint) < 0.001)
        }
    }

    @Test func angleConstraintSolvesTwoLineDirections() throws {
        let entities = [
            CADSketchEntity(id: "base", kind: "line", params: ["x1": 0, "y1": 0, "x2": 10, "y2": 0]),
            CADSketchEntity(id: "arm", kind: "line", params: ["x1": 0, "y1": 0, "x2": 3, "y2": 2])
        ]
        let angle = CADSketchConstraint(id: "angle", kind: "angle", entities: ["base", "arm"], value: 60)
        let solved = try CADProfileSketch.solving([angle], entities: entities)
        let base = try #require(solved.first { $0.id == "base" })
        let arm = try #require(solved.first { $0.id == "arm" })
        let a = try #require(CADProfileSketch.endpoint(base, start: false)) - (try #require(CADProfileSketch.endpoint(base, start: true)))
        let b = try #require(CADProfileSketch.endpoint(arm, start: false)) - (try #require(CADProfileSketch.endpoint(arm, start: true)))
        let measured = acos(simd_dot(a, b) / (simd_length(a) * simd_length(b))) * 180 / .pi
        #expect(abs(measured - 60) < 0.05)
    }

    @Test func persistedAngleConstraintEditsInDegrees() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        try store.createProfileSketch(name: "Angle fixture", plane: "XY")
        let sketchId = try #require(store.selectedFeatureId)
        try store.addSketchEntity(sketchId: sketchId, entity: CADSketchEntity(id: "base", kind: "line", params: ["x1": 0, "y1": 0, "x2": 10, "y2": 0]))
        try store.addSketchEntity(sketchId: sketchId, entity: CADSketchEntity(id: "arm", kind: "line", params: ["x1": 0, "y1": 0, "x2": 3, "y2": 2]))
        try store.addSketchConstraint(sketchId: sketchId, constraint: CADSketchConstraint(id: "angle", kind: "angle", entities: ["base", "arm"], value: 45))
        try store.updateSketchConstraintValue(sketchId: sketchId, constraintId: "angle", value: 75)
        let sketch = try #require(store.document.features.first { $0.id == sketchId }?.sketch)
        let base = try #require(sketch.entities?.first { $0.id == "base" })
        let arm = try #require(sketch.entities?.first { $0.id == "arm" })
        let a = try #require(CADProfileSketch.endpoint(base, start: false)) - (try #require(CADProfileSketch.endpoint(base, start: true)))
        let b = try #require(CADProfileSketch.endpoint(arm, start: false)) - (try #require(CADProfileSketch.endpoint(arm, start: true)))
        let measured = acos(simd_dot(a, b) / (simd_length(a) * simd_length(b))) * 180 / .pi
        #expect(abs(measured - 75) < 0.05)
        #expect(throws: CADValidationError.self) { try store.updateSketchConstraintValue(sketchId: sketchId, constraintId: "angle", value: 180) }
    }

    @Test func sketchLinesTrimExtendRejectInvalidReferencesAndUndo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        try store.createProfileSketch(name: "Trim fixture", plane: "XY")
        let sketchId = try #require(store.selectedFeatureId)
        try store.addSketchEntity(sketchId: sketchId, entity: CADSketchEntity(id: "trim-target", kind: "line", params: ["x1": 0, "y1": 0, "x2": 10, "y2": 0]))
        try store.addSketchEntity(sketchId: sketchId, entity: CADSketchEntity(id: "trim-reference", kind: "line", params: ["x1": 6, "y1": -5, "x2": 6, "y2": 5], construction: true))
        try store.trimOrExtendSketchLine(sketchId: sketchId, lineId: "trim-target", referenceLineId: "trim-reference", endpoint: "end", mode: "trim")
        var target = try #require(store.document.features.first { $0.id == sketchId }?.sketch?.entities?.first { $0.id == "trim-target" })
        #expect(target.params["x2"] == 6 && target.params["y2"] == 0)
        store.undo()
        target = try #require(store.document.features.first { $0.id == sketchId }?.sketch?.entities?.first { $0.id == "trim-target" })
        #expect(target.params["x2"] == 10)
        store.redo()

        try store.addSketchEntity(sketchId: sketchId, entity: CADSketchEntity(id: "extend-target", kind: "line", params: ["x1": 0, "y1": 2, "x2": 4, "y2": 2]))
        try store.addSketchEntity(sketchId: sketchId, entity: CADSketchEntity(id: "extend-reference", kind: "line", params: ["x1": 8, "y1": -1, "x2": 8, "y2": 3], construction: true))
        try store.trimOrExtendSketchLine(sketchId: sketchId, lineId: "extend-target", referenceLineId: "extend-reference", endpoint: "end", mode: "extend")
        target = try #require(store.document.features.first { $0.id == sketchId }?.sketch?.entities?.first { $0.id == "extend-target" })
        #expect(target.params["x2"] == 8 && target.params["y2"] == 2)
        let revision = store.document.revision
        #expect(throws: CADValidationError.self) { try store.trimOrExtendSketchLine(sketchId: sketchId, lineId: "trim-target", referenceLineId: "extend-target", endpoint: "end", mode: "extend") }
        #expect(store.document.revision == revision)
    }

    @Test func sketchEditIsOneUndoableRevisionAndDrivesTheKernel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        let before = CADKernel.active.renderMesh(document: store.document, selectedFeatureId: nil).map(\.position.x).max() ?? 0
        try store.setSketchDimensions(width: 110, height: 64, holeDiameter: 7, holeOffset: 15)
        #expect(store.document.revision == 19)
        #expect(store.document.operations.first?.kind == "solve_sketch")
        let after = CADKernel.active.renderMesh(document: store.document, selectedFeatureId: nil).map(\.position.x).max() ?? 0
        #expect(after > before)
        store.undo()
        #expect(store.document.features.first { $0.id == "sketch-base" }?.params["width"] == 86)
    }

    @Test func newAndOpenDocumentPreserveRevisionSafetyAndUndo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        try store.newDocument(name: "Fixture")
        #expect(store.document.name == "Fixture")
        #expect(store.document.revision == 19)
        #expect(store.document.operations.first?.kind == "new_document")
        store.undo()
        #expect(store.document.name == "Wall bracket")

        var imported = CADDocument.newPart(name: "Imported fixture", revision: 2)
        imported.features[0].params["width"] = 120
        let importURL = root.appendingPathComponent("fixture.axis.json")
        try JSONEncoder().encode(imported).write(to: importURL)
        try store.openDocument(from: importURL)
        #expect(store.document.name == "Imported fixture")
        #expect(store.document.revision == 19)
        #expect(store.document.features[0].params["width"] == 120)
        #expect(store.document.operations.first?.kind == "open_document")
        #expect(store.recentDocumentPaths.first == importURL.path)
        let reopenedStore = DocumentStore(dataDirectory: root)
        #expect(reopenedStore.recentDocumentPaths.first == importURL.path)
    }

    @Test func nativeCheckpointRecoveryIsMonotonicAndUndoable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        try store.checkpoint(label: "baseline")
        let checkpoint = try #require(store.checkpointSummaries.first)
        #expect(checkpoint.revision == 18)
        try store.setParameter(featureId: "pad-base", key: "length", value: 12)
        #expect(store.document.revision == 19)
        try store.restoreCheckpoint(checkpoint)
        #expect(store.document.revision == 20)
        #expect(store.document.features.first { $0.id == "pad-base" }?.params["length"] == 6)
        #expect(store.document.operations.first?.kind == "restore_checkpoint")
        store.undo()
        #expect(store.document.revision == 19)
        #expect(store.document.features.first { $0.id == "pad-base" }?.params["length"] == 12)
    }

    @Test func meshMeasurementTracksDocumentBoundsAndVolume() {
        let base = CADMeasurement.measure(document: .seed)
        #expect(base.size.x == 86)
        #expect(base.size.y == 54)
        #expect(base.size.z == 6)
        #expect(base.volume > 0)
        #expect(base.surfaceArea > 0)
        #expect(base.triangleCount > 0)

        var wider = CADDocument.seed
        wider.features[0].params["width"] = 120
        #expect(CADMeasurement.measure(document: wider).size.x == 120)
    }

    @Test func hitTestingSelectsNearestFeatureAndIgnoresMisses() {
        var document = CADDocument.seed
        document.features.append(CADFeature(id: "box-hit", name: "Pick box", kind: "box", visible: true, params: ["width": 10, "height": 10, "depth": 10, "x": 0, "y": 0, "z": 20]))
        let hit = CADHitTester.firstHit(document: document, origin: SIMD3(0, 0, 60), direction: SIMD3(0, 0, -1))
        #expect(hit == "box-hit")
        let miss = CADHitTester.firstHit(document: document, origin: SIMD3(200, 200, 60), direction: SIMD3(0, 0, -1))
        #expect(miss == nil)
    }

    @Test func directTransformCommitsOneRevisionAndUndoRestoresPosition() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        store.addPrimitive(kind: "box")
        let box = try #require(store.selectedFeature)
        let revision = store.document.revision
        try store.setTransform(featureId: box.id, x: -12, y: 9, z: 18)
        #expect(store.document.revision == revision + 1)
        #expect(store.selectedFeature?.params["x"] == -12)
        #expect(store.document.operations.first?.kind == "transform_feature")
        store.undo()
        #expect(store.selectedFeature?.params["x"] == 0)
    }

    @Test func directRotationCommitsAllAxesInOneRevisionAndUndoes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        store.addPrimitive(kind: "cone")
        let cone = try #require(store.selectedFeature)
        let revision = store.document.revision
        try store.setRotation(featureId: cone.id, x: 30, y: -45, z: 120)
        #expect(store.document.revision == revision + 1)
        #expect(store.selectedFeature?.params["rotation_x"] == 30)
        #expect(store.selectedFeature?.params["rotation_y"] == -45)
        #expect(store.selectedFeature?.params["rotation_z"] == 120)
        #expect(store.document.operations.first?.kind == "rotate_feature")
        store.undo()
        #expect(store.selectedFeature?.params["rotation_x"] == 0)
        #expect(store.selectedFeature?.params["rotation_y"] == 0)
        #expect(store.selectedFeature?.params["rotation_z"] == 0)
    }

    @Test func selectionContextIsSharedWithoutChangingGeometryRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        let revision = store.document.revision
        let hit = CADSurfaceHit(featureId: "pocket-holes", position: SIMD3(2, 3, 3), normal: SIMD3(0, 0, 1), distance: 10, triangleIndex: 4, topologyFaceId: 7, topologyEdgeId: 3, topologyEdgeFaceIds: [2, 7])
        store.selectSurface(hit)
        let selection = try JSONDecoder().decode(CADSelectionState.self, from: Data(contentsOf: store.selectionURL))
        #expect(selection.revision == revision)
        #expect(selection.featureIds == ["pocket-holes"])
        #expect(selection.surface?.featureId == "pocket-holes")
        #expect(selection.surface?.triangleIndex == 4)
        #expect(selection.surface?.topologyFaceId == 7)
        #expect(selection.surface?.topologyEdgeId == 3)
        #expect(selection.surface?.topologyEdgeFaceIds == [2, 7])
        #expect(selection.surface?.position == CADSelectionVector(x: 2, y: 3, z: 3))
        #expect(selection.surface?.normal == CADSelectionVector(x: 0, y: 0, z: 1))
        #expect(store.document.revision == revision)
        store.selectedFeatureId = "pad-base"
        #expect(store.selectedSurface == nil)
        store.setSection(axis: "x", offset: 5, flipped: true)
        store.setExplodedDistance(35)
        let view = try JSONDecoder().decode(CADViewState.self, from: Data(contentsOf: store.viewURL))
        #expect(view.section == CADSectionPlane(axis: "x", offset: 5, flipped: true))
        #expect(view.explodedDistance == 35)
        #expect(view.measurement == nil)
        #expect(store.document.revision == revision)
        store.setIsolatedFeature("pad-base")
        #expect(store.isolatedFeatureId == "pad-base")
        #expect(store.document.revision == revision)
        let reloaded = DocumentStore(dataDirectory: root)
        #expect(reloaded.sectionPlane == view.section)
        #expect(reloaded.isolatedFeatureId == "pad-base")
        #expect(reloaded.explodedDistance == 35)
        reloaded.setExplodedDistance(0)
        #expect(reloaded.explodedDistance == 0)
        reloaded.setIsolatedFeature(nil)
        #expect(reloaded.isolatedFeatureId == nil)
        reloaded.clearSection()
        #expect(reloaded.sectionPlane == nil)
    }

    @Test func pointMeasurementPersistsWithoutRevisionAndClearsWhenGeometryChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(dataDirectory: root)
        let revision = store.document.revision
        store.toggleMeasurementMode()
        store.addMeasurementPoint(CADSurfaceHit(featureId: "pad-base", position: SIMD3(1, 2, 3), normal: SIMD3(0, 0, 1), distance: 4, triangleIndex: 0))
        #expect(store.measurementProbe?.end == nil)
        store.addMeasurementPoint(CADSurfaceHit(featureId: "pocket-holes", position: SIMD3(4, 6, 15), normal: SIMD3(1, 0, 0), distance: 8, triangleIndex: 2))
        #expect(store.document.revision == revision)
        #expect(store.measurementProbe?.delta == CADSelectionVector(x: 3, y: 4, z: 12))
        #expect(store.measurementProbe?.distance == 13)
        let view = try JSONDecoder().decode(CADViewState.self, from: Data(contentsOf: store.viewURL))
        #expect(view.measurement == store.measurementProbe)
        let reloaded = DocumentStore(dataDirectory: root)
        #expect(reloaded.measurementProbe?.distance == 13)
        try reloaded.setParameter(featureId: "pad-base", key: "length", value: 8)
        #expect(reloaded.measurementProbe == nil)
        let changedView = try JSONDecoder().decode(CADViewState.self, from: Data(contentsOf: reloaded.viewURL))
        #expect(changedView.measurement == nil)
    }

    @Test func projectedFeatureCenterRoundTripsThroughPickingRay() throws {
        var document = CADDocument.seed
        document.features.append(CADFeature(id: "box-camera", name: "Camera target", kind: "box", visible: true, params: ["width": 12, "height": 12, "depth": 12, "x": 30, "y": 5, "z": 18]))
        let size = CGSize(width: 900, height: 600)
        let center = SIMD3<Float>(30, 5, 18)
        let screen = try #require(CADCameraMath.project(modelPoint: center, viewportSize: size, yaw: -0.55, pitch: 0.55, distance: 4.4))
        let ray = try #require(CADCameraMath.ray(screenPoint: screen, viewportSize: size, yaw: -0.55, pitch: 0.55, distance: 4.4))
        let surface = CADHitTester.firstSurfaceHit(meshes: CADKernel.active.renderMeshes(document: document, selectedFeatureId: nil), origin: ray.origin, direction: ray.direction)
        #expect(surface?.featureId == "box-camera")
        let closest = ray.origin + ray.direction * simd_dot(center - ray.origin, ray.direction)
        #expect(simd_distance(closest, center) < 0.01)
    }

    @Test func transformGizmoHandlesPickAndProjectAxisMotion() throws {
        let size = CGSize(width: 900, height: 600), center = SIMD3<Float>(12, -4, 18)
        let yaw: Float = -0.55, pitch: Float = 0.55, distance: Float = 4.4
        for axis in CADTransformAxis.allCases {
            let midpoint = center + axis.vector * (CADTransformGizmoMath.handleLength * 0.65)
            let screen = try #require(CADCameraMath.project(modelPoint: midpoint, viewportSize: size, yaw: yaw, pitch: pitch, distance: distance))
            #expect(CADTransformGizmoMath.hitAxis(at: screen, center: center, viewportSize: size, yaw: yaw, pitch: pitch, distance: distance) == axis)
            let origin = try #require(CADCameraMath.project(modelPoint: center, viewportSize: size, yaw: yaw, pitch: pitch, distance: distance))
            let endpoint = try #require(CADCameraMath.project(modelPoint: center + axis.vector * CADTransformGizmoMath.handleLength, viewportSize: size, yaw: yaw, pitch: pitch, distance: distance))
            let movement = try #require(CADTransformGizmoMath.translation(axis: axis, dragStart: origin, current: endpoint, center: center, viewportSize: size, yaw: yaw, pitch: pitch, distance: distance))
            #expect(abs(movement - CADTransformGizmoMath.handleLength) < 0.001)
            let scale = try #require(CADTransformGizmoMath.scaleFactor(axis: axis, dragStart: origin, current: endpoint, center: center, viewportSize: size, yaw: yaw, pitch: pitch, distance: distance))
            #expect(abs(scale - 2) < 0.001)
            let ringStart = CADTransformGizmoMath.ringPoint(axis: axis, angle: 0.7, center: center)
            let ringScreen = try #require(CADCameraMath.project(modelPoint: ringStart, viewportSize: size, yaw: yaw, pitch: pitch, distance: distance))
            #expect(CADTransformGizmoMath.hitRotationAxis(at: ringScreen, center: center, viewportSize: size, yaw: yaw, pitch: pitch, distance: distance) == axis)
            let quarterStart = try #require(CADCameraMath.project(modelPoint: CADTransformGizmoMath.ringPoint(axis: axis, angle: 0, center: center), viewportSize: size, yaw: yaw, pitch: pitch, distance: distance))
            let quarterEnd = try #require(CADCameraMath.project(modelPoint: CADTransformGizmoMath.ringPoint(axis: axis, angle: .pi / 2, center: center), viewportSize: size, yaw: yaw, pitch: pitch, distance: distance))
            let rotation = try #require(CADTransformGizmoMath.rotationDegrees(axis: axis, dragStart: quarterStart, current: quarterEnd, center: center, viewportSize: size, yaw: yaw, pitch: pitch, distance: distance))
            #expect(abs(rotation - 90) < 0.01)
        }
        var document = CADDocument.seed
        document.features.append(CADFeature(id: "gizmo-box", name: "Gizmo", kind: "box", visible: true, params: ["width": 10, "height": 10, "depth": 10, "x": 12, "y": -4, "z": 18]))
        #expect(CADTransformGizmoMath.center(document: document, selectedFeatureId: "gizmo-box") == center)
        #expect(CADTransformGizmoMath.center(document: document, selectedFeatureId: "pad-base") == nil)
    }

    @Test func trianglePickingDoesNotSelectThroughEmptySpace() {
        let triangle = CADRenderMesh(featureId: "triangle", vertices: [
            GPUVertex(position: SIMD4(-1, -1, 0, 1), normal: SIMD4(0, 0, 1, 0), color: .one),
            GPUVertex(position: SIMD4(1, -1, 0, 1), normal: SIMD4(0, 0, 1, 0), color: .one),
            GPUVertex(position: SIMD4(0, 1, 0, 1), normal: SIMD4(0, 0, 1, 0), color: .one)
        ], faceIds: [9])
        let hit = CADHitTester.firstSurfaceHit(meshes: [triangle], origin: SIMD3(0, 0, 2), direction: SIMD3(0, 0, -1))
        #expect(hit?.featureId == "triangle")
        #expect(hit?.topologyFaceId == 9)
        #expect(CADHitTester.firstSurfaceHit(meshes: [triangle], origin: SIMD3(2, 2, 2), direction: SIMD3(0, 0, -1)) == nil)
    }

    @Test func stableTopologyEdgePickingUsesScreenToleranceAndAdjacentFace() throws {
        let edge = CADKernelTopologyEdge(id: 7, faceIds: [9, 10], positions: [-10, 0, 0, 10, 0, 0], anchor: [0, 0, 0])
        let mesh = CADRenderMesh(featureId: "edge-body", vertices: [], topologyEdges: [edge])
        let viewport = CGSize(width: 800, height: 600), yaw: Float = -0.55, pitch: Float = 0.55, distance: Float = 4.4
        let midpoint = try #require(CADCameraMath.project(modelPoint: .zero, viewportSize: viewport, yaw: yaw, pitch: pitch, distance: distance))
        let hit = try #require(CADHitTester.nearestTopologyEdge(mesh: mesh, screenPoint: CGPoint(x: midpoint.x + 3, y: midpoint.y), viewportSize: viewport, yaw: yaw, pitch: pitch, distance: distance, adjacentTo: 9))
        #expect(hit.edge.id == 7)
        #expect(hit.edge.faceIds == [9, 10])
        #expect(hit.edge.segmentCount == 1)
        #expect(hit.edge.measuredLength == 20)
        #expect(hit.edge.hasExactLinearLength)
        #expect(hit.screenDistance <= 8)
        #expect(CADHitTester.nearestTopologyEdge(mesh: mesh, screenPoint: midpoint, viewportSize: viewport, yaw: yaw, pitch: pitch, distance: distance, adjacentTo: 8) == nil)
    }

    @Test func featureVisibilityChangesKernelMeshes() {
        var hiddenPocket = CADDocument.seed
        hiddenPocket.features[2].visible = false
        let meshes = CADKernel.active.renderMeshes(document: hiddenPocket, selectedFeatureId: nil)
        #expect(meshes.first?.featureId == "pad-base")
        #expect(meshes.flatMap(\.vertices).count < CADKernel.active.renderMesh(document: .seed, selectedFeatureId: nil).count)
    }

    @Test func cameraRequestIdentityAllowsRepeatedPresetCommands() {
        let first = CADCameraRequest(id: 1, preset: .isometric)
        let repeated = CADCameraRequest(id: 2, preset: .isometric)
        #expect(first != repeated)
        #expect(first.preset == repeated.preset)
    }

    @Test func sectionPlaneProducesCorrectGPUClipEquation() {
        #expect(CADSectionPlane(axis: "x", offset: 5, flipped: false).clipEquation == SIMD4<Float>(1, 0, 0, 5))
        #expect(CADSectionPlane(axis: "x", offset: 5, flipped: true).clipEquation == SIMD4<Float>(-1, 0, 0, -5))
        #expect(CADSectionPlane(axis: "y", offset: -3, flipped: false).clipEquation == SIMD4<Float>(0, 1, 0, -3))
    }

    @Test func drawingSheetContainsOrthographicViewsAndCurrentDimensions() {
        var document = CADDocument.seed
        document.features[0].params["width"] = 104
        let sheet = CADDrawingSheet.make(document: document)
        #expect(sheet.projections.map(\.id) == ["front", "top", "right"])
        #expect(sheet.projections[0].width == 104)
        #expect(sheet.projections[0].outlines.count == 5)
        #expect(sheet.revision == document.revision)
    }

    @Test func vectorDrawingPDFHasOneNontrivialPage() throws {
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("axis-drawing-\(UUID().uuidString).pdf")
        let output = ProcessInfo.processInfo.environment["AXIS_CAD_DRAWING_FIXTURE"].map { URL(fileURLWithPath: $0) } ?? fallback
        let shouldRemove = ProcessInfo.processInfo.environment["AXIS_CAD_DRAWING_FIXTURE"] == nil
        if ProcessInfo.processInfo.environment["AXIS_CAD_DRAWING_FIXTURE"] != nil {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try DrawingPDFExporter.write(sheet: .make(document: .seed), to: output)
        let data = try Data(contentsOf: output)
        #expect(data.starts(with: Data("%PDF".utf8)))
        #expect(data.count > 4_000)
        #expect(String(decoding: data, as: UTF8.self).contains("/Type /Page"))
        if shouldRemove { try? FileManager.default.removeItem(at: output) }
    }

    @Test func drawingDXFContainsEditableOrthographicEntitiesAndMillimeterUnits() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("axis-drawing-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: output) }
        try DrawingDXFExporter.write(sheet: .make(document: .seed), to: output)
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.contains("$INSUNITS\n70\n4"))
        #expect(text.components(separatedBy: "\nCIRCLE\n").count - 1 == 4)
        #expect(text.contains("\nFRONT\n"))
        #expect(text.hasSuffix("0\nEOF\n"))
    }

    @Test func externalKernelServiceValidatesRealBRepAndReportsMeshWarning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axis-kernel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let documentURL = root.appendingPathComponent("active-document.json")
        var document = CADDocument.seed
        document.features.append(CADFeature(id: "sphere-kernel", name: "Kernel sphere", kind: "sphere", visible: true, params: ["radius": 9, "x": 30, "y": 0, "z": 14]))
        document.features.append(CADFeature(id: "cylinder-kernel", name: "Kernel cylinder", kind: "cylinder", visible: true, params: ["radius": 7, "height": 18, "x": -30, "y": 0, "z": 9]))
        document.features.append(CADFeature(id: "box-kernel", name: "Kernel box", kind: "box", visible: true, params: ["width": 10, "height": 20, "depth": 30, "x": 0, "y": 0, "z": 0]))
        try JSONEncoder().encode(document).write(to: documentURL, options: .atomic)

        let status = try await KernelService.status()
        #expect(status.available)
        #expect(status.adapter == "vcad-wasm")
        #expect(status.bundledWithApp == false)

        let validation = try await KernelService.validate(documentURL: documentURL, featureId: "pad-base")
        #expect(validation.revision == CADDocument.seed.revision)
        #expect(validation.ok)
        #expect(validation.kernelMassProperties)
        #expect(validation.canExportStep)
        #expect(validation.closedManifoldMesh)
        #expect(validation.boundaryEdgeSegments == 0)
        #expect(validation.stepRoundtrip.passed)
        #expect(validation.warnings.isEmpty)

        let sphere = try await KernelService.validate(documentURL: documentURL, featureId: "sphere-kernel")
        #expect(sphere.ok)
        #expect(sphere.closedManifoldMesh)
        #expect(sphere.canExportStep)
        #expect(sphere.stepRoundtrip.passed)
        #expect(sphere.stepRoundtrip.bodyCount == 1)
        #expect((sphere.stepRoundtrip.volumeRelativeError ?? 1) < 0.01)
        #expect(sphere.volumeWithinOnePercent == true)
        #expect((sphere.volumeRelativeError ?? 1) > 0)
        #expect((sphere.volumeRelativeError ?? 1) < 0.01)

        let sphereMesh = try await KernelService.renderMesh(documentURL: documentURL, featureId: "sphere-kernel")
        let sphereFace = try #require(sphereMesh.topologyFaces?.first)
        #expect(sphereFace.areaExact)
        #expect(sphereFace.surfaceKind == "sphere")
        #expect(sphereFace.radius == 9)
        #expect(abs(sphereFace.area - 324 * Double.pi) < 0.001)

        let cylinderMesh = try await KernelService.renderMesh(documentURL: documentURL, featureId: "cylinder-kernel")
        let cylinderEdges = try #require(cylinderMesh.topologyEdges)
        #expect(cylinderEdges.count == 2)
        #expect(cylinderEdges.allSatisfy { $0.lengthExact == true && $0.curveKind == "circle" && $0.radius == 7 })
        #expect(cylinderEdges.allSatisfy { abs($0.measuredLength - 14 * Double.pi) < 0.001 })
        let cylinderFaces = try #require(cylinderMesh.topologyFaces)
        #expect(cylinderFaces.count == 3)
        #expect(cylinderFaces.allSatisfy { $0.areaExact })
        #expect(abs(cylinderFaces.map(\.area).reduce(0, +) - 350 * Double.pi) < 0.001)

        let boxMesh = try await KernelService.renderMesh(documentURL: documentURL, featureId: "box-kernel")
        let boxEdges = try #require(boxMesh.topologyEdges)
        #expect(boxEdges.count == 12)
        #expect(boxEdges.allSatisfy { $0.positions.count == 6 && $0.faceIds.count == 2 })
        #expect(boxEdges.allSatisfy { $0.segmentCount == 1 && $0.measuredLength > 0 && $0.hasExactLinearLength })
        let boxFaces = try #require(boxMesh.topologyFaces)
        #expect(boxFaces.count == 6)
        #expect(boxFaces.allSatisfy { $0.areaExact && $0.surfaceKind == "plane" })
        #expect(abs(boxFaces.map(\.area).reduce(0, +) - 2200) < 0.001)
        document.features[document.features.count - 1].params["width"] = 16
        document.revision += 1
        try JSONEncoder().encode(document).write(to: documentURL, options: .atomic)
        let regenerated = try await KernelService.renderMesh(documentURL: documentURL, featureId: "box-kernel")
        #expect(regenerated.topologyEdges?.map(\.id) == boxEdges.map(\.id))
        #expect(regenerated.topologyEdges?.map(\.faceIds) == boxEdges.map(\.faceIds))
    }

}
