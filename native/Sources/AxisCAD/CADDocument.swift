import Foundation

enum CADMaterialPreset: Int, CaseIterable, Identifiable, Sendable {
    case unassigned = 0, aluminum6061, mildSteel, stainlessSteel, titanium, abs
    var id: Int { rawValue }
    var name: String { switch self { case .unassigned: "Unassigned"; case .aluminum6061: "Aluminum 6061"; case .mildSteel: "Mild steel"; case .stainlessSteel: "Stainless steel"; case .titanium: "Titanium"; case .abs: "ABS plastic" } }
    var density: Double { switch self { case .unassigned: 0; case .aluminum6061: 0.00270; case .mildSteel: 0.00785; case .stainlessSteel: 0.00800; case .titanium: 0.00443; case .abs: 0.00104 } }
    var color: SIMD3<Float> { switch self { case .unassigned: SIMD3(0.73, 0.55, 0.93); case .aluminum6061: SIMD3(0.72, 0.76, 0.80); case .mildSteel: SIMD3(0.34, 0.39, 0.43); case .stainlessSteel: SIMD3(0.58, 0.64, 0.68); case .titanium: SIMD3(0.48, 0.52, 0.58); case .abs: SIMD3(0.15, 0.18, 0.22) } }
    static func resolve(_ feature: CADFeature?) -> CADMaterialPreset { CADMaterialPreset(rawValue: Int(feature?.params["material_id"] ?? 0)) ?? .unassigned }
}

struct CADAssemblyMassSummary: Equatable, Sendable {
    var assignedInstanceCount: Int
    var totalInstanceCount: Int
    var totalMassGrams: Double
}

struct CADCheckpointSummary: Identifiable, Equatable, Sendable {
    var id: String { path }
    var path: String
    var name: String
    var revision: Int
}

struct CADFeature: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var kind: String
    var visible: Bool
    var params: [String: Double]
    var sketch: CADSketchDefinition? = nil
    var inputFeatureIds: [String]? = nil
    var assetPath: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, kind, visible, params, sketch
        case inputFeatureIds = "input_feature_ids"
        case assetPath = "asset_path"
    }
}

struct CADSketchDefinition: Codable, Equatable, Sendable {
    var plane: String
    var profile: String
    var constraints: [CADSketchConstraint]
    var entities: [CADSketchEntity]? = nil

    static let mountingPlate = CADSketchDefinition(
        plane: "XY",
        profile: "centered-rectangle-four-holes",
        constraints: [
            .init(id: "origin", kind: "coincident", entities: ["profile-center", "origin"]),
            .init(id: "top-horizontal", kind: "horizontal", entities: ["edge-top"]),
            .init(id: "bottom-horizontal", kind: "horizontal", entities: ["edge-bottom"]),
            .init(id: "left-vertical", kind: "vertical", entities: ["edge-left"]),
            .init(id: "right-vertical", kind: "vertical", entities: ["edge-right"]),
            .init(id: "profile-width", kind: "distance", entities: ["edge-left", "edge-right"], parameter: "width"),
            .init(id: "profile-height", kind: "distance", entities: ["edge-bottom", "edge-top"], parameter: "height"),
            .init(id: "equal-holes", kind: "equal", entities: ["hole-nw", "hole-ne", "hole-sw", "hole-se"], parameter: "diameter"),
            .init(id: "symmetric-holes-x", kind: "symmetric", entities: ["hole-nw", "hole-ne", "hole-sw", "hole-se", "axis-y"]),
            .init(id: "symmetric-holes-y", kind: "symmetric", entities: ["hole-nw", "hole-ne", "hole-sw", "hole-se", "axis-x"]),
            .init(id: "hole-edge-offset", kind: "distance", entities: ["profile", "holes"], parameter: "offset")
        ]
    )
}

struct CADSketchEntity: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var kind: String
    var params: [String: Double]
    var construction: Bool = false
    var loopId: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, kind, params, construction
        case loopId = "loop_id"
    }

    var profileLoopId: String { loopId ?? "outer" }
}

struct CADSketchConstraint: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var kind: String
    var entities: [String]
    var parameter: String? = nil
    var value: Double? = nil
}

struct CADOperation: Codable, Identifiable, Equatable, Sendable {
    var operationId: String
    var author: String
    var kind: String
    var featureId: String?
    var parameter: String?
    var previousValue: Double?
    var value: Double?
    var revision: Int
    var timestamp: String

    var id: String { operationId }

    enum CodingKeys: String, CodingKey {
        case operationId = "operation_id"
        case author, kind
        case featureId = "feature_id"
        case parameter
        case previousValue = "previous_value"
        case value, revision, timestamp
    }
}

struct CADSelectionState: Codable, Equatable, Sendable {
    var revision: Int
    var featureIds: [String]
    var surface: CADSelectionSurface? = nil

    enum CodingKeys: String, CodingKey {
        case revision, surface
        case featureIds = "feature_ids"
    }
}

struct CADSelectionVector: Codable, Equatable, Sendable {
    var x: Float
    var y: Float
    var z: Float
}

struct CADSelectionSurface: Codable, Equatable, Sendable {
    var featureId: String
    var triangleIndex: Int
    var position: CADSelectionVector
    var normal: CADSelectionVector
    var topologyFaceId: Int? = nil
    var topologyEdgeId: Int? = nil
    var topologyEdgeFaceIds: [Int]? = nil

    enum CodingKeys: String, CodingKey {
        case featureId = "feature_id"
        case triangleIndex = "triangle_index"
        case topologyFaceId = "topology_face_id"
        case topologyEdgeId = "topology_edge_id"
        case topologyEdgeFaceIds = "topology_edge_face_ids"
        case position, normal
    }
}

struct CADSectionPlane: Codable, Equatable, Sendable {
    var axis: String
    var offset: Double
    var flipped: Bool
}

struct CADMeasurementProbe: Codable, Equatable, Sendable {
    var revision: Int
    var start: CADSelectionVector
    var end: CADSelectionVector?

    var delta: CADSelectionVector? {
        guard let end else { return nil }
        return CADSelectionVector(x: end.x - start.x, y: end.y - start.y, z: end.z - start.z)
    }

    var distance: Double? {
        guard let delta else { return nil }
        return sqrt(Double(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z))
    }
}

struct CADMotionStudy: Codable, Equatable, Sendable {
    var mateId: String
    var parameter: String
    var minimum: Double
    var maximum: Double
    var progress: Double
    var playing: Bool

    var value: Double { minimum + (maximum - minimum) * min(1, max(0, progress)) }

    enum CodingKeys: String, CodingKey {
        case parameter, minimum, maximum, progress, playing
        case mateId = "mate_id"
    }
}

struct CADViewState: Codable, Equatable, Sendable {
    var section: CADSectionPlane?
    var measurement: CADMeasurementProbe? = nil
    var isolatedFeatureId: String? = nil
    var explodedDistance: Double? = nil
    var motionStudy: CADMotionStudy? = nil

    enum CodingKeys: String, CodingKey {
        case section, measurement
        case isolatedFeatureId = "isolated_feature_id"
        case explodedDistance = "exploded_distance"
        case motionStudy = "motion_study"
        case legacyIsolatedFeatureId = "isolatedFeatureId"
        case legacyExplodedDistance = "explodedDistance"
    }

    init(section: CADSectionPlane?, measurement: CADMeasurementProbe? = nil, isolatedFeatureId: String? = nil, explodedDistance: Double? = nil, motionStudy: CADMotionStudy? = nil) {
        self.section = section; self.measurement = measurement; self.isolatedFeatureId = isolatedFeatureId; self.explodedDistance = explodedDistance; self.motionStudy = motionStudy
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        section = try values.decodeIfPresent(CADSectionPlane.self, forKey: .section)
        measurement = try values.decodeIfPresent(CADMeasurementProbe.self, forKey: .measurement)
        isolatedFeatureId = try values.decodeIfPresent(String.self, forKey: .isolatedFeatureId) ?? values.decodeIfPresent(String.self, forKey: .legacyIsolatedFeatureId)
        explodedDistance = try values.decodeIfPresent(Double.self, forKey: .explodedDistance) ?? values.decodeIfPresent(Double.self, forKey: .legacyExplodedDistance)
        motionStudy = try values.decodeIfPresent(CADMotionStudy.self, forKey: .motionStudy)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(section, forKey: .section)
        try values.encodeIfPresent(measurement, forKey: .measurement)
        try values.encodeIfPresent(isolatedFeatureId, forKey: .isolatedFeatureId)
        try values.encodeIfPresent(explodedDistance, forKey: .explodedDistance)
        try values.encodeIfPresent(motionStudy, forKey: .motionStudy)
    }
}

struct CADDocument: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var units: String
    var revision: Int
    var backend: String
    var features: [CADFeature]
    var operations: [CADOperation]

    static let seed = CADDocument(
        id: "wall-bracket",
        name: "Wall bracket",
        units: "mm",
        revision: 18,
        backend: "native-metal",
        features: [
            CADFeature(id: "sketch-base", name: "Base profile", kind: "sketch", visible: true, params: ["width": 86, "height": 54], sketch: .mountingPlate),
            CADFeature(id: "pad-base", name: "Base extrusion", kind: "pad", visible: true, params: ["length": 6]),
            CADFeature(id: "pocket-holes", name: "Mounting holes", kind: "pocket", visible: true, params: ["diameter": 5, "offset": 12]),
            CADFeature(id: "fillet-edges", name: "Edge rounds", kind: "fillet", visible: true, params: ["radius": 3])
        ],
        operations: []
    )

    static func newPart(name: String, revision: Int) -> CADDocument {
        var document = seed
        document.id = "part-r\(revision)"
        document.name = name
        document.revision = revision
        document.operations = []
        return document
    }
}

enum CADValidationError: LocalizedError, Equatable {
    case invalidFeature(String)
    case invalidParameter(String)
    case invalidValue
    case constraintConflict(String)
    case revisionConflict(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .invalidFeature(let id): return "Feature ‘\(id)’ no longer exists. Refresh the model tree."
        case .invalidParameter(let key): return "Parameter ‘\(key)’ is not available on this feature."
        case .invalidValue: return "Dimensions must be greater than zero; positions and rotations must be finite numbers."
        case .constraintConflict(let detail): return "Sketch constraints could not converge: \(detail) No geometry was changed."
        case .revisionConflict(let expected, let actual): return "Revision changed from \(expected) to \(actual). Review the latest model before editing."
        }
    }
}
