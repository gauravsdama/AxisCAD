import CoreGraphics
import Foundation

struct SketchCircleSolution: Equatable, Sendable {
    var id: String
    var center: CGPoint
    var radius: Double
}
struct SketchSolution: Equatable, Sendable {
    var width: Double
    var height: Double
    var holeDiameter: Double
    var holeOffset: Double
    var corners: [CGPoint]
    var holes: [SketchCircleSolution]
    var constraintCount: Int
    var degreesOfFreedom: Int
    var errors: [String]

    var isFullyConstrained: Bool { errors.isEmpty && degreesOfFreedom == 0 }
}

enum SketchSolver {
    static func solve(document: CADDocument) -> SketchSolution {
        let profile = document.features.first { $0.id == "sketch-base" }
        let pockets = document.features.first { $0.id == "pocket-holes" }
        return solve(
            width: profile?.params["width"] ?? 86,
            height: profile?.params["height"] ?? 54,
            holeDiameter: pockets?.params["diameter"] ?? 5,
            holeOffset: pockets?.params["offset"] ?? 12,
            constraintCount: profile?.sketch?.constraints.count ?? CADSketchDefinition.mountingPlate.constraints.count
        )
    }

    static func solve(width: Double, height: Double, holeDiameter: Double, holeOffset: Double, constraintCount: Int = 11) -> SketchSolution {
        var errors: [String] = []
        if width <= 0 || height <= 0 { errors.append("Profile width and height must be greater than zero.") }
        if holeDiameter <= 0 { errors.append("Hole diameter must be greater than zero.") }
        if holeOffset <= holeDiameter / 2 { errors.append("Hole offset must exceed the hole radius.") }
        if holeOffset + holeDiameter / 2 >= min(width, height) / 2 {
            errors.append("Holes overlap the profile center or cross the outer edge.")
        }

        let x = width / 2
        let y = height / 2
        let radius = holeDiameter / 2
        let centers: [(String, CGPoint)] = [
            ("hole-nw", CGPoint(x: -x + holeOffset, y: y - holeOffset)),
            ("hole-ne", CGPoint(x: x - holeOffset, y: y - holeOffset)),
            ("hole-sw", CGPoint(x: -x + holeOffset, y: -y + holeOffset)),
            ("hole-se", CGPoint(x: x - holeOffset, y: -y + holeOffset))
        ]
        return SketchSolution(
            width: width,
            height: height,
            holeDiameter: holeDiameter,
            holeOffset: holeOffset,
            corners: [CGPoint(x: -x, y: -y), CGPoint(x: x, y: -y), CGPoint(x: x, y: y), CGPoint(x: -x, y: y)],
            holes: centers.map { SketchCircleSolution(id: $0.0, center: $0.1, radius: radius) },
            constraintCount: constraintCount,
            degreesOfFreedom: errors.isEmpty ? 0 : 1,
            errors: errors
        )
    }
}
