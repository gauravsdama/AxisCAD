import AppKit
import Combine
import Foundation
import simd

private let kernelDerivedFeatureKinds: Set<String> = ["extrude_feature", "pocket_feature", "revolve_feature", "sweep_feature", "loft_feature", "boolean_union", "boolean_difference", "boolean_intersection", "edge_fillet", "edge_chamfer", "shell_feature", "linear_pattern", "circular_pattern", "body_transform", "assembly_instance", "imported_step"]

enum CADCompositePathSegment {
    case line(start: SIMD3<Double>, end: SIMD3<Double>)
    case arc(start: SIMD3<Double>, mid: SIMD3<Double>, end: SIMD3<Double>)
}

enum CADSweepFrameMode: Int, CaseIterable, Identifiable {
    case minimumTwist = 0
    case curvature = 1
    case fixedUp = 2

    var id: Int { rawValue }
    var name: String {
        switch self {
        case .minimumTwist: "Minimum twist"
        case .curvature: "Follow curvature"
        case .fixedUp: "Fixed up direction"
        }
    }
}

enum CADSweepContinuityMode: Int, CaseIterable, Identifiable {
    case position = 0
    case tangent = 1
    case curvature = 2

    var id: Int { rawValue }
    var name: String { rawValue == 0 ? "Connected (G0)" : rawValue == 1 ? "Tangent (G1)" : "Curvature (G2)" }
}

struct CADSweepScaleStation: Equatable {
    var position: Double
    var scale: Double
}

struct CADSweepProfileSection: Equatable {
    var sketchId: String
    var position: Double
}

private struct ProjectSession: Codable {
    let path: String?
    let savedRevision: Int?
}

enum CADProjectError: LocalizedError {
    case noSaveDestination

    var errorDescription: String? {
        "Choose Save As once to create an Axis CAD project file."
    }
}

@MainActor
final class DocumentStore: ObservableObject {
    @Published private(set) var document: CADDocument
    @Published var selectedFeatureId: String? {
        didSet {
            if selectedSurface?.featureId != selectedFeatureId { selectedSurface = nil }
            clearanceResult = nil
            try? persistSelection()
        }
    }
    @Published private(set) var selectedSurface: CADSelectionSurface?
    @Published private(set) var sectionPlane: CADSectionPlane?
    @Published private(set) var measurementProbe: CADMeasurementProbe?
    @Published private(set) var isolatedFeatureId: String?
    @Published private(set) var explodedDistance = 0.0
    @Published private(set) var motionStudy: CADMotionStudy?
    @Published private(set) var recentDocumentPaths: [String] = []
    @Published private(set) var projectURL: URL?
    @Published private(set) var lastSavedRevision: Int?
    @Published var isMeasuring = false
    @Published var status = "Ready"
    @Published var lastError: String?
    @Published var isAIWorking = false
    @Published private(set) var kernelRenderMeshes: [CADKernelRenderMesh] = []
    @Published private(set) var isKernelRendering = false
    @Published private(set) var clearanceResult: CADKernelClearance?
    @Published private(set) var isCheckingClearance = false

    let dataDirectory: URL
    private var undoStack: [CADDocument] = []
    private var redoStack: [CADDocument] = []
    private var knownModificationDate: Date?
    private var knownViewModificationDate: Date?
    private var motionTimer: Timer?
    private var kernelRefreshTask: Task<Void, Never>?
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    var documentURL: URL { dataDirectory.appendingPathComponent("active-document.json") }
    var selectionURL: URL { dataDirectory.appendingPathComponent("active-selection.json") }
    var viewURL: URL { dataDirectory.appendingPathComponent("active-view.json") }
    var checkpointsURL: URL { dataDirectory.appendingPathComponent("checkpoints", isDirectory: true) }
    var recentsURL: URL { dataDirectory.appendingPathComponent("recent-documents.json") }
    var projectSessionURL: URL { dataDirectory.appendingPathComponent("project-session.json") }
    var hasUnsavedChanges: Bool { projectURL == nil || lastSavedRevision != document.revision }
    var selectedFeature: CADFeature? { document.features.first { $0.id == selectedFeatureId } }
    var selectedTopologyEdge: CADKernelTopologyEdge? {
        guard let surface = selectedSurface, let edgeId = surface.topologyEdgeId,
              let mesh = kernelRenderMeshes.first(where: { $0.revision == document.revision && $0.featureId == surface.featureId }) else { return nil }
        return mesh.topologyEdges?.first { $0.id == UInt32(edgeId) }
    }
    var selectedTopologyFace: CADKernelTopologyFace? {
        guard let surface = selectedSurface, let faceId = surface.topologyFaceId,
              let mesh = kernelRenderMeshes.first(where: { $0.revision == document.revision && $0.featureId == surface.featureId }) else { return nil }
        return mesh.topologyFaces?.first { $0.id == UInt32(faceId) }
    }
    var checkpointSummaries: [CADCheckpointSummary] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: checkpointsURL, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let checkpoint = try? decoder.decode(CADDocument.self, from: data) else { return nil }
            return CADCheckpointSummary(path: url.path, name: url.deletingPathExtension().lastPathComponent, revision: checkpoint.revision)
        }.sorted { $0.revision > $1.revision }
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var assemblyInstances: [CADFeature] { document.features.filter { $0.kind == "assembly_instance" } }
    var assemblyMates: [CADFeature] { document.features.filter { $0.kind == "assembly_mate" } }
    func instanceSource(_ instance: CADFeature) -> CADFeature? { instance.inputFeatureIds?.first.flatMap { id in document.features.first { $0.id == id } } }
    func materialSource(for feature: CADFeature) -> CADFeature? { feature.kind == "assembly_instance" ? instanceSource(feature) : feature }
    func material(for feature: CADFeature) -> CADMaterialPreset { CADMaterialPreset.resolve(materialSource(for: feature)) }
    var assemblyMassSummary: CADAssemblyMassSummary {
        var assigned = 0, mass = 0.0
        for instance in assemblyInstances {
            let material = material(for: instance)
            guard material != .unassigned, let mesh = kernelRenderMeshes.first(where: { $0.revision == document.revision && $0.featureId == instance.id }) else { continue }
            assigned += 1; mass += Self.meshVolume(mesh) * material.density
        }
        return CADAssemblyMassSummary(assignedInstanceCount: assigned, totalInstanceCount: assemblyInstances.count, totalMassGrams: mass)
    }
    var motionPreviewDocument: CADDocument {
        guard let study = motionStudy, let index = document.features.firstIndex(where: { $0.id == study.mateId && $0.kind == "assembly_mate" }), document.features[index].params[study.parameter] != nil else { return document }
        var preview = document; preview.features[index].params[study.parameter] = study.value; Self.solveAssemblyMates(&preview); return preview
    }
    func drivingMates(for instanceId: String) -> [CADFeature] { document.features.filter { $0.kind == "assembly_mate" && [1, 2, 3, 4, 5].contains($0.params["mate_type"] ?? -1) && $0.inputFeatureIds?.count == 2 && $0.inputFeatureIds?[1] == instanceId } }
    func positionDrivingMate(for instanceId: String) -> CADFeature? { drivingMates(for: instanceId).first { [1, 2, 3, 4].contains($0.params["mate_type"] ?? -1) } }
    func orientationDrivingMate(for instanceId: String) -> CADFeature? { drivingMates(for: instanceId).first { [3, 4, 5].contains($0.params["mate_type"] ?? -1) } }
    func drivingMate(for instanceId: String) -> CADFeature? { drivingMates(for: instanceId).first }
    func assemblyDegreesOfFreedom(for instance: CADFeature) -> Int {
        if instance.params["fixed"] == 1 { return 0 }
        let position = positionDrivingMate(for: instance.id), orientation = orientationDrivingMate(for: instance.id)
        if position?.params["mate_type"] == 3 { return 1 }
        if position?.params["mate_type"] == 4 { return 2 }
        return 6 - (position == nil ? 0 : 3) - (orientation == nil ? 0 : 2)
    }
    var assemblySourceCandidates: [CADFeature] {
        let supported = Set(["pad", "pocket", "fillet", "box", "cylinder", "cone", "sphere", "torus"]).union(kernelDerivedFeatureKinds)
        return document.features.filter { supported.contains($0.kind) && !["assembly_instance", "assembly_mate"].contains($0.kind) }
    }
    var clearanceCandidates: [CADFeature] {
        guard let selectedFeatureId else { return [] }
        let solidKinds = Set(["pad", "pocket", "fillet", "box", "cylinder", "cone", "sphere", "torus"]).union(kernelDerivedFeatureKinds)
        return document.features.filter { $0.visible && $0.id != selectedFeatureId && solidKinds.contains($0.kind) }
    }

    init(dataDirectory: URL? = nil) {
        let resolvedDirectory = dataDirectory ?? DocumentStore.defaultDataDirectory
        self.dataDirectory = resolvedDirectory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? FileManager.default.createDirectory(at: resolvedDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: resolvedDirectory.appendingPathComponent("active-document.json")),
           let decoded = try? decoder.decode(CADDocument.self, from: data) {
            document = Self.migrated(decoded)
        } else {
            document = .seed
        }
        if let data = try? Data(contentsOf: resolvedDirectory.appendingPathComponent("active-selection.json")),
           let selection = try? decoder.decode(CADSelectionState.self, from: data),
           let selected = selection.featureIds.first,
           document.features.contains(where: { $0.id == selected }) {
            selectedFeatureId = selected
            selectedSurface = selection.surface?.featureId == selected ? selection.surface : nil
        } else {
            selectedFeatureId = document.features.first?.id
            selectedSurface = nil
        }
        if let data = try? Data(contentsOf: resolvedDirectory.appendingPathComponent("active-view.json")), let view = try? decoder.decode(CADViewState.self, from: data) {
            sectionPlane = view.section
            measurementProbe = view.measurement?.revision == document.revision ? view.measurement : nil
            isolatedFeatureId = view.isolatedFeatureId.flatMap { id in document.features.contains { $0.id == id } ? id : nil }
            explodedDistance = min(200, max(0, view.explodedDistance ?? 0))
            motionStudy = Self.validMotionStudy(view.motionStudy, in: document)
        } else {
            sectionPlane = nil
            measurementProbe = nil
            isolatedFeatureId = nil
            explodedDistance = 0
            motionStudy = nil
        }
        if let data = try? Data(contentsOf: recentsURL), let paths = try? decoder.decode([String].self, from: data) { recentDocumentPaths = paths.filter { FileManager.default.fileExists(atPath: $0) } }
        if let data = try? Data(contentsOf: projectSessionURL),
           let session = try? decoder.decode(ProjectSession.self, from: data),
           let path = session.path, FileManager.default.fileExists(atPath: path) {
            projectURL = URL(fileURLWithPath: path)
            lastSavedRevision = session.savedRevision
        }
        try? persist()
        try? persistSelection()
        try? persistView()
        syncMotionTimer()
    }

    static var defaultDataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AXIS_CAD_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AxisCAD", isDirectory: true)
    }

    func selectSurface(_ hit: CADSurfaceHit?) {
        selectedFeatureId = hit?.featureId
        selectedSurface = hit.map {
            CADSelectionSurface(featureId: $0.featureId, triangleIndex: $0.triangleIndex,
                position: CADSelectionVector(x: $0.position.x, y: $0.position.y, z: $0.position.z),
                normal: CADSelectionVector(x: $0.normal.x, y: $0.normal.y, z: $0.normal.z),
                topologyFaceId: $0.topologyFaceId, topologyEdgeId: $0.topologyEdgeId,
                topologyEdgeFaceIds: $0.topologyEdgeFaceIds)
        }
        try? persistSelection()
    }

    func setSection(axis: String, offset: Double = 0, flipped: Bool = false) {
        guard ["x", "y", "z"].contains(axis), offset.isFinite else { return }
        sectionPlane = CADSectionPlane(axis: axis, offset: offset, flipped: flipped)
        try? persistView(); status = "Section \(axis.uppercased()) at \(offset.formatted(.number.precision(.fractionLength(0...2)))) \(document.units)"
    }

    func clearSection() {
        sectionPlane = nil; try? persistView(); status = "Section view cleared"
    }

    func setExplodedDistance(_ distance: Double) {
        guard distance.isFinite else { return }
        explodedDistance = min(200, max(0, distance))
        measurementProbe = nil; isMeasuring = false
        try? persistView()
        status = explodedDistance > 0 ? "Exploded assembly view · \(explodedDistance.formatted(.number.precision(.fractionLength(0...1)))) mm" : "Assembly view collapsed"
    }

    func motionParameters(for mate: CADFeature) -> [String] {
        let allowed = ["angle", "distance", "axial_offset", "spin", "offset_x", "offset_y", "offset_z"]
        return allowed.filter { mate.params[$0] != nil }
    }

    func configureMotionStudy(mateId: String, parameter: String? = nil, minimum: Double? = nil, maximum: Double? = nil, progress: Double = 0, playing: Bool = false) throws {
        guard let mate = document.features.first(where: { $0.id == mateId && $0.kind == "assembly_mate" }), mate.params["mate_type"] != 0 else { throw CADValidationError.invalidFeature(mateId) }
        let parameters = motionParameters(for: mate), resolvedParameter = parameter ?? parameters.first
        guard let resolvedParameter, parameters.contains(resolvedParameter) else { throw CADValidationError.invalidParameter(parameter ?? "motion") }
        let defaults = Self.defaultMotionRange(parameter: resolvedParameter, mate: mate)
        let study = CADMotionStudy(mateId: mateId, parameter: resolvedParameter, minimum: minimum ?? defaults.0, maximum: maximum ?? defaults.1, progress: progress, playing: playing)
        guard let valid = Self.validMotionStudy(study, in: document) else { throw CADValidationError.invalidValue }
        motionStudy = valid; measurementProbe = nil; isMeasuring = false; try? persistView(); syncMotionTimer()
        status = "Motion preview · \(mate.name).\(resolvedParameter)"
    }

    func setMotionProgress(_ progress: Double) {
        guard var study = motionStudy, progress.isFinite else { return }
        study.progress = min(1, max(0, progress)); study.playing = false; motionStudy = study; try? persistView()
    }

    func setMotionRange(minimum: Double, maximum: Double) {
        guard let study = motionStudy else { return }
        try? configureMotionStudy(mateId: study.mateId, parameter: study.parameter, minimum: minimum, maximum: maximum, progress: study.progress, playing: false)
    }

    func setMotionParameter(_ parameter: String) {
        guard let study = motionStudy else { return }
        try? configureMotionStudy(mateId: study.mateId, parameter: parameter, progress: study.progress, playing: false)
    }

    func toggleMotionPlayback() {
        guard var study = motionStudy else { return }
        study.playing.toggle(); motionStudy = study; try? persistView(); syncMotionTimer(); status = study.playing ? "Motion preview playing" : "Motion preview paused"
    }

    func advanceMotion() {
        guard var study = motionStudy, study.playing else { return }
        study.progress = (study.progress + 1.0 / 180.0).truncatingRemainder(dividingBy: 1)
        motionStudy = study
    }

    func clearMotionStudy() {
        motionStudy = nil; try? persistView(); syncMotionTimer(); status = "Motion preview closed"
    }

    func setIsolatedFeature(_ featureId: String?) {
        guard featureId == nil || document.features.contains(where: { $0.id == featureId }) else { return }
        isolatedFeatureId = featureId
        if let featureId { selectedFeatureId = featureId; status = "Isolated \(document.features.first { $0.id == featureId }?.name ?? featureId)" }
        else { status = "Showing all visible bodies" }
        try? persistView()
    }

    func toggleMeasurementMode() {
        isMeasuring.toggle()
        if isMeasuring {
            measurementProbe = nil
            try? persistView()
            status = "Measure: click the first point"
        } else {
            status = "Measure tool closed"
        }
    }

    func addMeasurementPoint(_ hit: CADSurfaceHit?) {
        guard isMeasuring, let hit else {
            status = "Measure: click a rendered surface"
            return
        }
        let point = CADSelectionVector(x: hit.position.x, y: hit.position.y, z: hit.position.z)
        if measurementProbe == nil || measurementProbe?.end != nil {
            measurementProbe = CADMeasurementProbe(revision: document.revision, start: point, end: nil)
            status = "Measure: click the second point"
        } else {
            measurementProbe?.end = point
            if let distance = measurementProbe?.distance {
                status = "Measured \(distance.formatted(.number.precision(.fractionLength(0...3)))) \(document.units)"
            }
        }
        try? persistView()
    }

    func setMeasurement(start: CADSelectionVector, end: CADSelectionVector) {
        measurementProbe = CADMeasurementProbe(revision: document.revision, start: start, end: end)
        isMeasuring = false
        try? persistView()
        status = "Measured \((measurementProbe?.distance ?? 0).formatted(.number.precision(.fractionLength(0...3)))) \(document.units)"
    }

    func clearMeasurement() {
        measurementProbe = nil
        isMeasuring = false
        try? persistView()
        status = "Measurement cleared"
    }

    func setParameter(featureId: String, key: String, value: Double, author: String = "you", expectedRevision: Int? = nil) throws {
        if let expectedRevision, expectedRevision != document.revision {
            throw CADValidationError.revisionConflict(expected: expectedRevision, actual: document.revision)
        }
        guard isValidParameter(key: key, value: value) else { throw CADValidationError.invalidValue }
        if ["symmetric", "closed"].contains(key), value != 0 && value != 1 { throw CADValidationError.invalidValue }
        guard let index = document.features.firstIndex(where: { $0.id == featureId }) else { throw CADValidationError.invalidFeature(featureId) }
        guard let previous = document.features[index].params[key] else { throw CADValidationError.invalidParameter(key) }
        guard previous != value else { return }
        if document.features[index].kind == "assembly_instance" {
            if key == "fixed" { throw CADValidationError.invalidParameter(key) }
            let poseKeys = Set(["x", "y", "z", "rotation_x", "rotation_y", "rotation_z", "scale_x", "scale_y", "scale_z"])
            if poseKeys.contains(key), document.features[index].params["fixed"] == 1 { throw CADValidationError.invalidValue }
            if ["x", "y", "z"].contains(key), Self.isMateDriven(document, instanceId: featureId) { throw CADValidationError.invalidValue }
            if key.hasPrefix("rotation_"), Self.drivingOrientationMate(document, instanceId: featureId) != nil { throw CADValidationError.invalidValue }
        }
        if document.features[index].kind == "assembly_mate" {
            var params = document.features[index].params; params[key] = value
            let type = params["mate_type"] ?? -1
            if type == 2 {
                let axis = SIMD3(params["axis_x"] ?? 0, params["axis_y"] ?? 0, params["axis_z"] ?? 0)
                guard (params["distance"] ?? 0) > 0, simd_length(axis) > 0.000_001 else { throw CADValidationError.invalidValue }
            } else if type == 3 {
                let referenceNormal = SIMD3(params["reference_normal_x"] ?? 0, params["reference_normal_y"] ?? 0, params["reference_normal_z"] ?? 0)
                let movingNormal = SIMD3(params["moving_normal_x"] ?? 0, params["moving_normal_y"] ?? 0, params["moving_normal_z"] ?? 0)
                guard (params["distance"] ?? -1) >= 0, [0, 1].contains(params["opposed"] ?? -1), (params["spin"] ?? .nan).isFinite, simd_length(referenceNormal) > 0.000_001, simd_length(movingNormal) > 0.000_001 else { throw CADValidationError.invalidValue }
            } else if type == 4 {
                let referenceAxis = SIMD3(params["reference_axis_x"] ?? 0, params["reference_axis_y"] ?? 0, params["reference_axis_z"] ?? 0)
                let movingAxis = SIMD3(params["moving_axis_x"] ?? 0, params["moving_axis_y"] ?? 0, params["moving_axis_z"] ?? 0)
                guard (params["axial_offset"] ?? .nan).isFinite, [0, 1].contains(params["opposed"] ?? -1), (params["spin"] ?? .nan).isFinite, simd_length(referenceAxis) > 0.000_001, simd_length(movingAxis) > 0.000_001 else { throw CADValidationError.invalidValue }
            } else if type == 5 {
                let referenceNormal = SIMD3(params["reference_normal_x"] ?? 0, params["reference_normal_y"] ?? 0, params["reference_normal_z"] ?? 0)
                let movingNormal = SIMD3(params["moving_normal_x"] ?? 0, params["moving_normal_y"] ?? 0, params["moving_normal_z"] ?? 0)
                let hingeAxis = SIMD3(params["hinge_axis_x"] ?? 0, params["hinge_axis_y"] ?? 0, params["hinge_axis_z"] ?? 0)
                guard (params["angle"] ?? -1) >= 0, (params["angle"] ?? 181) <= 180, (params["spin"] ?? .nan).isFinite, simd_length(referenceNormal) > 0.000_001, simd_length(movingNormal) > 0.000_001, simd_length(hingeAxis) > 0.000_001, simd_length(simd_cross(referenceNormal, hingeAxis)) > 0.000_001 else { throw CADValidationError.invalidValue }
            } else if ![0, 1].contains(type) { throw CADValidationError.invalidValue }
        }
        if document.features[index].kind == "torus" {
            let major = key == "major_radius" ? value : document.features[index].params["major_radius"] ?? 0
            let tube = key == "tube_radius" ? value : document.features[index].params["tube_radius"] ?? 0
            guard major > tube else { throw CADValidationError.invalidValue }
        }
        if document.features[index].kind == "revolve_feature" {
            if key == "angle", !(value > 0 && value <= 360) { throw CADValidationError.invalidValue }
            let axisX = key == "axis_x" ? value : document.features[index].params["axis_x"] ?? 0
            let axisY = key == "axis_y" ? value : document.features[index].params["axis_y"] ?? 0
            let axisZ = key == "axis_z" ? value : document.features[index].params["axis_z"] ?? 0
            if sqrt(axisX * axisX + axisY * axisY + axisZ * axisZ) < 0.000_001 { throw CADValidationError.invalidValue }
        }
        if document.features[index].kind == "sweep_feature", document.features[index].params["helix_radius"] == nil, document.features[index].params["path_point_count"] == nil, document.features[index].params["path_segment_count"] == nil {
            let startX = key == "start_x" ? value : document.features[index].params["start_x"] ?? 0
            let startY = key == "start_y" ? value : document.features[index].params["start_y"] ?? 0
            let startZ = key == "start_z" ? value : document.features[index].params["start_z"] ?? 0
            let endX = key == "end_x" ? value : document.features[index].params["end_x"] ?? 0
            let endY = key == "end_y" ? value : document.features[index].params["end_y"] ?? 0
            let endZ = key == "end_z" ? value : document.features[index].params["end_z"] ?? 0
            if sqrt(pow(endX - startX, 2) + pow(endY - startY, 2) + pow(endZ - startZ, 2)) < 0.000_001 { throw CADValidationError.invalidValue }
        }
        if document.features[index].kind == "sweep_feature", key == "guide_point_count" { throw CADValidationError.invalidParameter(key) }
        if document.features[index].kind == "sweep_feature", key == "frame_mode" || key.hasPrefix("up_") || key.hasPrefix("guide_") {
            var params = document.features[index].params; params[key] = value
            if Self.sweepOrientationError(params) != nil { throw CADValidationError.invalidValue }
        }
        if document.features[index].kind == "sweep_feature", key == "tangent_mode" || key.contains("_tangent_") || key == "continuity_mode" || key == "tangent_tolerance" {
            var params = document.features[index].params; params[key] = value
            if Self.sweepPathControlError(params) != nil { throw CADValidationError.invalidValue }
            if params["path_segment_count"] != nil, Self.compositePathError(params) != nil { throw CADValidationError.invalidValue }
        }
        if document.features[index].kind == "sweep_feature", let pointCountValue = document.features[index].params["path_point_count"] {
            if key == "path_point_count" { throw CADValidationError.invalidParameter(key) }
            if key.hasPrefix("path_") {
                var params = document.features[index].params; params[key] = value
                let pointCount = Int(pointCountValue.rounded())
                let points = (0..<pointCount).map { pointIndex in
                    SIMD3(params["path_\(pointIndex)_x"] ?? .nan, params["path_\(pointIndex)_y"] ?? .nan, params["path_\(pointIndex)_z"] ?? .nan)
                }
                guard points.flatMap({ [$0.x, $0.y, $0.z] }).allSatisfy(\.isFinite),
                      zip(points, points.dropFirst()).contains(where: { simd_distance($0, $1) > 0.000_001 }) else { throw CADValidationError.invalidValue }
            }
        }
        if document.features[index].kind == "sweep_feature", document.features[index].params["path_segment_count"] != nil {
            if key == "path_segment_count" || key.range(of: #"^path_\d+_kind$"#, options: .regularExpression) != nil { throw CADValidationError.invalidParameter(key) }
            if key.hasPrefix("path_") {
                var params = document.features[index].params; Self.setCompositePathParameter(&params, key: key, value: value)
                if Self.compositePathError(params) != nil { throw CADValidationError.invalidValue }
            }
        }
        if document.features[index].kind == "sweep_feature", document.features[index].params["scale_station_count"] != nil {
            if key == "scale_station_count" { throw CADValidationError.invalidParameter(key) }
            if key.hasPrefix("scale_station_") {
                var params = document.features[index].params; params[key] = value
                if Self.sweepScaleStationError(params) != nil { throw CADValidationError.invalidValue }
            }
        }
        if document.features[index].kind == "sweep_feature", document.features[index].params["profile_station_count"] != nil {
            if key == "profile_station_count" { throw CADValidationError.invalidParameter(key) }
            if key.hasPrefix("profile_station_") {
                var params = document.features[index].params; params[key] = value
                if Self.sweepProfileStationError(params) != nil { throw CADValidationError.invalidValue }
            }
        }

        beginMutation()
        document.revision += 1
        if document.features[index].params["path_segment_count"] != nil {
            Self.setCompositePathParameter(&document.features[index].params, key: key, value: value)
        } else {
            document.features[index].params[key] = value
        }
        document.operations.insert(CADOperation(
            operationId: "op-\(document.revision)", author: author, kind: "set_parameter",
            featureId: featureId, parameter: key, previousValue: previous, value: value,
            revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())
        ), at: 0)
        try persist()
        status = "Updated \(document.features[index].name).\(key) to \(format(value)) \(document.units)"
    }

    func setTransform(featureId: String, x: Double, y: Double, z: Double, author: String = "you", expectedRevision: Int? = nil) throws {
        if let expectedRevision, expectedRevision != document.revision {
            throw CADValidationError.revisionConflict(expected: expectedRevision, actual: document.revision)
        }
        guard [x, y, z].allSatisfy(\.isFinite) else { throw CADValidationError.invalidValue }
        guard let index = document.features.firstIndex(where: { $0.id == featureId }) else { throw CADValidationError.invalidFeature(featureId) }
        if kernelDerivedFeatureKinds.contains(document.features[index].kind), !["body_transform", "assembly_instance"].contains(document.features[index].kind) {
            try createBodyTransform(inputFeatureId: featureId, x: x, y: y, z: z, author: author)
            return
        }
        guard ["box", "cylinder", "cone", "sphere", "torus", "body_transform", "assembly_instance"].contains(document.features[index].kind),
              document.features[index].params["x"] != nil,
              document.features[index].params["y"] != nil,
              document.features[index].params["z"] != nil else { throw CADValidationError.invalidParameter("x/y/z") }
        if document.features[index].kind == "assembly_instance", document.features[index].params["fixed"] == 1 || Self.isMateDriven(document, instanceId: featureId) { throw CADValidationError.invalidValue }
        let previous = SIMD3(document.features[index].params["x"] ?? 0, document.features[index].params["y"] ?? 0, document.features[index].params["z"] ?? 0)
        let next = SIMD3(x, y, z)
        guard previous != next else { return }

        beginMutation()
        document.revision += 1
        document.features[index].params["x"] = x
        document.features[index].params["y"] = y
        document.features[index].params["z"] = z
        document.operations.insert(CADOperation(
            operationId: "op-\(document.revision)", author: author, kind: "transform_feature",
            featureId: featureId, parameter: "position", previousValue: nil, value: nil,
            revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())
        ), at: 0)
        try persist()
        status = "Moved \(document.features[index].name) to (\(format(x)), \(format(y)), \(format(z))) \(document.units)"
    }

    func setRotation(featureId: String, x: Double, y: Double, z: Double, author: String = "you", expectedRevision: Int? = nil) throws {
        if let expectedRevision, expectedRevision != document.revision {
            throw CADValidationError.revisionConflict(expected: expectedRevision, actual: document.revision)
        }
        guard [x, y, z].allSatisfy(\.isFinite) else { throw CADValidationError.invalidValue }
        guard let index = document.features.firstIndex(where: { $0.id == featureId }) else { throw CADValidationError.invalidFeature(featureId) }
        if kernelDerivedFeatureKinds.contains(document.features[index].kind), !["body_transform", "assembly_instance"].contains(document.features[index].kind) {
            try createBodyTransform(inputFeatureId: featureId, rotationX: x, rotationY: y, rotationZ: z, author: author)
            return
        }
        guard ["box", "cylinder", "cone", "sphere", "torus", "body_transform", "assembly_instance"].contains(document.features[index].kind),
              document.features[index].params["rotation_x"] != nil,
              document.features[index].params["rotation_y"] != nil,
              document.features[index].params["rotation_z"] != nil else { throw CADValidationError.invalidParameter("rotation_x/y/z") }
        if document.features[index].kind == "assembly_instance", document.features[index].params["fixed"] == 1 || Self.drivingOrientationMate(document, instanceId: featureId) != nil { throw CADValidationError.invalidValue }
        let previous = SIMD3(document.features[index].params["rotation_x"] ?? 0, document.features[index].params["rotation_y"] ?? 0, document.features[index].params["rotation_z"] ?? 0)
        let next = SIMD3(x, y, z)
        guard previous != next else { return }

        beginMutation()
        document.revision += 1
        document.features[index].params["rotation_x"] = x
        document.features[index].params["rotation_y"] = y
        document.features[index].params["rotation_z"] = z
        document.operations.insert(CADOperation(
            operationId: "op-\(document.revision)", author: author, kind: "rotate_feature",
            featureId: featureId, parameter: "rotation", previousValue: nil, value: nil,
            revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())
        ), at: 0)
        try persist()
        status = "Rotated \(document.features[index].name) to (\(format(x))°, \(format(y))°, \(format(z))°)"
    }

    func setScale(featureId: String, x: Double, y: Double, z: Double, author: String = "you", expectedRevision: Int? = nil) throws {
        if let expectedRevision, expectedRevision != document.revision {
            throw CADValidationError.revisionConflict(expected: expectedRevision, actual: document.revision)
        }
        guard [x, y, z].allSatisfy({ $0.isFinite && $0 > 0 }),
              let index = document.features.firstIndex(where: { $0.id == featureId }) else { throw CADValidationError.invalidValue }
        if !["body_transform", "assembly_instance"].contains(document.features[index].kind) {
            guard CADTransformGizmoMath.transformableKinds.contains(document.features[index].kind) else { throw CADValidationError.invalidValue }
            try createBodyTransform(inputFeatureId: featureId, scaleX: x, scaleY: y, scaleZ: z, author: author)
            return
        }
        if document.features[index].kind == "assembly_instance", document.features[index].params["fixed"] == 1 { throw CADValidationError.invalidValue }
        let previous = SIMD3(document.features[index].params["scale_x"] ?? 1, document.features[index].params["scale_y"] ?? 1, document.features[index].params["scale_z"] ?? 1)
        let next = SIMD3(x, y, z)
        guard previous != next else { return }

        beginMutation()
        document.revision += 1
        document.features[index].params["scale_x"] = x
        document.features[index].params["scale_y"] = y
        document.features[index].params["scale_z"] = z
        document.operations.insert(CADOperation(
            operationId: "op-\(document.revision)", author: author, kind: "scale_feature",
            featureId: featureId, parameter: "scale", previousValue: nil, value: nil,
            revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())
        ), at: 0)
        try persist()
        status = "Scaled \(document.features[index].name) to (\(format(x))×, \(format(y))×, \(format(z))×)"
    }

    func createBodyTransform(inputFeatureId: String, x: Double = 0, y: Double = 0, z: Double = 0, rotationX: Double = 0, rotationY: Double = 0, rotationZ: Double = 0, scaleX: Double = 1, scaleY: Double = 1, scaleZ: Double = 1, author: String = "you") throws {
        guard [x, y, z, rotationX, rotationY, rotationZ, scaleX, scaleY, scaleZ].allSatisfy(\.isFinite),
              [scaleX, scaleY, scaleZ].allSatisfy({ $0 > 0 }),
              let inputIndex = document.features.firstIndex(where: { $0.id == inputFeatureId }),
              CADTransformGizmoMath.transformableKinds.contains(document.features[inputIndex].kind),
              document.features[inputIndex].kind != "body_transform" else { throw CADValidationError.invalidValue }
        let input = document.features[inputIndex]
        beginMutation(); document.revision += 1
        var suffix = 1
        while document.features.contains(where: { $0.id == "body-transform-\(suffix)" }) { suffix += 1 }
        document.features[inputIndex].visible = false
        let feature = CADFeature(id: "body-transform-\(suffix)", name: "Move body \(suffix)", kind: "body_transform", visible: true,
            params: ["x": x, "y": y, "z": z, "rotation_x": rotationX, "rotation_y": rotationY, "rotation_z": rotationZ, "scale_x": scaleX, "scale_y": scaleY, "scale_z": scaleZ], inputFeatureIds: [inputFeatureId])
        document.features.append(feature)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: author, kind: "create_body_transform", featureId: feature.id, parameter: "pose", previousValue: nil, value: nil, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = feature.id
        try persist()
        status = "Created \(feature.name) from \(input.name) · kernel rebuild started"
    }

    func createAssemblyInstance(sourceFeatureId: String, name: String? = nil, position: SIMD3<Double> = .zero, rotation: SIMD3<Double> = .zero, scale: SIMD3<Double> = SIMD3(repeating: 1), author: String = "you") throws {
        let supported = Set(["pad", "pocket", "fillet", "box", "cylinder", "cone", "sphere", "torus"]).union(kernelDerivedFeatureKinds)
        guard [position.x, position.y, position.z, rotation.x, rotation.y, rotation.z, scale.x, scale.y, scale.z].allSatisfy(\.isFinite), [scale.x, scale.y, scale.z].allSatisfy({ $0 > 0 }),
              let sourceIndex = document.features.firstIndex(where: { $0.id == sourceFeatureId }), supported.contains(document.features[sourceIndex].kind), !["assembly_instance", "assembly_mate"].contains(document.features[sourceIndex].kind) else { throw CADValidationError.invalidValue }
        let source = document.features[sourceIndex]
        beginMutation(); document.revision += 1
        var suffix = 1; while document.features.contains(where: { $0.id == "instance-\(suffix)" }) { suffix += 1 }
        document.features[sourceIndex].visible = false
        let feature = CADFeature(id: "instance-\(suffix)", name: name ?? "\(source.name) · \(suffix)", kind: "assembly_instance", visible: true,
            params: ["x": position.x, "y": position.y, "z": position.z, "rotation_x": rotation.x, "rotation_y": rotation.y, "rotation_z": rotation.z, "scale_x": scale.x, "scale_y": scale.y, "scale_z": scale.z, "fixed": 0], inputFeatureIds: [sourceFeatureId])
        document.features.append(feature)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: author, kind: "create_instance", featureId: feature.id, parameter: "pose", previousValue: nil, value: nil, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = feature.id
        try persist(); status = "Created assembly instance \(feature.name) · kernel rebuild started"
    }

    func setMaterial(featureId: String, preset: CADMaterialPreset, author: String = "you") throws {
        guard let selected = document.features.first(where: { $0.id == featureId }), let source = materialSource(for: selected),
              assemblySourceCandidates.contains(where: { $0.id == source.id }),
              let index = document.features.firstIndex(where: { $0.id == source.id }) else { throw CADValidationError.invalidFeature(featureId) }
        let previous = document.features[index].params["material_id"] ?? 0
        guard previous != Double(preset.rawValue) else { return }
        beginMutation(); document.revision += 1
        if preset == .unassigned {
            for key in ["material_id", "density", "color_r", "color_g", "color_b"] { document.features[index].params.removeValue(forKey: key) }
        } else {
            document.features[index].params["material_id"] = Double(preset.rawValue)
            document.features[index].params["density"] = preset.density
            document.features[index].params["color_r"] = Double(preset.color.x); document.features[index].params["color_g"] = Double(preset.color.y); document.features[index].params["color_b"] = Double(preset.color.z)
        }
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: author, kind: "set_material", featureId: source.id, parameter: "material_id", previousValue: previous, value: Double(preset.rawValue), revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        try persist(); status = preset == .unassigned ? "Cleared material for \(source.name)" : "Assigned \(preset.name) to \(source.name)"
    }

    func createFixedMate(instanceId: String, author: String = "you") throws {
        guard let instance = document.features.first(where: { $0.id == instanceId && $0.kind == "assembly_instance" }), instance.params["fixed"] != 1,
              drivingMates(for: instanceId).isEmpty,
              !document.features.contains(where: { $0.kind == "assembly_mate" && $0.params["mate_type"] == 0 && $0.inputFeatureIds?.first == instanceId }) else { throw CADValidationError.invalidValue }
        beginMutation(); document.revision += 1
        var suffix = 1; while document.features.contains(where: { $0.id == "mate-fixed-\(suffix)" }) { suffix += 1 }
        let mate = CADFeature(id: "mate-fixed-\(suffix)", name: "Fix \(instance.name)", kind: "assembly_mate", visible: true, params: ["mate_type": 0], inputFeatureIds: [instanceId])
        document.features.append(mate)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: author, kind: "create_fixed_mate", featureId: mate.id, parameter: nil, previousValue: nil, value: nil, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = mate.id
        try persist(); status = "Grounded \(instance.name) · 0 rigid-body DOF"
    }

    func createCoincidentMate(referenceInstanceId: String, movingInstanceId: String, referenceAnchor: SIMD3<Double> = .zero, movingAnchor: SIMD3<Double> = .zero, offset: SIMD3<Double> = .zero, author: String = "you") throws {
        guard referenceInstanceId != movingInstanceId,
              let reference = document.features.first(where: { $0.id == referenceInstanceId && $0.kind == "assembly_instance" }),
              let moving = document.features.first(where: { $0.id == movingInstanceId && $0.kind == "assembly_instance" }), moving.params["fixed"] != 1,
              !Self.isMateDriven(document, instanceId: movingInstanceId),
              [referenceAnchor.x, referenceAnchor.y, referenceAnchor.z, movingAnchor.x, movingAnchor.y, movingAnchor.z, offset.x, offset.y, offset.z].allSatisfy(\.isFinite),
              !Self.assemblyMatePathExists(document, from: movingInstanceId, to: referenceInstanceId) else { throw CADValidationError.invalidValue }
        beginMutation(); document.revision += 1
        var suffix = 1; while document.features.contains(where: { $0.id == "mate-coincident-\(suffix)" }) { suffix += 1 }
        let mate = CADFeature(id: "mate-coincident-\(suffix)", name: "Mate \(moving.name) to \(reference.name)", kind: "assembly_mate", visible: true,
            params: ["mate_type": 1, "reference_anchor_x": referenceAnchor.x, "reference_anchor_y": referenceAnchor.y, "reference_anchor_z": referenceAnchor.z, "moving_anchor_x": movingAnchor.x, "moving_anchor_y": movingAnchor.y, "moving_anchor_z": movingAnchor.z, "offset_x": offset.x, "offset_y": offset.y, "offset_z": offset.z], inputFeatureIds: [referenceInstanceId, movingInstanceId])
        document.features.append(mate)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: author, kind: "create_coincident_mate", featureId: mate.id, parameter: "offset", previousValue: nil, value: nil, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = mate.id
        try persist(); status = "Mated \(moving.name) to \(reference.name) · 3 rotational DOF remain"
    }

    func createDistanceMate(referenceInstanceId: String, movingInstanceId: String, referenceAnchor: SIMD3<Double> = .zero, movingAnchor: SIMD3<Double> = .zero, axis: SIMD3<Double> = SIMD3(1, 0, 0), distance: Double = 10, author: String = "you") throws {
        guard referenceInstanceId != movingInstanceId,
              let reference = document.features.first(where: { $0.id == referenceInstanceId && $0.kind == "assembly_instance" }),
              let moving = document.features.first(where: { $0.id == movingInstanceId && $0.kind == "assembly_instance" }), moving.params["fixed"] != 1,
              !Self.isMateDriven(document, instanceId: movingInstanceId),
              [referenceAnchor.x, referenceAnchor.y, referenceAnchor.z, movingAnchor.x, movingAnchor.y, movingAnchor.z, axis.x, axis.y, axis.z, distance].allSatisfy(\.isFinite),
              simd_length(axis) > 0.000_001, distance > 0,
              !Self.assemblyMatePathExists(document, from: movingInstanceId, to: referenceInstanceId) else { throw CADValidationError.invalidValue }
        beginMutation(); document.revision += 1
        var suffix = 1; while document.features.contains(where: { $0.id == "mate-distance-\(suffix)" }) { suffix += 1 }
        let mate = CADFeature(id: "mate-distance-\(suffix)", name: "Space \(moving.name) from \(reference.name)", kind: "assembly_mate", visible: true,
            params: ["mate_type": 2, "reference_anchor_x": referenceAnchor.x, "reference_anchor_y": referenceAnchor.y, "reference_anchor_z": referenceAnchor.z, "moving_anchor_x": movingAnchor.x, "moving_anchor_y": movingAnchor.y, "moving_anchor_z": movingAnchor.z, "axis_x": axis.x, "axis_y": axis.y, "axis_z": axis.z, "distance": distance], inputFeatureIds: [referenceInstanceId, movingInstanceId])
        document.features.append(mate)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: author, kind: "create_distance_mate", featureId: mate.id, parameter: "distance", previousValue: nil, value: distance, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = mate.id
        try persist(); status = "Spaced \(moving.name) \(format(distance)) \(document.units) from \(reference.name) · 3 rotational DOF remain"
    }

    func createPlaneMate(referenceInstanceId: String, movingInstanceId: String, referenceAnchor: SIMD3<Double> = .zero, movingAnchor: SIMD3<Double> = .zero, referenceNormal: SIMD3<Double> = SIMD3(0, 0, 1), movingNormal: SIMD3<Double> = SIMD3(0, 0, 1), distance: Double = 0, opposed: Bool = false, spin: Double = 0, author: String = "you") throws {
        guard referenceInstanceId != movingInstanceId,
              let reference = document.features.first(where: { $0.id == referenceInstanceId && $0.kind == "assembly_instance" }),
              let moving = document.features.first(where: { $0.id == movingInstanceId && $0.kind == "assembly_instance" }), moving.params["fixed"] != 1,
              !Self.isMateDriven(document, instanceId: movingInstanceId),
              Self.drivingOrientationMate(document, instanceId: movingInstanceId) == nil,
              [referenceAnchor.x, referenceAnchor.y, referenceAnchor.z, movingAnchor.x, movingAnchor.y, movingAnchor.z, referenceNormal.x, referenceNormal.y, referenceNormal.z, movingNormal.x, movingNormal.y, movingNormal.z, distance, spin].allSatisfy(\.isFinite),
              simd_length(referenceNormal) > 0.000_001, simd_length(movingNormal) > 0.000_001, distance >= 0,
              !Self.assemblyMatePathExists(document, from: movingInstanceId, to: referenceInstanceId) else { throw CADValidationError.invalidValue }
        beginMutation(); document.revision += 1
        var suffix = 1; while document.features.contains(where: { $0.id == "mate-plane-\(suffix)" }) { suffix += 1 }
        let mate = CADFeature(id: "mate-plane-\(suffix)", name: "Plane mate \(moving.name) to \(reference.name)", kind: "assembly_mate", visible: true,
            params: ["mate_type": 3, "reference_anchor_x": referenceAnchor.x, "reference_anchor_y": referenceAnchor.y, "reference_anchor_z": referenceAnchor.z, "moving_anchor_x": movingAnchor.x, "moving_anchor_y": movingAnchor.y, "moving_anchor_z": movingAnchor.z, "reference_normal_x": referenceNormal.x, "reference_normal_y": referenceNormal.y, "reference_normal_z": referenceNormal.z, "moving_normal_x": movingNormal.x, "moving_normal_y": movingNormal.y, "moving_normal_z": movingNormal.z, "distance": distance, "opposed": opposed ? 1 : 0, "spin": spin], inputFeatureIds: [referenceInstanceId, movingInstanceId])
        document.features.append(mate)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: author, kind: "create_plane_mate", featureId: mate.id, parameter: "distance", previousValue: nil, value: distance, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = mate.id
        try persist(); status = "Aligned \(moving.name) plane to \(reference.name) · 1 spin DOF remains"
    }

    func createConcentricMate(referenceInstanceId: String, movingInstanceId: String, referenceAnchor: SIMD3<Double> = .zero, movingAnchor: SIMD3<Double> = .zero, referenceAxis: SIMD3<Double> = SIMD3(0, 0, 1), movingAxis: SIMD3<Double> = SIMD3(0, 0, 1), axialOffset: Double = 0, opposed: Bool = false, spin: Double = 0, author: String = "you") throws {
        guard referenceInstanceId != movingInstanceId,
              let reference = document.features.first(where: { $0.id == referenceInstanceId && $0.kind == "assembly_instance" }),
              let moving = document.features.first(where: { $0.id == movingInstanceId && $0.kind == "assembly_instance" }), moving.params["fixed"] != 1,
              !Self.isMateDriven(document, instanceId: movingInstanceId),
              Self.drivingOrientationMate(document, instanceId: movingInstanceId) == nil,
              [referenceAnchor.x, referenceAnchor.y, referenceAnchor.z, movingAnchor.x, movingAnchor.y, movingAnchor.z, referenceAxis.x, referenceAxis.y, referenceAxis.z, movingAxis.x, movingAxis.y, movingAxis.z, axialOffset, spin].allSatisfy(\.isFinite),
              simd_length(referenceAxis) > 0.000_001, simd_length(movingAxis) > 0.000_001,
              !Self.assemblyMatePathExists(document, from: movingInstanceId, to: referenceInstanceId) else { throw CADValidationError.invalidValue }
        beginMutation(); document.revision += 1
        var suffix = 1; while document.features.contains(where: { $0.id == "mate-concentric-\(suffix)" }) { suffix += 1 }
        let mate = CADFeature(id: "mate-concentric-\(suffix)", name: "Concentric \(moving.name) to \(reference.name)", kind: "assembly_mate", visible: true,
            params: ["mate_type": 4, "reference_anchor_x": referenceAnchor.x, "reference_anchor_y": referenceAnchor.y, "reference_anchor_z": referenceAnchor.z, "moving_anchor_x": movingAnchor.x, "moving_anchor_y": movingAnchor.y, "moving_anchor_z": movingAnchor.z, "reference_axis_x": referenceAxis.x, "reference_axis_y": referenceAxis.y, "reference_axis_z": referenceAxis.z, "moving_axis_x": movingAxis.x, "moving_axis_y": movingAxis.y, "moving_axis_z": movingAxis.z, "axial_offset": axialOffset, "opposed": opposed ? 1 : 0, "spin": spin], inputFeatureIds: [referenceInstanceId, movingInstanceId])
        document.features.append(mate)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: author, kind: "create_concentric_mate", featureId: mate.id, parameter: "axial_offset", previousValue: nil, value: axialOffset, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = mate.id
        try persist(); status = "Aligned \(moving.name) axis to \(reference.name) · axial slide and spin remain"
    }

    func createAngleMate(referenceInstanceId: String, movingInstanceId: String, referenceNormal: SIMD3<Double> = SIMD3(0, 0, 1), movingNormal: SIMD3<Double> = SIMD3(0, 0, 1), hingeAxis: SIMD3<Double> = SIMD3(1, 0, 0), angle: Double = 90, spin: Double = 0, author: String = "you") throws {
        guard referenceInstanceId != movingInstanceId,
              let reference = document.features.first(where: { $0.id == referenceInstanceId && $0.kind == "assembly_instance" }),
              let moving = document.features.first(where: { $0.id == movingInstanceId && $0.kind == "assembly_instance" }), moving.params["fixed"] != 1,
              Self.drivingOrientationMate(document, instanceId: movingInstanceId) == nil,
              [referenceNormal.x, referenceNormal.y, referenceNormal.z, movingNormal.x, movingNormal.y, movingNormal.z, hingeAxis.x, hingeAxis.y, hingeAxis.z, angle, spin].allSatisfy(\.isFinite),
              simd_length(referenceNormal) > 0.000_001, simd_length(movingNormal) > 0.000_001, simd_length(hingeAxis) > 0.000_001, simd_length(simd_cross(referenceNormal, hingeAxis)) > 0.000_001,
              angle >= 0, angle <= 180,
              !Self.assemblyMatePathExists(document, from: movingInstanceId, to: referenceInstanceId) else { throw CADValidationError.invalidValue }
        beginMutation(); document.revision += 1
        var suffix = 1; while document.features.contains(where: { $0.id == "mate-angle-\(suffix)" }) { suffix += 1 }
        let mate = CADFeature(id: "mate-angle-\(suffix)", name: "Angle \(moving.name) to \(reference.name)", kind: "assembly_mate", visible: true,
            params: ["mate_type": 5, "reference_normal_x": referenceNormal.x, "reference_normal_y": referenceNormal.y, "reference_normal_z": referenceNormal.z, "moving_normal_x": movingNormal.x, "moving_normal_y": movingNormal.y, "moving_normal_z": movingNormal.z, "hinge_axis_x": hingeAxis.x, "hinge_axis_y": hingeAxis.y, "hinge_axis_z": hingeAxis.z, "angle": angle, "spin": spin], inputFeatureIds: [referenceInstanceId, movingInstanceId])
        document.features.append(mate)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: author, kind: "create_angle_mate", featureId: mate.id, parameter: "angle", previousValue: nil, value: angle, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = mate.id
        try persist(); status = "Set \(moving.name) to \(format(angle))° from \(reference.name) · orientation is mate-driven"
    }

    func setSketchDimensions(width: Double, height: Double, holeDiameter: Double, holeOffset: Double, author: String = "you") throws {
        let solution = SketchSolver.solve(width: width, height: height, holeDiameter: holeDiameter, holeOffset: holeOffset)
        guard solution.errors.isEmpty else {
            lastError = solution.errors.joined(separator: " ")
            throw CADValidationError.invalidValue
        }
        guard let profileIndex = document.features.firstIndex(where: { $0.id == "sketch-base" }),
              let pocketIndex = document.features.firstIndex(where: { $0.id == "pocket-holes" }) else {
            throw CADValidationError.invalidFeature("sketch-base")
        }
        let unchanged = document.features[profileIndex].params["width"] == width
            && document.features[profileIndex].params["height"] == height
            && document.features[pocketIndex].params["diameter"] == holeDiameter
            && document.features[pocketIndex].params["offset"] == holeOffset
        guard !unchanged else { return }

        beginMutation()
        document.revision += 1
        document.features[profileIndex].params["width"] = width
        document.features[profileIndex].params["height"] = height
        document.features[profileIndex].sketch = .mountingPlate
        document.features[pocketIndex].params["diameter"] = holeDiameter
        document.features[pocketIndex].params["offset"] = holeOffset
        document.operations.insert(CADOperation(
            operationId: "op-\(document.revision)", author: author, kind: "solve_sketch",
            featureId: "sketch-base", parameter: "dimensions", previousValue: nil, value: nil,
            revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())
        ), at: 0)
        try persist()
        status = "Solved sketch · \(solution.constraintCount) constraints · fully constrained · revision \(document.revision)"
    }

    func applyPrompt(_ prompt: String) {
        let request = prompt.lowercased()
        do {
            if request.contains("hole") || request.contains("mount") {
                let value = firstNumber(in: request) ?? 6
                try setParameter(featureId: "pocket-holes", key: "diameter", value: value, author: "ai")
            } else if request.contains("thick") || request.contains("strong") {
                let value = firstNumber(in: request) ?? 8
                try setParameter(featureId: "pad-base", key: "length", value: value, author: "ai")
            } else if request.contains("wide") || request.contains("width") {
                let value = firstNumber(in: request) ?? 100
                try setParameter(featureId: "sketch-base", key: "width", value: value, author: "ai")
            } else if request.contains("tall") || request.contains("height") {
                let value = firstNumber(in: request) ?? 70
                try setParameter(featureId: "sketch-base", key: "height", value: value, author: "ai")
            } else {
                let value = firstNumber(in: request) ?? 4
                try setParameter(featureId: "fillet-edges", key: "radius", value: value, author: "ai")
            }
            status = "AI change applied at revision \(document.revision). Geometry updated on the GPU."
        } catch {
            lastError = error.localizedDescription
            status = "AI edit needs attention"
        }
    }

    func runCodex(_ prompt: String) async {
        guard !isAIWorking else { return }
        isAIWorking = true
        status = "Codex is inspecting revision \(document.revision)…"
        do {
            try checkpoint(label: "before-codex")
            let response = try await CodexService.run(request: prompt, workingDirectory: dataDirectory)
            reloadIfChanged()
            status = response.replacingOccurrences(of: "\n", with: " ").prefix(220).description
        } catch {
            lastError = error.localizedDescription
            status = "Codex request did not complete; no uncommitted geometry was applied"
        }
        isAIWorking = false
    }

    func addPrimitive(kind: String) {
        guard ["box", "cylinder", "cone", "sphere", "torus"].contains(kind) else { return }
        beginMutation()
        document.revision += 1
        let prefix = kind
        var suffix = 1
        while document.features.contains(where: { $0.id == "\(prefix)-\(suffix)" }) { suffix += 1 }
        let params: [String: Double] = switch kind {
        case "box": ["width": 30, "height": 24, "depth": 16, "x": 0, "y": 0, "z": 14, "rotation_x": 0, "rotation_y": 0, "rotation_z": 0]
        case "cylinder": ["radius": 8, "height": 22, "x": 0, "y": 0, "z": 14, "rotation_x": 0, "rotation_y": 0, "rotation_z": 0]
        case "cone": ["radius_bottom": 10, "radius_top": 4, "height": 24, "x": 0, "y": 0, "z": 14, "rotation_x": 0, "rotation_y": 0, "rotation_z": 0]
        case "sphere": ["radius": 10, "x": 0, "y": 0, "z": 14, "rotation_x": 0, "rotation_y": 0, "rotation_z": 0]
        default: ["major_radius": 14, "tube_radius": 4, "x": 0, "y": 0, "z": 14, "rotation_x": 0, "rotation_y": 0, "rotation_z": 0]
        }
        let feature = CADFeature(id: "\(prefix)-\(suffix)", name: "\(kind.capitalized) \(suffix)", kind: kind, visible: true, params: params)
        document.features.append(feature)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "create_feature", featureId: feature.id, parameter: nil, previousValue: nil, value: nil, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = feature.id
        try? persist()
        status = "Created \(feature.name) · revision \(document.revision)"
    }

    func importSTEP(from sourceURL: URL) async throws -> [CADFeature] {
        guard ["step", "stp"].contains(sourceURL.pathExtension.lowercased()) else { throw CADValidationError.invalidValue }
        let inspection = try await KernelService.inspectStep(at: sourceURL)
        guard inspection.bodyCount > 0, inspection.bodyCount <= 128, inspection.bodies.allSatisfy(\.canExportStep) else { throw CADValidationError.invalidValue }
        let assetsDirectory = dataDirectory.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        let assetURL = assetsDirectory.appendingPathComponent("import-\(UUID().uuidString.lowercased()).step")
        try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: sourceURL, to: assetURL) }.value
        beginMutation(); document.revision += 1
        let baseName = sourceURL.deletingPathExtension().lastPathComponent.isEmpty ? "Imported STEP" : sourceURL.deletingPathExtension().lastPathComponent
        var suffix = 1; while document.features.contains(where: { $0.id == "imported-step-\(suffix)" || $0.id.hasPrefix("imported-step-\(suffix)-body-") }) { suffix += 1 }
        let imported = inspection.bodies.map { body in
            CADFeature(id: inspection.bodyCount == 1 ? "imported-step-\(suffix)" : "imported-step-\(suffix)-body-\(body.bodyNumber)",
                name: inspection.bodyCount == 1 ? baseName : "\(baseName) · Body \(body.bodyNumber)", kind: "imported_step", visible: true,
                params: ["body_number": Double(body.bodyNumber)], assetPath: assetURL.path)
        }
        document.features.append(contentsOf: imported)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "import_step", featureId: imported.first?.id, parameter: "body_count", previousValue: nil, value: Double(imported.count), revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = imported.first?.id
        try persist(); status = "Imported \(imported.count) retained STEP bod\(imported.count == 1 ? "y" : "ies") · kernel meshes rebuilding"
        return imported
    }

    func createProfileSketch(name: String = "Profile sketch", plane: String = "XY", offset: Double = 0) throws {
        guard ["XY", "XZ", "YZ"].contains(plane), offset.isFinite else { throw CADValidationError.invalidValue }
        beginMutation(); document.revision += 1
        var suffix = 1
        while document.features.contains(where: { $0.id == "profile-sketch-\(suffix)" }) { suffix += 1 }
        let feature = CADFeature(id: "profile-sketch-\(suffix)", name: "\(name) \(suffix)", kind: "profile_sketch", visible: true, params: ["offset": offset], sketch: CADSketchDefinition(plane: plane, profile: "custom-profile", constraints: [], entities: []))
        document.features.append(feature)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "create_profile_sketch", featureId: feature.id, parameter: plane, previousValue: nil, value: nil, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = feature.id
        try persist()
        status = "Created \(feature.name) on \(plane) · draw an outer profile and optional hole loops"
    }

    func addSketchEntity(sketchId: String, entity: CADSketchEntity) throws {
        guard let index = document.features.firstIndex(where: { $0.id == sketchId && $0.kind == "profile_sketch" }) else { throw CADValidationError.invalidFeature(sketchId) }
        guard !entity.id.isEmpty, entity.params.values.allSatisfy(\.isFinite), document.features[index].sketch?.entities?.contains(where: { $0.id == entity.id }) != true else { throw CADValidationError.invalidValue }
        beginMutation(); document.revision += 1
        if document.features[index].sketch?.entities == nil { document.features[index].sketch?.entities = [] }
        document.features[index].sketch?.entities?.append(entity)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "add_sketch_entity", featureId: sketchId, parameter: entity.kind, previousValue: nil, value: nil, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        try persist()
        let solution = CADProfileSketch.solve(feature: document.features[index])
        status = solution.isClosed ? "Closed profile ready to extrude · revision \(document.revision)" : solution.errors.last.map { "Profile needs attention · \($0)" } ?? "Added \(entity.kind) · continue the closed profile"
    }

    func deleteSketchEntity(sketchId: String, entityId: String) throws {
        guard let featureIndex = document.features.firstIndex(where: { $0.id == sketchId && $0.kind == "profile_sketch" }),
              let entityIndex = document.features[featureIndex].sketch?.entities?.firstIndex(where: { $0.id == entityId }) else { throw CADValidationError.invalidFeature(entityId) }
        beginMutation(); document.revision += 1
        document.features[featureIndex].sketch?.entities?.remove(at: entityIndex)
        document.features[featureIndex].sketch?.constraints.removeAll { constraint in
            constraint.entities.contains { reference in reference.split(separator: ":", maxSplits: 1).first.map(String.init) == entityId }
        }
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "delete_sketch_entity", featureId: sketchId, parameter: entityId, previousValue: nil, value: nil, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        try persist(); status = "Deleted sketch entity · revision \(document.revision)"
    }

    func toggleSketchEntityConstruction(sketchId: String, entityId: String) throws {
        guard let featureIndex = document.features.firstIndex(where: { $0.id == sketchId && $0.kind == "profile_sketch" }),
              let entityIndex = document.features[featureIndex].sketch?.entities?.firstIndex(where: { $0.id == entityId }) else { throw CADValidationError.invalidFeature(entityId) }
        beginMutation(); document.revision += 1
        let previous = document.features[featureIndex].sketch?.entities?[entityIndex].construction ?? false
        document.features[featureIndex].sketch?.entities?[entityIndex].construction = !previous
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "toggle_construction", featureId: sketchId, parameter: entityId, previousValue: previous ? 1 : 0, value: previous ? 0 : 1, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        try persist(); status = previous ? "Converted \(entityId) to profile geometry" : "Converted \(entityId) to construction geometry"
    }

    func addSketchConstraint(sketchId: String, constraint: CADSketchConstraint) throws {
        guard let featureIndex = document.features.firstIndex(where: { $0.id == sketchId && $0.kind == "profile_sketch" }),
              var sketch = document.features[featureIndex].sketch,
              !constraint.id.isEmpty, !sketch.constraints.contains(where: { $0.id == constraint.id }) else { throw CADValidationError.invalidValue }
        sketch.constraints.append(constraint)
        sketch.entities = try CADProfileSketch.solving(sketch.constraints, entities: sketch.entities ?? [])
        beginMutation(); document.revision += 1
        document.features[featureIndex].sketch = sketch
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "add_sketch_constraint", featureId: sketchId, parameter: constraint.kind, previousValue: nil, value: constraint.value, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        try persist(); status = "Added \(constraint.kind) constraint · revision \(document.revision)"
    }

    func deleteSketchConstraint(sketchId: String, constraintId: String) throws {
        guard let featureIndex = document.features.firstIndex(where: { $0.id == sketchId && $0.kind == "profile_sketch" }),
              let constraintIndex = document.features[featureIndex].sketch?.constraints.firstIndex(where: { $0.id == constraintId }) else { throw CADValidationError.invalidFeature(constraintId) }
        beginMutation(); document.revision += 1
        document.features[featureIndex].sketch?.constraints.remove(at: constraintIndex)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "delete_sketch_constraint", featureId: sketchId, parameter: constraintId, previousValue: nil, value: nil, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        try persist(); status = "Removed sketch constraint · revision \(document.revision)"
    }

    func updateSketchConstraintValue(sketchId: String, constraintId: String, value: Double) throws {
        guard value.isFinite, value > 0,
              let featureIndex = document.features.firstIndex(where: { $0.id == sketchId && $0.kind == "profile_sketch" }),
              var sketch = document.features[featureIndex].sketch,
              let constraintIndex = sketch.constraints.firstIndex(where: { $0.id == constraintId }),
              ["length", "radius", "angle"].contains(sketch.constraints[constraintIndex].kind),
              sketch.constraints[constraintIndex].kind != "angle" || value < 180 else { throw CADValidationError.invalidValue }
        let previous = sketch.constraints[constraintIndex].value
        sketch.constraints[constraintIndex].value = value
        sketch.entities = try CADProfileSketch.solving(sketch.constraints, entities: sketch.entities ?? [])
        beginMutation(); document.revision += 1
        document.features[featureIndex].sketch = sketch
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "update_sketch_constraint", featureId: sketchId, parameter: constraintId, previousValue: previous, value: value, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        let suffix = sketch.constraints[constraintIndex].kind == "angle" ? "°" : " \(document.units)"
        try persist(); status = "Updated \(constraintId) to \(value.formatted(.number.precision(.fractionLength(0...3))))\(suffix)"
    }

    func trimOrExtendSketchLine(sketchId: String, lineId: String, referenceLineId: String, endpoint: String, mode: String) throws {
        guard let featureIndex = document.features.firstIndex(where: { $0.id == sketchId && $0.kind == "profile_sketch" }),
              var sketch = document.features[featureIndex].sketch,
              let lineIndex = sketch.entities?.firstIndex(where: { $0.id == lineId }),
              let referenceIndex = sketch.entities?.firstIndex(where: { $0.id == referenceLineId }),
              let line = sketch.entities?[lineIndex], let reference = sketch.entities?[referenceIndex] else { throw CADValidationError.invalidValue }
        let edited = try CADProfileSketch.trimmingOrExtending(line: line, to: reference, endpoint: endpoint, mode: mode)
        sketch.entities?[lineIndex] = edited
        sketch.entities = try CADProfileSketch.solving(sketch.constraints, entities: sketch.entities ?? [])
        guard let solvedLine = sketch.entities?[lineIndex], let solvedReference = sketch.entities?[referenceIndex],
              let point = CADProfileSketch.endpoint(solvedLine, start: endpoint == "start"),
              let referenceStart = CADProfileSketch.endpoint(solvedReference, start: true), let referenceEnd = CADProfileSketch.endpoint(solvedReference, start: false) else { throw CADValidationError.invalidValue }
        let vector = referenceEnd - referenceStart, lengthSquared = simd_length_squared(vector)
        guard lengthSquared > 0.000_001 else { throw CADValidationError.invalidValue }
        let projection = simd_dot(point - referenceStart, vector) / lengthSquared
        let nearest = referenceStart + vector * projection
        guard projection >= -0.000_1, projection <= 1.000_1, simd_distance(point, nearest) <= 0.001 else { throw CADValidationError.invalidValue }
        beginMutation(); document.revision += 1
        document.features[featureIndex].sketch = sketch
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "\(mode)_sketch_line", featureId: sketchId, parameter: "\(lineId):\(endpoint)", previousValue: nil, value: nil, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        try persist(); status = "\(mode == "trim" ? "Trimmed" : "Extended") \(lineId) to \(referenceLineId) · revision \(document.revision)"
    }

    func createExtrusion(sketchId: String, length: Double = 20, symmetric: Bool = false) throws {
        guard length.isFinite, length > 0, let sketch = document.features.first(where: { $0.id == sketchId && $0.kind == "profile_sketch" }) else { throw CADValidationError.invalidValue }
        guard CADProfileSketch.solve(feature: sketch).isClosed else { throw CADValidationError.invalidValue }
        beginMutation(); document.revision += 1
        var suffix = 1
        while document.features.contains(where: { $0.id == "extrude-\(suffix)" }) { suffix += 1 }
        if let index = document.features.firstIndex(where: { $0.id == sketchId }) { document.features[index].visible = false }
        let feature = CADFeature(id: "extrude-\(suffix)", name: "Extrusion \(suffix)", kind: "extrude_feature", visible: true, params: ["length": length, "symmetric": symmetric ? 1 : 0], inputFeatureIds: [sketchId])
        document.features.append(feature)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "create_extrusion", featureId: feature.id, parameter: "length", previousValue: nil, value: length, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = feature.id
        try persist(); status = "Created \(feature.name) · kernel rebuild started"
    }

    func createPocket(targetFeatureId: String, sketchId: String, length: Double = 20, symmetric: Bool = false) throws {
        guard length.isFinite, length > 0, targetFeatureId != sketchId,
              let target = document.features.first(where: { $0.id == targetFeatureId }),
              let sketch = document.features.first(where: { $0.id == sketchId && $0.kind == "profile_sketch" }) else { throw CADValidationError.invalidValue }
        let supported = Set(["pad", "pocket", "fillet", "box", "cylinder", "cone", "sphere", "torus"]).union(kernelDerivedFeatureKinds)
        guard supported.contains(target.kind), CADProfileSketch.solve(feature: sketch).isClosed else { throw CADValidationError.invalidValue }
        beginMutation(); document.revision += 1
        var suffix = 1
        while document.features.contains(where: { $0.id == "pocket-feature-\(suffix)" }) { suffix += 1 }
        for suppressedId in Self.suppressedIds(for: targetFeatureId) {
            if let index = document.features.firstIndex(where: { $0.id == suppressedId }) { document.features[index].visible = false }
        }
        if let index = document.features.firstIndex(where: { $0.id == sketchId }) { document.features[index].visible = false }
        let feature = CADFeature(id: "pocket-feature-\(suffix)", name: "Pocket \(suffix)", kind: "pocket_feature", visible: true, params: ["length": length, "symmetric": symmetric ? 1 : 0], inputFeatureIds: [targetFeatureId, sketchId])
        document.features.append(feature)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "create_pocket", featureId: feature.id, parameter: "length", previousValue: nil, value: length, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = feature.id
        try persist(); status = "Created \(feature.name) in \(target.name) · kernel rebuild started"
    }

    func createRevolve(sketchId: String, angle: Double = 360, axis: SIMD3<Double> = SIMD3(0, 1, 0), origin: SIMD3<Double> = .zero) throws {
        guard angle.isFinite, angle > 0, angle <= 360, axis.x.isFinite, axis.y.isFinite, axis.z.isFinite,
              origin.x.isFinite, origin.y.isFinite, origin.z.isFinite, simd_length(axis) > 0.000_001,
              let sketch = document.features.first(where: { $0.id == sketchId && $0.kind == "profile_sketch" }),
              CADProfileSketch.solve(feature: sketch).isClosed else { throw CADValidationError.invalidValue }
        beginMutation(); document.revision += 1
        var suffix = 1
        while document.features.contains(where: { $0.id == "revolve-\(suffix)" }) { suffix += 1 }
        if let index = document.features.firstIndex(where: { $0.id == sketchId }) { document.features[index].visible = false }
        let normalized = simd_normalize(axis)
        let feature = CADFeature(
            id: "revolve-\(suffix)", name: "Revolve \(suffix)", kind: "revolve_feature", visible: true,
            params: ["angle": angle, "axis_x": normalized.x, "axis_y": normalized.y, "axis_z": normalized.z, "origin_x": origin.x, "origin_y": origin.y, "origin_z": origin.z],
            inputFeatureIds: [sketchId]
        )
        document.features.append(feature)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "create_revolve", featureId: feature.id, parameter: "angle", previousValue: nil, value: angle, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = feature.id
        try persist(); status = "Created \(feature.name) · kernel rebuild started"
    }

    func createSweep(sketchId: String, start: SIMD3<Double> = .zero, end: SIMD3<Double> = SIMD3(0, 0, 40), twistAngle: Double = 0, scaleStart: Double = 1, scaleEnd: Double = 1, scaleStations: [CADSweepScaleStation] = [], profileSections: [CADSweepProfileSection] = [], frameMode: CADSweepFrameMode = .minimumTwist, upDirection: SIMD3<Double> = SIMD3(0, 0, 1), guidePoints: [SIMD3<Double>] = []) throws {
        guard start.x.isFinite, start.y.isFinite, start.z.isFinite, end.x.isFinite, end.y.isFinite, end.z.isFinite,
              twistAngle.isFinite, scaleStart.isFinite, scaleEnd.isFinite, scaleStart > 0, scaleEnd > 0,
              simd_distance(start, end) > 0.000_001,
              let sketch = document.features.first(where: { $0.id == sketchId && $0.kind == "profile_sketch" }),
              CADProfileSketch.solve(feature: sketch).isClosed else { throw CADValidationError.invalidValue }
        let sectionIds = profileSections.map(\.sketchId)
        let baseLoops = Set((sketch.sketch?.entities ?? []).filter { !$0.construction }.map(\.profileLoopId))
        guard profileSections.count <= 8, Set(sectionIds).count == sectionIds.count,
              !sectionIds.contains(sketchId), (profileSections.isEmpty || baseLoops == ["outer"]),
              profileSections.allSatisfy({ section in
                  guard let feature = document.features.first(where: { $0.id == section.sketchId && $0.kind == "profile_sketch" }),
                        CADProfileSketch.solve(feature: feature).isClosed else { return false }
                  let loops = Set((feature.sketch?.entities ?? []).filter { !$0.construction }.map(\.profileLoopId))
                  return loops == ["outer"]
              }) else { throw CADValidationError.invalidValue }
        var params: [String: Double] = ["start_x": start.x, "start_y": start.y, "start_z": start.z, "end_x": end.x, "end_y": end.y, "end_z": end.z, "twist_angle": twistAngle, "scale_start": scaleStart, "scale_end": scaleEnd]
        try Self.storeSweepOrientation(frameMode, upDirection: upDirection, guidePoints: guidePoints, in: &params)
        Self.storeSweepScaleStations(scaleStations, in: &params)
        Self.storeSweepProfileSections(profileSections, in: &params)
        guard Self.sweepScaleStationError(params) == nil, Self.sweepProfileStationError(params) == nil else { throw CADValidationError.invalidValue }
        beginMutation(); document.revision += 1
        var suffix = 1
        while document.features.contains(where: { $0.id == "sweep-\(suffix)" }) { suffix += 1 }
        for inputId in [sketchId] + sectionIds {
            if let index = document.features.firstIndex(where: { $0.id == inputId }) { document.features[index].visible = false }
        }
        let feature = CADFeature(
            id: "sweep-\(suffix)", name: profileSections.isEmpty ? "Sweep \(suffix)" : "Morph sweep \(suffix)", kind: "sweep_feature", visible: true,
            params: params,
            inputFeatureIds: [sketchId] + sectionIds
        )
        document.features.append(feature)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "create_sweep", featureId: feature.id, parameter: "twist_angle", previousValue: nil, value: twistAngle, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = feature.id
        try persist(); status = profileSections.isEmpty ? "Created \(feature.name) · kernel rebuild started" : "Created \(feature.name) through \(profileSections.count + 1) section shapes · kernel rebuild started"
    }

    func createHelixSweep(sketchId: String, radius: Double = 10, pitch: Double = 8, turns: Double = 4, twistAngle: Double = 0, scaleStart: Double = 1, scaleEnd: Double = 1, scaleStations: [CADSweepScaleStation] = [], frameMode: CADSweepFrameMode = .minimumTwist, upDirection: SIMD3<Double> = SIMD3(0, 0, 1), guidePoints: [SIMD3<Double>] = []) throws {
        guard [radius, pitch, turns, scaleStart, scaleEnd].allSatisfy({ $0.isFinite && $0 > 0 }), twistAngle.isFinite,
              let sketch = document.features.first(where: { $0.id == sketchId && $0.kind == "profile_sketch" }), CADProfileSketch.solve(feature: sketch).isClosed else { throw CADValidationError.invalidValue }
        var params: [String: Double] = ["helix_radius": radius, "helix_pitch": pitch, "helix_turns": turns, "twist_angle": twistAngle, "scale_start": scaleStart, "scale_end": scaleEnd]
        try Self.storeSweepOrientation(frameMode, upDirection: upDirection, guidePoints: guidePoints, in: &params)
        Self.storeSweepScaleStations(scaleStations, in: &params)
        guard Self.sweepScaleStationError(params) == nil else { throw CADValidationError.invalidValue }
        beginMutation(); document.revision += 1
        var suffix = 1; while document.features.contains(where: { $0.id == "helix-sweep-\(suffix)" }) { suffix += 1 }
        if let index = document.features.firstIndex(where: { $0.id == sketchId }) { document.features[index].visible = false }
        let feature = CADFeature(id: "helix-sweep-\(suffix)", name: "Helix sweep \(suffix)", kind: "sweep_feature", visible: true,
            params: params, inputFeatureIds: [sketchId])
        document.features.append(feature)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "create_helix_sweep", featureId: feature.id, parameter: "helix_radius", previousValue: nil, value: radius, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = feature.id
        try persist(); status = "Created \(feature.name) · curved kernel rebuild started"
    }

    func createSplineSweep(sketchId: String, points: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(0, 10, 12), SIMD3(10, 10, 26), SIMD3(14, 0, 40)], twistAngle: Double = 0, scaleStart: Double = 1, scaleEnd: Double = 1, scaleStations: [CADSweepScaleStation] = [], frameMode: CADSweepFrameMode = .minimumTwist, upDirection: SIMD3<Double> = SIMD3(0, 0, 1), guidePoints: [SIMD3<Double>] = [], startTangent: SIMD3<Double>? = nil, endTangent: SIMD3<Double>? = nil) throws {
        guard points.count >= 2, points.count <= 12,
              points.flatMap({ [$0.x, $0.y, $0.z] }).allSatisfy(\.isFinite),
              zip(points, points.dropFirst()).contains(where: { simd_distance($0, $1) > 0.000_001 }),
              twistAngle.isFinite, scaleStart.isFinite, scaleEnd.isFinite, scaleStart > 0, scaleEnd > 0,
              let sketchIndex = document.features.firstIndex(where: { $0.id == sketchId && $0.kind == "profile_sketch" }),
              CADProfileSketch.solve(feature: document.features[sketchIndex]).isClosed else { throw CADValidationError.invalidValue }
        var params: [String: Double] = ["path_point_count": Double(points.count), "twist_angle": twistAngle, "scale_start": scaleStart, "scale_end": scaleEnd]
        try Self.storeSweepOrientation(frameMode, upDirection: upDirection, guidePoints: guidePoints, in: &params)
        try Self.storeSweepTangents(startTangent, endTangent: endTangent, in: &params)
        Self.storeSweepScaleStations(scaleStations, in: &params)
        for (index, point) in points.enumerated() {
            params["path_\(index)_x"] = point.x; params["path_\(index)_y"] = point.y; params["path_\(index)_z"] = point.z
        }
        let automaticStart = 0.5 * (points[1] - points[0]), automaticEnd = 0.5 * (points[points.count - 1] - points[points.count - 2])
        if startTangent == nil { params["start_tangent_x"] = automaticStart.x; params["start_tangent_y"] = automaticStart.y; params["start_tangent_z"] = automaticStart.z }
        if endTangent == nil { params["end_tangent_x"] = automaticEnd.x; params["end_tangent_y"] = automaticEnd.y; params["end_tangent_z"] = automaticEnd.z }
        guard Self.sweepScaleStationError(params) == nil, Self.sweepPathControlError(params) == nil else { throw CADValidationError.invalidValue }
        beginMutation(); document.revision += 1
        var suffix = 1; while document.features.contains(where: { $0.id == "spline-sweep-\(suffix)" }) { suffix += 1 }
        document.features[sketchIndex].visible = false
        let feature = CADFeature(id: "spline-sweep-\(suffix)", name: "Spline sweep \(suffix)", kind: "sweep_feature", visible: true, params: params, inputFeatureIds: [sketchId])
        document.features.append(feature)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "create_spline_sweep", featureId: feature.id, parameter: "path_point_count", previousValue: nil, value: Double(points.count), revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = feature.id
        try persist(); status = "Created \(feature.name) through \(points.count) guide points · kernel rebuild started"
    }

    func createCompositeSweep(sketchId: String, segments: [CADCompositePathSegment] = [
        .line(start: SIMD3(0, 0, 0), end: SIMD3(0, 0, 12)),
        .arc(start: SIMD3(0, 0, 12), mid: SIMD3(8, 0, 20), end: SIMD3(0, 0, 28)),
        .line(start: SIMD3(0, 0, 28), end: SIMD3(0, 0, 40))
    ], twistAngle: Double = 0, scaleStart: Double = 1, scaleEnd: Double = 1, scaleStations: [CADSweepScaleStation] = [], frameMode: CADSweepFrameMode = .minimumTwist, upDirection: SIMD3<Double> = SIMD3(0, 0, 1), guidePoints: [SIMD3<Double>] = [], continuity: CADSweepContinuityMode = .position, tangentTolerance: Double = 1) throws {
        guard (1...12).contains(segments.count), twistAngle.isFinite, scaleStart.isFinite, scaleEnd.isFinite, scaleStart > 0, scaleEnd > 0,
              let sketchIndex = document.features.firstIndex(where: { $0.id == sketchId && $0.kind == "profile_sketch" }),
              CADProfileSketch.solve(feature: document.features[sketchIndex]).isClosed else { throw CADValidationError.invalidValue }
        var params: [String: Double] = ["path_segment_count": Double(segments.count), "twist_angle": twistAngle, "scale_start": scaleStart, "scale_end": scaleEnd]
        try Self.storeSweepOrientation(frameMode, upDirection: upDirection, guidePoints: guidePoints, in: &params)
        params["continuity_mode"] = Double(continuity.rawValue); params["tangent_tolerance"] = tangentTolerance
        Self.storeSweepScaleStations(scaleStations, in: &params)
        func store(_ point: SIMD3<Double>, index: Int, role: String) {
            params["path_\(index)_\(role)_x"] = point.x; params["path_\(index)_\(role)_y"] = point.y; params["path_\(index)_\(role)_z"] = point.z
        }
        for (index, segment) in segments.enumerated() {
            switch segment {
            case let .line(start, end):
                params["path_\(index)_kind"] = 0; store(start, index: index, role: "start"); store(end, index: index, role: "end")
            case let .arc(start, mid, end):
                params["path_\(index)_kind"] = 1; store(start, index: index, role: "start"); store(mid, index: index, role: "mid"); store(end, index: index, role: "end")
            }
        }
        guard Self.compositePathError(params) == nil, Self.sweepScaleStationError(params) == nil else { throw CADValidationError.invalidValue }
        beginMutation(); document.revision += 1
        var suffix = 1; while document.features.contains(where: { $0.id == "composite-sweep-\(suffix)" }) { suffix += 1 }
        document.features[sketchIndex].visible = false
        let feature = CADFeature(id: "composite-sweep-\(suffix)", name: "Composite sweep \(suffix)", kind: "sweep_feature", visible: true, params: params, inputFeatureIds: [sketchId])
        document.features.append(feature)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "create_composite_sweep", featureId: feature.id, parameter: "path_segment_count", previousValue: nil, value: Double(segments.count), revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = feature.id
        try persist(); status = "Created \(feature.name) along \(segments.count) line/arc segments · kernel rebuild started"
    }

    func createLoft(sketchIds: [String], closed: Bool = false) throws {
        let uniqueIds = Array(NSOrderedSet(array: sketchIds)) as? [String] ?? sketchIds
        guard uniqueIds.count >= 2 else { throw CADValidationError.invalidValue }
        let sketches = uniqueIds.compactMap { id in document.features.first { $0.id == id && $0.kind == "profile_sketch" } }
        guard sketches.count == uniqueIds.count, sketches.allSatisfy({ CADProfileSketch.solve(feature: $0).isClosed }) else { throw CADValidationError.invalidValue }
        beginMutation(); document.revision += 1
        var suffix = 1
        while document.features.contains(where: { $0.id == "loft-\(suffix)" }) { suffix += 1 }
        for sketchId in uniqueIds {
            if let index = document.features.firstIndex(where: { $0.id == sketchId }) { document.features[index].visible = false }
        }
        let feature = CADFeature(id: "loft-\(suffix)", name: "Loft \(suffix)", kind: "loft_feature", visible: true, params: ["closed": closed ? 1 : 0], inputFeatureIds: uniqueIds)
        document.features.append(feature)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "create_loft", featureId: feature.id, parameter: "closed", previousValue: nil, value: closed ? 1 : 0, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = feature.id
        try persist(); status = "Created \(feature.name) from \(uniqueIds.count) profiles · kernel rebuild started"
    }

    func createBoolean(operation: String, leftFeatureId: String, rightFeatureId: String) throws {
        guard ["union", "difference", "intersection"].contains(operation), leftFeatureId != rightFeatureId else { throw CADValidationError.invalidValue }
        guard let left = document.features.first(where: { $0.id == leftFeatureId }),
              let right = document.features.first(where: { $0.id == rightFeatureId }) else { throw CADValidationError.invalidFeature(leftFeatureId) }
        let supported = Set(["pad", "pocket", "fillet", "box", "cylinder", "cone", "sphere", "torus"]).union(kernelDerivedFeatureKinds)
        guard supported.contains(left.kind), supported.contains(right.kind) else { throw CADValidationError.invalidValue }

        beginMutation(); document.revision += 1
        var suffix = 1
        while document.features.contains(where: { $0.id == "boolean-\(operation)-\(suffix)" }) { suffix += 1 }
        for inputId in [leftFeatureId, rightFeatureId] {
            for suppressedId in Self.suppressedIds(for: inputId) {
                if let index = document.features.firstIndex(where: { $0.id == suppressedId }) { document.features[index].visible = false }
            }
        }
        let feature = CADFeature(id: "boolean-\(operation)-\(suffix)", name: "\(operation.capitalized) \(suffix)", kind: "boolean_\(operation)", visible: true, params: [:], inputFeatureIds: [leftFeatureId, rightFeatureId])
        document.features.append(feature)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "create_boolean", featureId: feature.id, parameter: operation, previousValue: nil, value: nil, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = feature.id
        try persist()
        status = "Created \(feature.name) from \(left.name) and \(right.name) · kernel rebuild started"
    }

    func createModifier(kind: String, inputFeatureId: String) throws {
        guard let input = document.features.first(where: { $0.id == inputFeatureId }) else { throw CADValidationError.invalidFeature(inputFeatureId) }
        let supportedInputs = Set(["pad", "pocket", "fillet", "box", "cylinder", "cone", "sphere", "torus"]).union(kernelDerivedFeatureKinds)
        guard supportedInputs.contains(input.kind) else { throw CADValidationError.invalidValue }
        let params: [String: Double]
        let label: String
        switch kind {
        case "edge_fillet":
            params = ["radius": 2].merging(edgeSelectorParameters(inputFeatureId: inputFeatureId)) { current, _ in current }; label = "Fillet"
        case "edge_chamfer":
            params = ["distance": 2].merging(edgeSelectorParameters(inputFeatureId: inputFeatureId)) { current, _ in current }; label = "Chamfer"
        case "shell_feature": params = ["thickness": 1.5]; label = "Shell"
        case "linear_pattern": params = ["direction_x": 1, "direction_y": 0, "direction_z": 0, "count": 3, "spacing": 24]; label = "Linear pattern"
        case "circular_pattern": params = ["origin_x": 0, "origin_y": 0, "origin_z": 0, "axis_x": 0, "axis_y": 0, "axis_z": 1, "count": 4, "angle": 360]; label = "Circular pattern"
        default: throw CADValidationError.invalidValue
        }
        beginMutation(); document.revision += 1
        var suffix = 1
        while document.features.contains(where: { $0.id == "\(kind.replacingOccurrences(of: "_", with: "-"))-\(suffix)" }) { suffix += 1 }
        for suppressedId in Self.suppressedIds(for: inputFeatureId) {
            if let index = document.features.firstIndex(where: { $0.id == suppressedId }) { document.features[index].visible = false }
        }
        let feature = CADFeature(id: "\(kind.replacingOccurrences(of: "_", with: "-"))-\(suffix)", name: "\(label) \(suffix)", kind: kind, visible: true, params: params, inputFeatureIds: [inputFeatureId])
        document.features.append(feature)
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "create_modifier", featureId: feature.id, parameter: kind, previousValue: nil, value: nil, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = feature.id
        try persist()
        status = "Created \(feature.name) from \(input.name) · kernel rebuild started"
    }

    private func edgeSelectorParameters(inputFeatureId: String) -> [String: Double] {
        guard let surface = selectedSurface, surface.featureId == inputFeatureId else { return [:] }
        var params = ["selector_mode": surface.topologyEdgeId == nil ? 1 : 3, "selector_x": Double(surface.position.x), "selector_y": Double(surface.position.y), "selector_z": Double(surface.position.z), "selector_tolerance": 10]
        if let faceId = surface.topologyFaceId { params["selector_face_id"] = Double(faceId) }
        if let edgeId = surface.topologyEdgeId, let faces = surface.topologyEdgeFaceIds?.sorted(), faces.count == 2 {
            params["selector_edge_id"] = Double(edgeId)
            params["selector_edge_face_a"] = Double(faces[0])
            params["selector_edge_face_b"] = Double(faces[1])
        }
        return params
    }

    func newDocument(name: String = "Untitled part", author: String = "you") throws {
        let previousRevision = document.revision
        beginMutation()
        document = .newPart(name: name, revision: previousRevision + 1)
        document.operations.insert(CADOperation(
            operationId: "op-\(document.revision)", author: author, kind: "new_document",
            featureId: nil, parameter: nil, previousValue: nil, value: nil,
            revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())
        ), at: 0)
        selectedFeatureId = "sketch-base"
        projectURL = nil
        lastSavedRevision = nil
        persistProjectSession()
        try persist()
        status = "Created \(name) · revision \(document.revision)"
    }

    func openDocument(from url: URL) throws {
        let data = try Data(contentsOf: url)
        var incoming = Self.migrated(try decoder.decode(CADDocument.self, from: data))
        for index in incoming.features.indices where incoming.features[index].kind == "imported_step" {
            guard let storedPath = incoming.features[index].assetPath else { continue }
            let resolved = URL(fileURLWithPath: storedPath, relativeTo: storedPath.hasPrefix("/") ? nil : url.deletingLastPathComponent()).standardizedFileURL
            incoming.features[index].assetPath = resolved.path
        }
        let structuralErrors = Self.validationErrors(in: incoming)
        guard structuralErrors.isEmpty else {
            lastError = "Could not open \(url.lastPathComponent): \(structuralErrors.joined(separator: " "))"
            throw CADValidationError.invalidValue
        }
        let previousRevision = document.revision
        let importedAssetPaths = Set(incoming.features.compactMap { $0.kind == "imported_step" ? $0.assetPath : nil })
        if !importedAssetPaths.isEmpty {
            let assetsDirectory = dataDirectory.appendingPathComponent("assets", isDirectory: true)
            try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
            var managedPaths: [String: String] = [:]
            for sourcePath in importedAssetPaths {
                let target = assetsDirectory.appendingPathComponent("open-\(UUID().uuidString.lowercased()).step")
                try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: target)
                managedPaths[sourcePath] = target.path
            }
            for index in incoming.features.indices where incoming.features[index].kind == "imported_step" {
                if let sourcePath = incoming.features[index].assetPath { incoming.features[index].assetPath = managedPaths[sourcePath] }
            }
        }
        beginMutation()
        incoming.revision = previousRevision + 1
        incoming.operations.insert(CADOperation(
            operationId: "op-\(incoming.revision)", author: "you", kind: "open_document",
            featureId: nil, parameter: nil, previousValue: nil, value: nil,
            revision: incoming.revision, timestamp: ISO8601DateFormatter().string(from: Date())
        ), at: 0)
        document = incoming
        selectedFeatureId = document.features.first?.id
        try persist()
        rememberDocument(url)
        projectURL = url.standardizedFileURL
        lastSavedRevision = document.revision
        persistProjectSession()
        status = "Opened \(url.lastPathComponent) · revision \(document.revision)"
    }

    func restoreCheckpoint(_ summary: CADCheckpointSummary) throws {
        let url = URL(fileURLWithPath: summary.path), data = try Data(contentsOf: url)
        var restored = Self.migrated(try decoder.decode(CADDocument.self, from: data))
        let errors = Self.validationErrors(in: restored); guard errors.isEmpty else { throw CADValidationError.invalidValue }
        let previousRevision = document.revision; beginMutation(); restored.revision = previousRevision + 1
        restored.operations.insert(CADOperation(operationId: "op-\(restored.revision)", author: "you", kind: "restore_checkpoint", featureId: nil, parameter: summary.name, previousValue: Double(summary.revision), value: Double(restored.revision), revision: restored.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        document = restored; selectedFeatureId = document.features.first?.id; try persist()
        status = "Restored checkpoint r\(summary.revision) as revision \(document.revision)"
    }

    func setVisibility(featureId: String, visible: Bool) {
        guard let index = document.features.firstIndex(where: { $0.id == featureId }), document.features[index].visible != visible else { return }
        beginMutation()
        document.revision += 1
        document.features[index].visible = visible
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "set_visibility", featureId: featureId, parameter: nil, previousValue: nil, value: nil, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        try? persist()
        status = visible ? "Showing \(document.features[index].name)" : "Hid \(document.features[index].name)"
    }

    func deleteFeature(featureId: String) {
        guard !["sketch-base", "pad-base", "pocket-holes", "fillet-edges"].contains(featureId),
              let index = document.features.firstIndex(where: { $0.id == featureId }) else {
            lastError = "Base bracket features are protected until dependency-aware deletion is implemented."
            return
        }
        if let dependent = document.features.first(where: { $0.inputFeatureIds?.contains(featureId) == true }) {
            lastError = "\(document.features[index].name) is used by \(dependent.name). Delete the dependent feature first."
            return
        }
        beginMutation()
        document.revision += 1
        let removed = document.features.remove(at: index)
        for inputId in removed.kind == "assembly_mate" ? [] : removed.inputFeatureIds ?? [] {
            if removed.kind == "assembly_instance", document.features.contains(where: { $0.kind == "assembly_instance" && $0.inputFeatureIds?.first == inputId }) { continue }
            for restoredId in Self.suppressedIds(for: inputId) {
                if let restored = document.features.firstIndex(where: { $0.id == restoredId }) { document.features[restored].visible = true }
            }
        }
        document.operations.insert(CADOperation(operationId: "op-\(document.revision)", author: "you", kind: "delete_feature", featureId: removed.id, parameter: nil, previousValue: nil, value: nil, revision: document.revision, timestamp: ISO8601DateFormatter().string(from: Date())), at: 0)
        selectedFeatureId = removed.inputFeatureIds?.first(where: { inputId in
            document.features.contains { $0.id == inputId }
        }) ?? document.features.first?.id
        try? persist()
        status = "Deleted \(removed.name) · undo is available"
    }

    func checkpoint(label: String = "manual") throws {
        try FileManager.default.createDirectory(at: checkpointsURL, withIntermediateDirectories: true)
        let safe = label.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let url = checkpointsURL.appendingPathComponent("r\(document.revision)-\(safe.isEmpty ? "checkpoint" : safe).json")
        let data = try encoder.encode(document)
        try data.write(to: url, options: [.atomic])
        status = "Checkpoint saved for revision \(document.revision)"
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
        selectedSurface = nil
        measurementProbe = nil
        isMeasuring = false
        try? persistView()
        try? persist()
        status = "Undid change · revision \(document.revision)"
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
        selectedSurface = nil
        measurementProbe = nil
        isMeasuring = false
        try? persistView()
        try? persist()
        status = "Redid change · revision \(document.revision)"
    }

    func reloadIfChanged() {
        reloadViewIfChanged()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: documentURL.path),
              let modified = attributes[.modificationDate] as? Date,
              modified != knownModificationDate,
              let data = try? Data(contentsOf: documentURL),
              let external = try? decoder.decode(CADDocument.self, from: data),
              external != document else { return }
        document = Self.migrated(external)
        selectedSurface = nil
        measurementProbe = nil
        motionStudy = nil
        syncMotionTimer()
        isMeasuring = false
        try? persistView()
        knownModificationDate = modified
        if !document.features.contains(where: { $0.id == selectedFeatureId }) { selectedFeatureId = document.features.first?.id }
        try? persistSelection()
        status = "Reloaded revision \(document.revision) from Codex MCP"
        scheduleKernelRefresh()
    }

    private func reloadViewIfChanged() {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: viewURL.path)[.modificationDate]) as? Date, modified != knownViewModificationDate,
              let data = try? Data(contentsOf: viewURL), let view = try? decoder.decode(CADViewState.self, from: data) else { return }
        sectionPlane = view.section
        measurementProbe = view.measurement?.revision == document.revision ? view.measurement : nil
        isolatedFeatureId = view.isolatedFeatureId.flatMap { id in document.features.contains { $0.id == id } ? id : nil }
        explodedDistance = min(200, max(0, view.explodedDistance ?? 0))
        motionStudy = Self.validMotionStudy(view.motionStudy, in: document)
        syncMotionTimer()
        knownViewModificationDate = modified
    }

    func exportJSON(to url: URL) throws {
        var exported = document
        let assetPaths = Set(exported.features.compactMap { $0.kind == "imported_step" ? $0.assetPath : nil })
        if !assetPaths.isEmpty {
            let assetsRootName = "\(url.deletingPathExtension().lastPathComponent).assets"
            let generation = UUID().uuidString.lowercased()
            let generationDirectory = url.deletingLastPathComponent().appendingPathComponent(assetsRootName, isDirectory: true).appendingPathComponent(generation, isDirectory: true)
            try FileManager.default.createDirectory(at: generationDirectory, withIntermediateDirectories: true)
            var relativePaths: [String: String] = [:]
            for (index, sourcePath) in assetPaths.sorted().enumerated() {
                let targetName = "asset-\(index + 1).step", target = generationDirectory.appendingPathComponent(targetName)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: target)
                relativePaths[sourcePath] = "\(assetsRootName)/\(generation)/\(targetName)"
            }
            for index in exported.features.indices where exported.features[index].kind == "imported_step" {
                if let sourcePath = exported.features[index].assetPath { exported.features[index].assetPath = relativePaths[sourcePath] }
            }
        }
        try encoder.encode(exported).write(to: url, options: [.atomic])
        rememberDocument(url)
        projectURL = url.standardizedFileURL
        lastSavedRevision = document.revision
        persistProjectSession()
        status = "Exported \(url.lastPathComponent)"
    }

    func saveProject() throws {
        guard let projectURL else { throw CADProjectError.noSaveDestination }
        try exportJSON(to: projectURL)
        status = "Saved \(projectURL.lastPathComponent)"
    }

    func exportSTL(to url: URL) throws {
        try STLExporter.data(document: document, kernelMeshes: kernelRenderMeshes).write(to: url, options: [.atomic])
        status = "Exported manufacturing mesh: \(url.lastPathComponent)"
    }

    func validate() -> [String] {
        let errors = Self.validationErrors(in: document)
        status = errors.isEmpty ? "Geometry parameters valid · revision \(document.revision)" : "Found \(errors.count) validation error(s)"
        return errors
    }

    func refreshKernelMeshes() async {
        kernelRefreshTask?.cancel()
        kernelRefreshTask = nil
        await performKernelMeshRefresh()
    }

    private func scheduleKernelRefresh() {
        kernelRefreshTask?.cancel()
        kernelRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(75)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            await self.performKernelMeshRefresh()
            if !Task.isCancelled { self.kernelRefreshTask = nil }
        }
    }

    private func performKernelMeshRefresh() async {
        let revision = document.revision
        let featureIds = document.features.filter { $0.visible && kernelDerivedFeatureKinds.contains($0.kind) }.map(\.id)
        guard !featureIds.isEmpty else {
            kernelRenderMeshes = []
            isKernelRendering = false
            return
        }
        isKernelRendering = true
        defer {
            if document.revision == revision { isKernelRendering = false }
        }
        var meshes: [CADKernelRenderMesh] = []
        do {
            for featureId in featureIds {
                guard !Task.isCancelled else { return }
                let mesh = try await KernelService.renderMesh(documentURL: documentURL, featureId: featureId)
                guard mesh.revision == revision else { return }
                meshes.append(mesh)
            }
            guard document.revision == revision else { return }
            kernelRenderMeshes = meshes
        } catch KernelServiceError.cancelled {
            return
        } catch {
            guard document.revision == revision else { return }
            kernelRenderMeshes = []
            lastError = error.localizedDescription
        }
    }

    func checkClearance(to secondFeatureId: String) async {
        guard let featureId = selectedFeatureId, featureId != secondFeatureId else { return }
        let revision = document.revision
        isCheckingClearance = true
        defer { isCheckingClearance = false }
        do {
            let result = try await KernelService.clearance(documentURL: documentURL, featureId: featureId, secondFeatureId: secondFeatureId)
            guard document.revision == revision, result.revision == revision else { return }
            clearanceResult = result
            status = switch result.classification {
            case "interference": "Interference · \(abs(result.distance).formatted(.number.precision(.fractionLength(0...3)))) \(document.units) penetration"
            case "touching": "Bodies touch · zero clearance"
            default: "Clearance · \(result.distance.formatted(.number.precision(.fractionLength(0...3)))) \(document.units)"
            }
        } catch {
            guard document.revision == revision else { return }
            clearanceResult = nil
            lastError = error.localizedDescription
        }
    }

    private static func setCompositePathParameter(_ params: inout [String: Double], key: String, value: Double) {
        params[key] = value
        let components = key.split(separator: "_")
        guard components.count == 4, components[0] == "path", let index = Int(components[1]), ["start", "end"].contains(String(components[2])), ["x", "y", "z"].contains(String(components[3])),
              let rawCount = params["path_segment_count"] else { return }
        let role = String(components[2]), axis = String(components[3]), count = Int(rawCount)
        if role == "start", index > 0 { params["path_\(index - 1)_end_\(axis)"] = value }
        if role == "end", index + 1 < count { params["path_\(index + 1)_start_\(axis)"] = value }
    }

    private static func storeSweepScaleStations(_ stations: [CADSweepScaleStation], in params: inout [String: Double]) {
        guard !stations.isEmpty else { return }
        params["scale_station_count"] = Double(stations.count)
        for (index, station) in stations.enumerated() {
            params["scale_station_\(index)_position"] = station.position
            params["scale_station_\(index)_factor"] = station.scale
        }
    }

    private static func storeSweepOrientation(_ mode: CADSweepFrameMode, upDirection: SIMD3<Double>, guidePoints: [SIMD3<Double>], in params: inout [String: Double]) throws {
        guard guidePoints.isEmpty || (2...12).contains(guidePoints.count),
              guidePoints.flatMap({ [$0.x, $0.y, $0.z] }).allSatisfy(\.isFinite),
              mode != .fixedUp || simd_length(upDirection) > 0.000_001 else { throw CADValidationError.invalidValue }
        params["frame_mode"] = Double(mode.rawValue)
        params["up_x"] = upDirection.x; params["up_y"] = upDirection.y; params["up_z"] = upDirection.z
        params["guide_point_count"] = Double(guidePoints.count)
        for (index, point) in guidePoints.enumerated() {
            params["guide_\(index)_x"] = point.x; params["guide_\(index)_y"] = point.y; params["guide_\(index)_z"] = point.z
        }
    }

    private static func storeSweepTangents(_ startTangent: SIMD3<Double>?, endTangent: SIMD3<Double>?, in params: inout [String: Double]) throws {
        params["tangent_mode"] = Double((startTangent == nil ? 0 : 1) | (endTangent == nil ? 0 : 2))
        for (prefix, tangent) in [("start", startTangent), ("end", endTangent)] {
            guard let tangent else { continue }
            guard [tangent.x, tangent.y, tangent.z].allSatisfy(\.isFinite), simd_length(tangent) > 0.000_001 else { throw CADValidationError.invalidValue }
            params["\(prefix)_tangent_x"] = tangent.x; params["\(prefix)_tangent_y"] = tangent.y; params["\(prefix)_tangent_z"] = tangent.z
        }
    }

    private static func sweepPathControlError(_ params: [String: Double]) -> String? {
        if params["path_point_count"] != nil {
            let modeValue = params["tangent_mode"] ?? 0
            guard modeValue.rounded() == modeValue, (0...3).contains(Int(modeValue)) else { return "has an invalid spline tangent mode" }
            let mode = Int(modeValue)
            for (prefix, bit) in [("start", 1), ("end", 2)] where mode & bit != 0 {
                let tangent = SIMD3(params["\(prefix)_tangent_x"] ?? .nan, params["\(prefix)_tangent_y"] ?? .nan, params["\(prefix)_tangent_z"] ?? .nan)
                guard [tangent.x, tangent.y, tangent.z].allSatisfy(\.isFinite), simd_length(tangent) > 0.000_001 else { return "\(prefix) tangent must be finite and nonzero" }
            }
        }
        if params["path_segment_count"] != nil {
            let modeValue = params["continuity_mode"] ?? 0, tolerance = params["tangent_tolerance"] ?? 1
            guard modeValue.rounded() == modeValue, (0...2).contains(Int(modeValue)), tolerance.isFinite, (0...90).contains(tolerance) else { return "has invalid composite continuity controls" }
        }
        return nil
    }

    private static func sweepOrientationError(_ params: [String: Double]) -> String? {
        let mode = params["frame_mode"] ?? 0
        guard mode.rounded() == mode, (0...2).contains(Int(mode)) else { return "has an invalid sweep orientation mode" }
        let up = SIMD3(params["up_x"] ?? 0, params["up_y"] ?? 0, params["up_z"] ?? 1)
        if mode == 2, simd_length(up) <= 0.000_001 { return "needs a nonzero fixed-up direction" }
        let countValue = params["guide_point_count"] ?? 0
        guard countValue.rounded() == countValue else { return "has an invalid guide rail point count" }
        let count = Int(countValue)
        guard count == 0 || (2...12).contains(count) else { return "guide rail needs 2 to 12 points" }
        for index in 0..<count {
            guard [params["guide_\(index)_x"], params["guide_\(index)_y"], params["guide_\(index)_z"]]
                .allSatisfy({ $0?.isFinite == true }) else { return "guide rail point \(index + 1) is incomplete" }
        }
        return nil
    }

    private static func storeSweepProfileSections(_ sections: [CADSweepProfileSection], in params: inout [String: Double]) {
        guard !sections.isEmpty else { return }
        params["profile_station_count"] = Double(sections.count)
        for (index, section) in sections.enumerated() {
            params["profile_station_\(index)_position"] = section.position
        }
    }

    private static func sweepProfileStationError(_ params: [String: Double]) -> String? {
        guard let rawCount = params["profile_station_count"] else { return nil }
        guard rawCount.rounded() == rawCount, (1...8).contains(Int(rawCount)) else { return "requires 1 to 8 morph profile stations" }
        var previous = 0.0
        for index in 0..<Int(rawCount) {
            let position = params["profile_station_\(index)_position"] ?? .nan
            guard position.isFinite, position > previous, position <= 1 else { return "profile station \(index + 1) needs an increasing position inside 0…1" }
            previous = position
        }
        guard abs(previous - 1) <= 0.000_001 else { return "the final morph profile station must be at path position 1" }
        return nil
    }

    private static func sweepScaleStationError(_ params: [String: Double]) -> String? {
        guard let rawCount = params["scale_station_count"] else { return nil }
        guard rawCount.rounded() == rawCount, (1...8).contains(Int(rawCount)) else { return "requires 1 to 8 scale stations when variable scaling is enabled" }
        var previous = 0.0
        for index in 0..<Int(rawCount) {
            let position = params["scale_station_\(index)_position"] ?? .nan
            let scale = params["scale_station_\(index)_factor"] ?? .nan
            guard position.isFinite, scale.isFinite, position > previous, position < 1, scale > 0 else { return "scale station \(index + 1) needs an increasing position inside 0…1 and a positive scale" }
            previous = position
        }
        return nil
    }

    private static func compositePathError(_ params: [String: Double]) -> String? {
        guard let rawCount = params["path_segment_count"], rawCount.rounded() == rawCount, (1...12).contains(Int(rawCount)) else { return "requires 1 to 12 guide segments" }
        let point: (Int, String) -> SIMD3<Double> = { index, role in
            SIMD3(params["path_\(index)_\(role)_x"] ?? .nan, params["path_\(index)_\(role)_y"] ?? .nan, params["path_\(index)_\(role)_z"] ?? .nan)
        }
        var previousEnd: SIMD3<Double>?
        var segments: [(kind: Double, start: SIMD3<Double>, mid: SIMD3<Double>?, end: SIMD3<Double>)] = []
        for index in 0..<Int(rawCount) {
            guard let kind = params["path_\(index)_kind"], kind == 0 || kind == 1 else { return "segment \(index + 1) has an invalid type" }
            let start = point(index, "start"), end = point(index, "end")
            guard [start.x, start.y, start.z, end.x, end.y, end.z].allSatisfy(\.isFinite) else { return "segment \(index + 1) is incomplete" }
            if let previousEnd, simd_distance(previousEnd, start) > 0.000_001 { return "segment \(index + 1) is disconnected" }
            if kind == 0 {
                if simd_distance(start, end) < 0.000_001 { return "line \(index + 1) has zero length" }
            } else {
                let mid = point(index, "mid")
                guard [mid.x, mid.y, mid.z].allSatisfy(\.isFinite), simd_distance(start, mid) > 0.000_001, simd_distance(mid, end) > 0.000_001,
                      simd_length(simd_cross(mid - start, end - start)) > 0.000_000_01 else { return "arc \(index + 1) needs three distinct non-collinear points" }
                segments.append((kind, start, mid, end))
            }
            if kind == 0 { segments.append((kind, start, nil, end)) }
            previousEnd = end
        }
        if let controlError = sweepPathControlError(params) { return controlError }
        let continuity = Int((params["continuity_mode"] ?? 0).rounded())
        guard continuity > 0 else { return nil }
        let arcGeometry: ((kind: Double, start: SIMD3<Double>, mid: SIMD3<Double>?, end: SIMD3<Double>)) -> (center: SIMD3<Double>, radius: Double)? = { segment in
            guard let mid = segment.mid else { return nil }
            let u = mid - segment.start, v = segment.end - segment.start, normal = simd_cross(u, v), normalSquared = simd_length_squared(normal)
            let center = segment.start + (simd_length_squared(u) * simd_cross(v, normal) + simd_length_squared(v) * simd_cross(normal, u)) / (2 * normalSquared)
            return (center, simd_distance(segment.start, center))
        }
        let tangent: ((kind: Double, start: SIMD3<Double>, mid: SIMD3<Double>?, end: SIMD3<Double>), Bool) -> SIMD3<Double> = { segment, atEnd in
            if segment.kind == 0 { return simd_normalize(segment.end - segment.start) }
            let geometry = arcGeometry(segment)!, normal = simd_normalize(simd_cross(segment.mid! - segment.start, segment.end - segment.start))
            return simd_normalize(simd_cross(normal, (atEnd ? segment.end : segment.start) - geometry.center))
        }
        let curvature: ((kind: Double, start: SIMD3<Double>, mid: SIMD3<Double>?, end: SIMD3<Double>), Bool) -> SIMD3<Double> = { segment, atEnd in
            guard let geometry = arcGeometry(segment) else { return .zero }
            return (geometry.center - (atEnd ? segment.end : segment.start)) / (geometry.radius * geometry.radius)
        }
        let tolerance = params["tangent_tolerance"] ?? 1
        for index in 1..<segments.count {
            let dot = max(-1, min(1, simd_dot(tangent(segments[index - 1], true), tangent(segments[index], false))))
            let angle = acos(dot) * 180 / .pi
            if angle > tolerance + 0.000_000_001 { return "segment \(index + 1) join is not G1 (\(angle.formatted(.number.precision(.fractionLength(3))))° mismatch)" }
            if continuity == 2 {
                let left = curvature(segments[index - 1], true), right = curvature(segments[index], false)
                if simd_length(left - right) > max(max(simd_length(left), simd_length(right)), 1) * 0.000_01 { return "segment \(index + 1) join is not G2" }
            }
        }
        return nil
    }

    private static func validationErrors(in document: CADDocument) -> [String] {
        var errors: [String] = []
        var ids = Set<String>()
        for feature in document.features {
            if !ids.insert(feature.id).inserted { errors.append("Duplicate feature ID: \(feature.id)") }
            for (key, value) in feature.params {
                let signedParameters: Set<String> = ["x", "y", "z", "rotation_x", "rotation_y", "rotation_z", "angle", "spin", "axial_offset", "origin_x", "origin_y", "origin_z", "direction_x", "direction_y", "direction_z", "axis_x", "axis_y", "axis_z", "start_x", "start_y", "start_z", "end_x", "end_y", "end_z", "twist_angle", "offset", "distance", "symmetric", "closed", "selector_mode", "selector_x", "selector_y", "selector_z", "selector_face_id", "selector_edge_id", "selector_edge_face_a", "selector_edge_face_b", "mate_type", "fixed", "opposed", "offset_x", "offset_y", "offset_z"]
                let isSigned = signedParameters.contains(key) || key.contains("_anchor_") || key.contains("_normal_") || key.contains("_axis_") || key.contains("_tangent_") || key.hasPrefix("guide_") || key.hasPrefix("up_") || ["frame_mode", "tangent_mode", "continuity_mode", "tangent_tolerance"].contains(key) || (key.hasPrefix("path_") && key != "path_point_count")
                if !value.isFinite || (!isSigned && value <= 0) {
                    errors.append("\(feature.name).\(key) has an invalid value")
                }
            }
            let required: [String] = switch feature.kind {
            case "box": ["width", "height", "depth", "x", "y", "z"]
            case "cylinder": ["radius", "height", "x", "y", "z"]
            case "cone": ["radius_bottom", "radius_top", "height", "x", "y", "z"]
            case "sphere": ["radius", "x", "y", "z"]
            case "torus": ["major_radius", "tube_radius", "x", "y", "z"]
            case "edge_fillet": ["radius"]
            case "edge_chamfer": ["distance"]
            case "shell_feature": ["thickness"]
            case "linear_pattern": ["direction_x", "direction_y", "direction_z", "count", "spacing"]
            case "circular_pattern": ["origin_x", "origin_y", "origin_z", "axis_x", "axis_y", "axis_z", "count", "angle"]
            case "body_transform": ["x", "y", "z", "rotation_x", "rotation_y", "rotation_z", "scale_x", "scale_y", "scale_z"]
            case "assembly_instance": ["x", "y", "z", "rotation_x", "rotation_y", "rotation_z", "scale_x", "scale_y", "scale_z", "fixed"]
            case "assembly_mate": ["mate_type"]
            case "imported_step": ["body_number"]
            case "extrude_feature", "pocket_feature": ["length", "symmetric"]
            case "revolve_feature": ["angle", "axis_x", "axis_y", "axis_z", "origin_x", "origin_y", "origin_z"]
            case "sweep_feature": feature.params["path_segment_count"] != nil ? ["path_segment_count", "twist_angle", "scale_start", "scale_end"] : feature.params["path_point_count"] != nil ? ["path_point_count", "twist_angle", "scale_start", "scale_end"] : feature.params["helix_radius"] == nil ? ["start_x", "start_y", "start_z", "end_x", "end_y", "end_z", "twist_angle", "scale_start", "scale_end"] : ["helix_radius", "helix_pitch", "helix_turns", "twist_angle", "scale_start", "scale_end"]
            case "loft_feature": ["closed"]
            default: []
            }
            let missing = required.filter { feature.params[$0] == nil }
            if !missing.isEmpty { errors.append("\(feature.name) is missing \(missing.joined(separator: ", "))") }
            if feature.kind == "torus", (feature.params["major_radius"] ?? 0) <= (feature.params["tube_radius"] ?? 0) {
                errors.append("\(feature.name) major radius must exceed its tube radius")
            }
            if feature.kind == "profile_sketch" { errors.append(contentsOf: CADProfileSketch.solve(feature: feature).errors) }
            if feature.kind == "imported_step", feature.assetPath == nil || !FileManager.default.fileExists(atPath: feature.assetPath ?? "") { errors.append("\(feature.name) STEP asset is missing") }
            if ["extrude_feature", "pocket_feature"].contains(feature.kind), ![0, 1].contains(feature.params["symmetric"] ?? -1) { errors.append("\(feature.name) symmetric must be on or off") }
            if feature.kind == "revolve_feature" {
                let angle = feature.params["angle"] ?? 0
                if angle <= 0 || angle > 360 { errors.append("\(feature.name) angle must be greater than 0 and no more than 360 degrees") }
                let axisLength = sqrt(pow(feature.params["axis_x"] ?? 0, 2) + pow(feature.params["axis_y"] ?? 0, 2) + pow(feature.params["axis_z"] ?? 0, 2))
                if axisLength < 0.000_001 { errors.append("\(feature.name) axis cannot be zero") }
            }
            if feature.kind == "sweep_feature", feature.params["helix_radius"] == nil {
                if feature.params["path_segment_count"] != nil {
                    if let error = compositePathError(feature.params) { errors.append("\(feature.name) \(error)") }
                } else if let rawCount = feature.params["path_point_count"] {
                    let count = Int(rawCount)
                    if rawCount.rounded() != rawCount || count < 2 || count > 12 { errors.append("\(feature.name) spline guide requires 2 to 12 points") }
                    let points: [SIMD3<Double>] = (0..<max(0, count)).map { index in SIMD3(feature.params["path_\(index)_x"] ?? .nan, feature.params["path_\(index)_y"] ?? .nan, feature.params["path_\(index)_z"] ?? .nan) }
                    if points.flatMap({ [$0.x, $0.y, $0.z] }).contains(where: { !$0.isFinite }) { errors.append("\(feature.name) spline guide is incomplete") }
                    else if !zip(points, points.dropFirst()).contains(where: { simd_distance($0, $1) > 0.000_001 }) { errors.append("\(feature.name) spline guide cannot have zero length") }
                } else {
                    let dx = (feature.params["end_x"] ?? 0) - (feature.params["start_x"] ?? 0)
                    let dy = (feature.params["end_y"] ?? 0) - (feature.params["start_y"] ?? 0)
                    let dz = (feature.params["end_z"] ?? 0) - (feature.params["start_z"] ?? 0)
                    if sqrt(dx * dx + dy * dy + dz * dz) < 0.000_001 { errors.append("\(feature.name) path cannot have zero length") }
                }
            }
            if feature.kind == "sweep_feature", let error = sweepScaleStationError(feature.params) { errors.append("\(feature.name) \(error)") }
            if feature.kind == "sweep_feature" {
                if let error = sweepOrientationError(feature.params) { errors.append("\(feature.name) \(error)") }
                if let error = sweepPathControlError(feature.params) { errors.append("\(feature.name) \(error)") }
                if let error = sweepProfileStationError(feature.params) { errors.append("\(feature.name) \(error)") }
                let expectedInputs = Int(feature.params["profile_station_count"] ?? 0) + 1
                if (feature.inputFeatureIds ?? []).count != expectedInputs { errors.append("\(feature.name) profile stations do not match its sketch inputs") }
            }
            if feature.kind == "loft_feature" {
                if ![0, 1].contains(feature.params["closed"] ?? -1) { errors.append("\(feature.name) closed must be on or off") }
                if (feature.inputFeatureIds ?? []).count < 2 { errors.append("\(feature.name) requires at least two profile sketches") }
            }
            if feature.kind == "assembly_instance" {
                if ![0, 1].contains(feature.params["fixed"] ?? -1) { errors.append("\(feature.name) fixed state must be on or off") }
                if feature.inputFeatureIds?.count != 1 { errors.append("\(feature.name) requires exactly one source part") }
            }
            if feature.kind == "assembly_mate" {
                let type = feature.params["mate_type"] ?? -1, expectedInputs = type == 0 ? 1 : 2
                if ![0, 1, 2, 3, 4, 5].contains(type) { errors.append("\(feature.name) has an invalid mate type") }
                if feature.inputFeatureIds?.count != expectedInputs { errors.append("\(feature.name) has invalid mate references") }
                if [1, 2, 3, 4].contains(type) {
                    let keys = ["reference_anchor_x", "reference_anchor_y", "reference_anchor_z", "moving_anchor_x", "moving_anchor_y", "moving_anchor_z"] + (type == 1 ? ["offset_x", "offset_y", "offset_z"] : type == 2 ? ["axis_x", "axis_y", "axis_z", "distance"] : type == 3 ? ["reference_normal_x", "reference_normal_y", "reference_normal_z", "moving_normal_x", "moving_normal_y", "moving_normal_z", "distance", "opposed", "spin"] : ["reference_axis_x", "reference_axis_y", "reference_axis_z", "moving_axis_x", "moving_axis_y", "moving_axis_z", "axial_offset", "opposed", "spin"])
                    if !keys.allSatisfy({ feature.params[$0]?.isFinite == true }) { errors.append("\(feature.name) has incomplete anchor coordinates") }
                    if type == 2, simd_length(SIMD3(feature.params["axis_x"] ?? 0, feature.params["axis_y"] ?? 0, feature.params["axis_z"] ?? 0)) < 0.000_001 { errors.append("\(feature.name) distance axis cannot be zero") }
                    if type == 2, (feature.params["distance"] ?? 0) <= 0 { errors.append("\(feature.name) distance must be positive") }
                    if type == 3, ![0, 1].contains(feature.params["opposed"] ?? -1) { errors.append("\(feature.name) opposed must be on or off") }
                    if type == 3, (feature.params["distance"] ?? -1) < 0 { errors.append("\(feature.name) plane offset cannot be negative") }
                    if type == 3, simd_length(SIMD3(feature.params["reference_normal_x"] ?? 0, feature.params["reference_normal_y"] ?? 0, feature.params["reference_normal_z"] ?? 0)) < 0.000_001 || simd_length(SIMD3(feature.params["moving_normal_x"] ?? 0, feature.params["moving_normal_y"] ?? 0, feature.params["moving_normal_z"] ?? 0)) < 0.000_001 { errors.append("\(feature.name) plane normals cannot be zero") }
                    if type == 4, ![0, 1].contains(feature.params["opposed"] ?? -1) { errors.append("\(feature.name) opposed must be on or off") }
                    if type == 4, simd_length(SIMD3(feature.params["reference_axis_x"] ?? 0, feature.params["reference_axis_y"] ?? 0, feature.params["reference_axis_z"] ?? 0)) < 0.000_001 || simd_length(SIMD3(feature.params["moving_axis_x"] ?? 0, feature.params["moving_axis_y"] ?? 0, feature.params["moving_axis_z"] ?? 0)) < 0.000_001 { errors.append("\(feature.name) concentric axes cannot be zero") }
                }
                if type == 5 {
                    let referenceNormal = SIMD3(feature.params["reference_normal_x"] ?? 0, feature.params["reference_normal_y"] ?? 0, feature.params["reference_normal_z"] ?? 0)
                    let movingNormal = SIMD3(feature.params["moving_normal_x"] ?? 0, feature.params["moving_normal_y"] ?? 0, feature.params["moving_normal_z"] ?? 0)
                    let hingeAxis = SIMD3(feature.params["hinge_axis_x"] ?? 0, feature.params["hinge_axis_y"] ?? 0, feature.params["hinge_axis_z"] ?? 0)
                    if ![referenceNormal.x, referenceNormal.y, referenceNormal.z, movingNormal.x, movingNormal.y, movingNormal.z, hingeAxis.x, hingeAxis.y, hingeAxis.z, feature.params["angle"] ?? .nan, feature.params["spin"] ?? .nan].allSatisfy(\.isFinite) { errors.append("\(feature.name) angle definition is incomplete") }
                    if simd_length(referenceNormal) < 0.000_001 || simd_length(movingNormal) < 0.000_001 || simd_length(hingeAxis) < 0.000_001 || simd_length(simd_cross(referenceNormal, hingeAxis)) < 0.000_001 { errors.append("\(feature.name) angle vectors are invalid") }
                    if (feature.params["angle"] ?? -1) < 0 || (feature.params["angle"] ?? 181) > 180 { errors.append("\(feature.name) angle must be between 0 and 180 degrees") }
                }
            }
            if ["linear_pattern", "circular_pattern"].contains(feature.kind) {
                let count = feature.params["count"] ?? 0
                if count < 2 || count.rounded() != count { errors.append("\(feature.name) count must be a whole number of at least 2") }
            }
            if ["edge_fillet", "edge_chamfer"].contains(feature.kind), let mode = feature.params["selector_mode"] {
                if ![0, 1, 2, 3].contains(mode) { errors.append("\(feature.name) edge selector mode is invalid") }
                if mode > 0, ["selector_x", "selector_y", "selector_z"].contains(where: { feature.params[$0] == nil }) { errors.append("\(feature.name) edge selector is incomplete") }
                if mode == 2, sqrt(pow(feature.params["selector_x"] ?? 0, 2) + pow(feature.params["selector_y"] ?? 0, 2) + pow(feature.params["selector_z"] ?? 0, 2)) < 0.000_001 { errors.append("\(feature.name) edge direction cannot be zero") }
                if let faceId = feature.params["selector_face_id"], faceId < 0 || faceId.rounded() != faceId { errors.append("\(feature.name) BRep face selector is invalid") }
                if mode == 3, ["selector_edge_id", "selector_edge_face_a", "selector_edge_face_b"].contains(where: { key in guard let value = feature.params[key] else { return true }; return value < 0 || value.rounded() != value }) { errors.append("\(feature.name) stable BRep edge selector is invalid") }
            }
            if feature.kind == "linear_pattern" {
                let length = sqrt(pow(feature.params["direction_x"] ?? 0, 2) + pow(feature.params["direction_y"] ?? 0, 2) + pow(feature.params["direction_z"] ?? 0, 2))
                if length < 0.000_001 { errors.append("\(feature.name) direction cannot be zero") }
            }
            if feature.kind == "circular_pattern" {
                let length = sqrt(pow(feature.params["axis_x"] ?? 0, 2) + pow(feature.params["axis_y"] ?? 0, 2) + pow(feature.params["axis_z"] ?? 0, 2))
                if length < 0.000_001 { errors.append("\(feature.name) axis cannot be zero") }
            }
            for inputId in feature.inputFeatureIds ?? [] where !document.features.contains(where: { $0.id == inputId }) {
                errors.append("\(feature.name) references missing input \(inputId)")
            }
        }
        var visiting = Set<String>(), visited = Set<String>()
        func visit(_ featureId: String) {
            if visiting.contains(featureId) { errors.append("Cyclic feature dependency at \(featureId)"); return }
            if visited.contains(featureId) { return }
            guard let feature = document.features.first(where: { $0.id == featureId }) else { return }
            visiting.insert(featureId); for inputId in feature.inputFeatureIds ?? [] { visit(inputId) }; visiting.remove(featureId); visited.insert(featureId)
        }
        for feature in document.features { visit(feature.id) }
        errors.append(contentsOf: CADKernel.active.validate(document: document))
        return errors
    }

    private static func isMateDriven(_ document: CADDocument, instanceId: String) -> Bool {
        document.features.contains { $0.kind == "assembly_mate" && [1, 2, 3, 4].contains($0.params["mate_type"] ?? -1) && $0.inputFeatureIds?.count == 2 && $0.inputFeatureIds?[1] == instanceId }
    }

    private static func drivingOrientationMate(_ document: CADDocument, instanceId: String) -> CADFeature? {
        document.features.first { $0.kind == "assembly_mate" && [3, 4, 5].contains($0.params["mate_type"] ?? -1) && $0.inputFeatureIds?.count == 2 && $0.inputFeatureIds?[1] == instanceId }
    }

    private static func assemblyMatePathExists(_ document: CADDocument, from: String, to: String, visited: inout Set<String>) -> Bool {
        if from == to { return true }
        if !visited.insert(from).inserted { return false }
        return document.features.filter { $0.kind == "assembly_mate" && [1, 2, 3, 4, 5].contains($0.params["mate_type"] ?? -1) && $0.inputFeatureIds?.first == from }.contains { mate in
            guard let next = mate.inputFeatureIds?.dropFirst().first else { return false }
            return assemblyMatePathExists(document, from: next, to: to, visited: &visited)
        }
    }

    private static func assemblyMatePathExists(_ document: CADDocument, from: String, to: String) -> Bool {
        var visited = Set<String>()
        return assemblyMatePathExists(document, from: from, to: to, visited: &visited)
    }

    private static func rotatedAssemblyOffset(instance: CADFeature, prefix: String, mate: CADFeature) -> SIMD3<Double> {
        let x = (mate.params["\(prefix)_x"] ?? 0) * (instance.params["scale_x"] ?? 1)
        let y = (mate.params["\(prefix)_y"] ?? 0) * (instance.params["scale_y"] ?? 1)
        let z = (mate.params["\(prefix)_z"] ?? 0) * (instance.params["scale_z"] ?? 1)
        let degreesToRadians = Double.pi / 180.0
        let rotationX = (instance.params["rotation_x"] ?? 0) * degreesToRadians
        let rotationY = (instance.params["rotation_y"] ?? 0) * degreesToRadians
        let rotationZ = (instance.params["rotation_z"] ?? 0) * degreesToRadians

        let cosX = cos(rotationX), sinX = sin(rotationX)
        let afterX = SIMD3<Double>(x, y * cosX - z * sinX, y * sinX + z * cosX)
        let cosY = cos(rotationY), sinY = sin(rotationY)
        let afterY = SIMD3<Double>(afterX.x * cosY + afterX.z * sinY, afterX.y, -afterX.x * sinY + afterX.z * cosY)
        let cosZ = cos(rotationZ), sinZ = sin(rotationZ)
        return SIMD3<Double>(afterY.x * cosZ - afterY.y * sinZ, afterY.x * sinZ + afterY.y * cosZ, afterY.z)
    }

    private static func assemblyQuaternion(_ instance: CADFeature) -> simd_quatd {
        let rotation = SIMD3(instance.params["rotation_x"] ?? 0, instance.params["rotation_y"] ?? 0, instance.params["rotation_z"] ?? 0) * (.pi / 180)
        return simd_quatd(angle: rotation.z, axis: SIMD3(0, 0, 1)) * simd_quatd(angle: rotation.y, axis: SIMD3(0, 1, 0)) * simd_quatd(angle: rotation.x, axis: SIMD3(1, 0, 0))
    }

    private static func quaternionFromTo(_ from: SIMD3<Double>, _ to: SIMD3<Double>) -> simd_quatd {
        let a = simd_normalize(from), b = simd_normalize(to), dot = max(-1, min(1, simd_dot(a, b)))
        if dot > 0.999_999 { return simd_quatd(real: 1, imag: .zero) }
        if dot < -0.999_999 {
            let basis = abs(a.x) < 0.8 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
            return simd_quatd(angle: .pi, axis: simd_normalize(simd_cross(a, basis)))
        }
        let cross = simd_cross(a, b), scale = sqrt((1 + dot) * 2)
        return simd_normalize(simd_quatd(real: scale / 2, imag: cross / scale))
    }

    private static func setAssemblyEuler(_ instance: inout CADFeature, quaternion: simd_quatd) {
        let matrix = simd_double3x3(quaternion), sinPitch = max(-1, min(1, -matrix.columns.0.z))
        let rotation = SIMD3(atan2(matrix.columns.1.z, matrix.columns.2.z), asin(sinPitch), atan2(matrix.columns.0.y, matrix.columns.0.x)) * (180 / .pi)
        instance.params["rotation_x"] = rotation.x; instance.params["rotation_y"] = rotation.y; instance.params["rotation_z"] = rotation.z
    }

    private static func solveAssemblyMates(_ document: inout CADDocument) {
        for index in document.features.indices where document.features[index].kind == "assembly_instance" { document.features[index].params["fixed"] = 0 }
        let mates = document.features.filter { $0.kind == "assembly_mate" }
        for mate in mates where mate.params["mate_type"] == 0 {
            if let instanceId = mate.inputFeatureIds?.first, let index = document.features.firstIndex(where: { $0.id == instanceId && $0.kind == "assembly_instance" }) { document.features[index].params["fixed"] = 1 }
        }
        for _ in 0..<max(1, mates.count) {
            for mate in mates where [1, 2, 3, 4, 5].contains(mate.params["mate_type"] ?? -1) && mate.inputFeatureIds?.count == 2 {
                guard let referenceId = mate.inputFeatureIds?.first, let movingId = mate.inputFeatureIds?.last,
                      let reference = document.features.first(where: { $0.id == referenceId && $0.kind == "assembly_instance" }),
                      let movingIndex = document.features.firstIndex(where: { $0.id == movingId && $0.kind == "assembly_instance" }) else { continue }
                var moving = document.features[movingIndex]
                if mate.params["mate_type"] == 5 {
                    let referenceNormal = SIMD3(mate.params["reference_normal_x"] ?? 0, mate.params["reference_normal_y"] ?? 0, mate.params["reference_normal_z"] ?? 0)
                    let movingNormal = SIMD3(mate.params["moving_normal_x"] ?? 0, mate.params["moving_normal_y"] ?? 0, mate.params["moving_normal_z"] ?? 0)
                    let hingeAxis = SIMD3(mate.params["hinge_axis_x"] ?? 0, mate.params["hinge_axis_y"] ?? 0, mate.params["hinge_axis_z"] ?? 0)
                    if simd_length(referenceNormal) > 0.000_001, simd_length(movingNormal) > 0.000_001, simd_length(hingeAxis) > 0.000_001 {
                        let referenceQuaternion = assemblyQuaternion(reference)
                        let referenceWorld = simd_normalize(referenceQuaternion.act(referenceNormal)), hingeWorld = simd_normalize(referenceQuaternion.act(hingeAxis))
                        let target = simd_quatd(angle: (mate.params["angle"] ?? 0) * .pi / 180, axis: hingeWorld).act(referenceWorld)
                        let aligned = quaternionFromTo(movingNormal, target)
                        setAssemblyEuler(&moving, quaternion: simd_quatd(angle: (mate.params["spin"] ?? 0) * .pi / 180, axis: target) * aligned)
                        document.features[movingIndex] = moving
                    }
                    continue
                }
                let referenceOffset = rotatedAssemblyOffset(instance: reference, prefix: "reference_anchor", mate: mate)
                var planeNormal: SIMD3<Double>?
                if [3, 4].contains(mate.params["mate_type"] ?? -1) {
                    let prefix = mate.params["mate_type"] == 4 ? "axis" : "normal"
                    let referenceNormal = SIMD3(mate.params["reference_\(prefix)_x"] ?? 0, mate.params["reference_\(prefix)_y"] ?? 0, mate.params["reference_\(prefix)_z"] ?? 0)
                    let movingNormal = SIMD3(mate.params["moving_\(prefix)_x"] ?? 0, mate.params["moving_\(prefix)_y"] ?? 0, mate.params["moving_\(prefix)_z"] ?? 0)
                    if simd_length(referenceNormal) > 0.000_001, simd_length(movingNormal) > 0.000_001 {
                        let sign = mate.params["opposed"] == 1 ? -1.0 : 1.0
                        let target = simd_normalize(assemblyQuaternion(reference).act(referenceNormal)) * sign
                        let aligned = quaternionFromTo(movingNormal, target)
                        setAssemblyEuler(&moving, quaternion: simd_quatd(angle: (mate.params["spin"] ?? 0) * .pi / 180, axis: target) * aligned)
                        document.features[movingIndex] = moving; planeNormal = target
                    }
                }
                let movingOffset = rotatedAssemblyOffset(instance: moving, prefix: "moving_anchor", mate: mate)
                let displacement: SIMD3<Double>
                if mate.params["mate_type"] == 4 {
                    displacement = (planeNormal ?? .zero) * (mate.params["axial_offset"] ?? 0)
                } else if mate.params["mate_type"] == 3 {
                    displacement = (planeNormal ?? .zero) * (mate.params["distance"] ?? 0)
                } else if mate.params["mate_type"] == 2 {
                    let axis = SIMD3(mate.params["axis_x"] ?? 0, mate.params["axis_y"] ?? 0, mate.params["axis_z"] ?? 0)
                    displacement = simd_length(axis) > 0.000_001 ? simd_normalize(axis) * (mate.params["distance"] ?? 0) : .zero
                } else {
                    displacement = SIMD3(mate.params["offset_x"] ?? 0, mate.params["offset_y"] ?? 0, mate.params["offset_z"] ?? 0)
                }
                document.features[movingIndex].params["x"] = (reference.params["x"] ?? 0) + referenceOffset.x + displacement.x - movingOffset.x
                document.features[movingIndex].params["y"] = (reference.params["y"] ?? 0) + referenceOffset.y + displacement.y - movingOffset.y
                document.features[movingIndex].params["z"] = (reference.params["z"] ?? 0) + referenceOffset.z + displacement.z - movingOffset.z
            }
        }
    }

    private static func defaultMotionRange(parameter: String, mate: CADFeature) -> (Double, Double) {
        switch parameter {
        case "angle": return (0, 180)
        case "distance": return (1, max(25, (mate.params[parameter] ?? 10) * 2))
        case "spin": return (-180, 180)
        default:
            let center = mate.params[parameter] ?? 0
            return (center - 25, center + 25)
        }
    }

    private static func validMotionStudy(_ study: CADMotionStudy?, in document: CADDocument) -> CADMotionStudy? {
        guard var study, [study.minimum, study.maximum, study.progress].allSatisfy(\.isFinite), study.minimum < study.maximum,
              let mate = document.features.first(where: { $0.id == study.mateId && $0.kind == "assembly_mate" && $0.params["mate_type"] != 0 }),
              ["angle", "distance", "axial_offset", "spin", "offset_x", "offset_y", "offset_z"].contains(study.parameter), mate.params[study.parameter] != nil else { return nil }
        if study.parameter == "angle", study.minimum < 0 || study.maximum > 180 { return nil }
        if study.parameter == "distance", mate.params["mate_type"] == 2, study.minimum <= 0 { return nil }
        if study.parameter == "distance", mate.params["mate_type"] == 3, study.minimum < 0 { return nil }
        study.progress = min(1, max(0, study.progress)); return study
    }

    private static func migrated(_ source: CADDocument) -> CADDocument {
        var result = source
        if let index = result.features.firstIndex(where: { $0.id == "sketch-base" }), result.features[index].sketch == nil {
            result.features[index].sketch = .mountingPlate
        }
        for index in result.features.indices where ["body_transform", "assembly_instance"].contains(result.features[index].kind) {
            for key in ["scale_x", "scale_y", "scale_z"] where result.features[index].params[key] == nil {
                result.features[index].params[key] = 1
            }
            if result.features[index].kind == "assembly_instance", result.features[index].params["fixed"] == nil { result.features[index].params["fixed"] = 0 }
        }
        for index in result.features.indices where result.features[index].kind == "sweep_feature" {
            if result.features[index].params["frame_mode"] == nil { result.features[index].params["frame_mode"] = 0 }
            if result.features[index].params["up_x"] == nil { result.features[index].params["up_x"] = 0 }
            if result.features[index].params["up_y"] == nil { result.features[index].params["up_y"] = 0 }
            if result.features[index].params["up_z"] == nil { result.features[index].params["up_z"] = 1 }
            if result.features[index].params["guide_point_count"] == nil { result.features[index].params["guide_point_count"] = 0 }
            if let countValue = result.features[index].params["path_point_count"] {
                let count = Int(countValue.rounded())
                if result.features[index].params["tangent_mode"] == nil { result.features[index].params["tangent_mode"] = 0 }
                if count >= 2 {
                    for (prefix, first, second) in [("start", 0, 1), ("end", count - 2, count - 1)] {
                        for axis in ["x", "y", "z"] where result.features[index].params["\(prefix)_tangent_\(axis)"] == nil {
                            result.features[index].params["\(prefix)_tangent_\(axis)"] = 0.5 * ((result.features[index].params["path_\(second)_\(axis)"] ?? 0) - (result.features[index].params["path_\(first)_\(axis)"] ?? 0))
                        }
                    }
                }
            }
            if result.features[index].params["path_segment_count"] != nil {
                if result.features[index].params["continuity_mode"] == nil { result.features[index].params["continuity_mode"] = 0 }
                if result.features[index].params["tangent_tolerance"] == nil { result.features[index].params["tangent_tolerance"] = 1 }
            }
        }
        solveAssemblyMates(&result)
        return result
    }

    private func beginMutation() {
        selectedSurface = nil
        measurementProbe = nil
        clearanceResult = nil
        isMeasuring = false
        motionStudy = nil
        syncMotionTimer()
        try? persistView()
        undoStack.append(document)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll(keepingCapacity: true)
    }

    private func persist() throws {
        Self.solveAssemblyMates(&document)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try encoder.encode(document).write(to: documentURL, options: [.atomic])
        knownModificationDate = (try? FileManager.default.attributesOfItem(atPath: documentURL.path)[.modificationDate]) as? Date
        try? persistSelection()
        scheduleKernelRefresh()
    }

    private func persistSelection() throws {
        let selection = CADSelectionState(revision: document.revision, featureIds: selectedFeatureId.map { [$0] } ?? [], surface: selectedSurface)
        try encoder.encode(selection).write(to: selectionURL, options: [.atomic])
    }

    private func persistView() throws {
        try encoder.encode(CADViewState(section: sectionPlane, measurement: measurementProbe, isolatedFeatureId: isolatedFeatureId, explodedDistance: explodedDistance, motionStudy: motionStudy)).write(to: viewURL, options: [.atomic])
        knownViewModificationDate = (try? FileManager.default.attributesOfItem(atPath: viewURL.path)[.modificationDate]) as? Date
    }

    private func rememberDocument(_ url: URL) {
        let path = url.standardizedFileURL.path
        recentDocumentPaths.removeAll { $0 == path }; recentDocumentPaths.insert(path, at: 0)
        if recentDocumentPaths.count > 8 { recentDocumentPaths.removeLast(recentDocumentPaths.count - 8) }
        try? encoder.encode(recentDocumentPaths).write(to: recentsURL, options: [.atomic])
    }

    private func persistProjectSession() {
        let session = ProjectSession(path: projectURL?.path, savedRevision: lastSavedRevision)
        try? encoder.encode(session).write(to: projectSessionURL, options: [.atomic])
    }

    private func syncMotionTimer() {
        motionTimer?.invalidate(); motionTimer = nil
        guard motionStudy?.playing == true else { return }
        motionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceMotion() }
        }
    }

    private func firstNumber(in text: String) -> Double? {
        guard let range = text.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression) else { return nil }
        return Double(text[range])
    }

    private static func meshVolume(_ mesh: CADKernelRenderMesh) -> Double {
        guard mesh.indices.count >= 3 else { return 0 }
        var signed = 0.0
        for index in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let ia = Int(mesh.indices[index]) * 3, ib = Int(mesh.indices[index + 1]) * 3, ic = Int(mesh.indices[index + 2]) * 3
            guard ic + 2 < mesh.positions.count else { continue }
            let a = SIMD3<Double>(Double(mesh.positions[ia]), Double(mesh.positions[ia + 1]), Double(mesh.positions[ia + 2]))
            let b = SIMD3<Double>(Double(mesh.positions[ib]), Double(mesh.positions[ib + 1]), Double(mesh.positions[ib + 2]))
            let c = SIMD3<Double>(Double(mesh.positions[ic]), Double(mesh.positions[ic + 1]), Double(mesh.positions[ic + 2]))
            signed += simd_dot(a, simd_cross(b, c)) / 6
        }
        return abs(signed)
    }

    private func isValidParameter(key: String, value: Double) -> Bool {
        guard value.isFinite else { return false }
        let signedParameters: Set<String> = ["x", "y", "z", "rotation_x", "rotation_y", "rotation_z", "angle", "spin", "axial_offset", "origin_x", "origin_y", "origin_z", "direction_x", "direction_y", "direction_z", "axis_x", "axis_y", "axis_z", "start_x", "start_y", "start_z", "end_x", "end_y", "end_z", "twist_angle", "offset", "distance", "symmetric", "closed", "selector_mode", "selector_x", "selector_y", "selector_z", "selector_face_id", "selector_edge_id", "selector_edge_face_a", "selector_edge_face_b", "mate_type", "fixed", "opposed", "offset_x", "offset_y", "offset_z"]
        return signedParameters.contains(key) || key.contains("_anchor_") || key.contains("_normal_") || key.contains("_axis_") || (key.hasPrefix("path_") && key != "path_point_count") || value > 0
    }

    private func format(_ value: Double) -> String { value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value) }

    private static func suppressedIds(for featureId: String) -> [String] {
        ["sketch-base", "pad-base", "pocket-holes", "fillet-edges"].contains(featureId)
            ? ["sketch-base", "pad-base", "pocket-holes", "fillet-edges"] : [featureId]
    }
}
