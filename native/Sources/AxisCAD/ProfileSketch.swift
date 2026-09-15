import Foundation
import simd

struct CADProfileSketchSolution: Equatable, Sendable {
    var entities: [CADSketchEntity]
    var isClosed: Bool
    var errors: [String]
    var boundsMinimum: SIMD2<Double>
    var boundsMaximum: SIMD2<Double>
    var constraintCount: Int
    var degreesOfFreedom: Int
}

enum CADProfileSketch {
    static func solve(feature: CADFeature) -> CADProfileSketchSolution {
        guard feature.kind == "profile_sketch", let sketch = feature.sketch else {
            return CADProfileSketchSolution(entities: [], isClosed: false, errors: ["Feature is not a profile sketch."], boundsMinimum: .zero, boundsMaximum: .zero, constraintCount: 0, degreesOfFreedom: 0)
        }
        let allEntities = sketch.entities ?? []
        let entities = allEntities.filter { !$0.construction }
        var errors: [String] = []
        var points: [SIMD2<Double>] = []
        var ids = Set<String>()
        for entity in entities {
            if !ids.insert(entity.id).inserted { errors.append("Duplicate sketch entity ID: \(entity.id)") }
            if !entity.params.values.allSatisfy(\.isFinite) { errors.append("\(entity.id) contains a non-finite coordinate.") }
            switch entity.kind {
            case "line":
                guard let start = endpoint(entity, start: true), let end = endpoint(entity, start: false), simd_distance(start, end) > 0.000_001 else {
                    errors.append("\(entity.id) is a zero-length or incomplete line."); continue
                }
                points += [start, end]
            case "circle":
                guard let x = entity.params["cx"], let y = entity.params["cy"], let radius = entity.params["radius"], radius > 0 else {
                    errors.append("\(entity.id) is an incomplete circle."); continue
                }
                points += [SIMD2(x - radius, y - radius), SIMD2(x + radius, y + radius)]
            case "arc":
                guard let centerX = entity.params["cx"], let centerY = entity.params["cy"], let radius = entity.params["radius"], radius > 0,
                      let startAngle = entity.params["start_angle"], let endAngle = entity.params["end_angle"], startAngle != endAngle else {
                    errors.append("\(entity.id) is an incomplete arc."); continue
                }
                let center = SIMD2(centerX, centerY)
                points += [center + SIMD2(cos(startAngle), sin(startAngle)) * radius, center + SIMD2(cos(endAngle), sin(endAngle)) * radius]
            default: errors.append("\(entity.id) has unsupported kind '\(entity.kind)'.")
            }
        }

        let loops = Dictionary(grouping: entities, by: \.profileLoopId)
        var isClosed = !entities.isEmpty && errors.isEmpty
        if entities.isEmpty { errors.append("Sketch has no profile geometry."); isClosed = false }
        if !entities.isEmpty, loops["outer"] == nil { errors.append("Sketch requires an outer profile loop."); isClosed = false }
        for loopId in loops.keys.sorted() {
            let loop = loops[loopId] ?? [], circles = loop.filter { $0.kind == "circle" }
            var loopClosed = loop.count == 1 && circles.count == 1
            if circles.isEmpty, loop.count >= 3 {
                loopClosed = true
                for index in loop.indices {
                    guard let end = endpoint(loop[index], start: false), let next = endpoint(loop[(index + 1) % loop.count], start: true), simd_distance(end, next) <= 0.001 else { loopClosed = false; break }
                }
            }
            if !loopClosed { errors.append("Loop '\(loopId)' must be one circle or a connected closed line/arc loop."); isClosed = false }
        }
        if isClosed, let outer = loops["outer"] {
            let polygons = loops.mapValues { polygon(for: $0) }
            for loopId in loops.keys.sorted() {
                if selfIntersects(polygons[loopId] ?? []) {
                    errors.append("Loop '\(loopId)' self-intersects or touches itself away from connected endpoints."); isClosed = false
                }
            }
            let outerPolygon = polygons["outer"] ?? polygon(for: outer)
            let holeIds = loops.keys.filter { $0 != "outer" }.sorted()
            for loopId in holeIds {
                let holePolygon = polygons[loopId] ?? []
                if polygonsIntersect(holePolygon, outerPolygon) {
                    errors.append("Hole loop '\(loopId)' intersects or touches the outer loop."); isClosed = false
                } else if holePolygon.isEmpty || holePolygon.contains(where: { !contains($0, polygon: outerPolygon) }) {
                    errors.append("Hole loop '\(loopId)' must remain completely inside the outer loop."); isClosed = false
                }
            }
            for firstIndex in holeIds.indices {
                for secondIndex in holeIds.index(after: firstIndex)..<holeIds.endIndex {
                    let firstId = holeIds[firstIndex], secondId = holeIds[secondIndex]
                    let first = polygons[firstId] ?? [], second = polygons[secondId] ?? []
                    if polygonsIntersect(first, second) || first.first.map({ contains($0, polygon: second) }) == true || second.first.map({ contains($0, polygon: first) }) == true {
                        errors.append("Hole loops '\(firstId)' and '\(secondId)' intersect, touch, or overlap."); isClosed = false
                    }
                }
            }
        }

        var constraintIds = Set<String>(), removedDegrees = 0
        for constraint in sketch.constraints {
            if !constraintIds.insert(constraint.id).inserted { errors.append("Duplicate sketch constraint ID: \(constraint.id)"); continue }
            let validation = validate(constraint: constraint, entities: allEntities)
            if let validation { errors.append("\(constraint.id): \(validation)") }
            else { removedDegrees += ["coincident": 2, "horizontal": 1, "vertical": 1, "length": 1, "radius": 1, "parallel": 1, "perpendicular": 1, "equal": 1, "tangent": 1, "angle": 1][constraint.kind] ?? 0 }
        }
        let unconstrainedDegrees = allEntities.reduce(0) { partial, entity in partial + (["line": 4, "circle": 3, "arc": 5][entity.kind] ?? 0) }

        let minimum = points.reduce(SIMD2<Double>(repeating: .infinity)) { simd.min($0, $1) }
        let maximum = points.reduce(SIMD2<Double>(repeating: -.infinity)) { simd.max($0, $1) }
        return CADProfileSketchSolution(
            entities: entities, isClosed: isClosed, errors: errors,
            boundsMinimum: minimum.x.isFinite ? minimum : .zero,
            boundsMaximum: maximum.x.isFinite ? maximum : .zero,
            constraintCount: sketch.constraints.count,
            degreesOfFreedom: max(0, unconstrainedDegrees - removedDegrees)
        )
    }

    static func enforcing(_ constraint: CADSketchConstraint, entities: [CADSketchEntity]) throws -> [CADSketchEntity] {
        var result = entities
        func index(_ id: String) throws -> Int {
            guard let found = result.firstIndex(where: { $0.id == id }) else { throw CADValidationError.invalidFeature(id) }
            return found
        }
        switch constraint.kind {
        case "horizontal", "vertical":
            guard constraint.entities.count == 1 else { throw CADValidationError.invalidValue }
            let entityIndex = try index(constraint.entities[0]); guard result[entityIndex].kind == "line" else { throw CADValidationError.invalidValue }
            if constraint.kind == "horizontal" { result[entityIndex].params["y2"] = result[entityIndex].params["y1"] }
            else { result[entityIndex].params["x2"] = result[entityIndex].params["x1"] }
        case "length":
            guard constraint.entities.count == 1, let value = constraint.value, value > 0 else { throw CADValidationError.invalidValue }
            let entityIndex = try index(constraint.entities[0]); guard result[entityIndex].kind == "line", let start = endpoint(result[entityIndex], start: true), let end = endpoint(result[entityIndex], start: false) else { throw CADValidationError.invalidValue }
            let direction = end - start, magnitude = simd_length(direction); guard magnitude > 0.000_001 else { throw CADValidationError.invalidValue }
            let solvedEnd = start + direction / magnitude * value
            result[entityIndex].params["x2"] = solvedEnd.x; result[entityIndex].params["y2"] = solvedEnd.y
        case "radius":
            guard constraint.entities.count == 1, let value = constraint.value, value > 0 else { throw CADValidationError.invalidValue }
            let entityIndex = try index(constraint.entities[0]); guard ["circle", "arc"].contains(result[entityIndex].kind) else { throw CADValidationError.invalidValue }
            result[entityIndex].params["radius"] = value
        case "coincident":
            guard constraint.entities.count == 2, let target = referencedPoint(constraint.entities[0], entities: result) else { throw CADValidationError.invalidValue }
            let parts = constraint.entities[1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, ["start", "end"].contains(parts[1]) else { throw CADValidationError.invalidValue }
            let entityIndex = try index(parts[0]); guard result[entityIndex].kind == "line" else { throw CADValidationError.invalidValue }
            let suffix = parts[1] == "start" ? "1" : "2"
            result[entityIndex].params["x\(suffix)"] = target.x; result[entityIndex].params["y\(suffix)"] = target.y
        case "parallel", "perpendicular":
            guard constraint.entities.count == 2 else { throw CADValidationError.invalidValue }
            let referenceIndex = try index(constraint.entities[0]), movingIndex = try index(constraint.entities[1])
            guard result[referenceIndex].kind == "line", result[movingIndex].kind == "line",
                  let referenceStart = endpoint(result[referenceIndex], start: true), let referenceEnd = endpoint(result[referenceIndex], start: false),
                  let movingStart = endpoint(result[movingIndex], start: true), let movingEnd = endpoint(result[movingIndex], start: false) else { throw CADValidationError.invalidValue }
            let referenceVector = referenceEnd - referenceStart, referenceLength = simd_length(referenceVector), movingLength = simd_distance(movingStart, movingEnd)
            guard referenceLength > 0.000_001, movingLength > 0.000_001 else { throw CADValidationError.invalidValue }
            var direction = referenceVector / referenceLength
            if constraint.kind == "perpendicular" { direction = SIMD2(-direction.y, direction.x) }
            let solvedEnd = movingStart + direction * movingLength
            result[movingIndex].params["x2"] = solvedEnd.x; result[movingIndex].params["y2"] = solvedEnd.y
        case "angle":
            guard constraint.entities.count == 2, let degrees = constraint.value, degrees > 0, degrees < 180 else { throw CADValidationError.invalidValue }
            let referenceIndex = try index(constraint.entities[0]), movingIndex = try index(constraint.entities[1])
            guard result[referenceIndex].kind == "line", result[movingIndex].kind == "line",
                  let referenceStart = endpoint(result[referenceIndex], start: true), let referenceEnd = endpoint(result[referenceIndex], start: false),
                  let movingStart = endpoint(result[movingIndex], start: true), let movingEnd = endpoint(result[movingIndex], start: false) else { throw CADValidationError.invalidValue }
            let reference = referenceEnd - referenceStart, moving = movingEnd - movingStart
            let referenceLength = simd_length(reference), movingLength = simd_length(moving)
            guard referenceLength > 0.000_001, movingLength > 0.000_001 else { throw CADValidationError.invalidValue }
            let sign = reference.x * moving.y - reference.y * moving.x < 0 ? -1.0 : 1.0
            let angle = sign * degrees * .pi / 180
            let unit = reference / referenceLength
            let direction = SIMD2(cos(angle) * unit.x - sin(angle) * unit.y, sin(angle) * unit.x + cos(angle) * unit.y)
            let solvedEnd = movingStart + direction * movingLength
            result[movingIndex].params["x2"] = solvedEnd.x; result[movingIndex].params["y2"] = solvedEnd.y
        case "equal":
            guard constraint.entities.count == 2 else { throw CADValidationError.invalidValue }
            let referenceIndex = try index(constraint.entities[0]), movingIndex = try index(constraint.entities[1])
            if result[referenceIndex].kind == "line", result[movingIndex].kind == "line",
               let referenceStart = endpoint(result[referenceIndex], start: true), let referenceEnd = endpoint(result[referenceIndex], start: false),
               let movingStart = endpoint(result[movingIndex], start: true), let movingEnd = endpoint(result[movingIndex], start: false) {
                let targetLength = simd_distance(referenceStart, referenceEnd), direction = movingEnd - movingStart, movingLength = simd_length(direction)
                guard targetLength > 0.000_001, movingLength > 0.000_001 else { throw CADValidationError.invalidValue }
                let solvedEnd = movingStart + direction / movingLength * targetLength
                result[movingIndex].params["x2"] = solvedEnd.x; result[movingIndex].params["y2"] = solvedEnd.y
            } else if ["circle", "arc"].contains(result[referenceIndex].kind), ["circle", "arc"].contains(result[movingIndex].kind), let radius = result[referenceIndex].params["radius"] {
                result[movingIndex].params["radius"] = radius
            } else { throw CADValidationError.invalidValue }
        case "tangent":
            guard constraint.entities.count == 2 else { throw CADValidationError.invalidValue }
            let firstIndex = try index(constraint.entities[0]), secondIndex = try index(constraint.entities[1])
            let first = result[firstIndex], second = result[secondIndex]
            if first.kind == "line" || second.kind == "line" {
                let lineIndex = first.kind == "line" ? firstIndex : secondIndex
                let curveIndex = first.kind == "line" ? secondIndex : firstIndex
                guard ["circle", "arc"].contains(result[curveIndex].kind),
                      let lineStart = endpoint(result[lineIndex], start: true), let lineEnd = endpoint(result[lineIndex], start: false),
                      let centerX = result[curveIndex].params["cx"], let centerY = result[curveIndex].params["cy"], let radius = result[curveIndex].params["radius"], radius > 0 else { throw CADValidationError.invalidValue }
                let direction = lineEnd - lineStart, length = simd_length(direction); guard length > 0.000_001 else { throw CADValidationError.invalidValue }
                let unit = direction / length, normal = SIMD2(-unit.y, unit.x), center = SIMD2(centerX, centerY)
                let projection = lineStart + unit * simd_dot(center - lineStart, unit)
                let side = simd_dot(center - lineStart, normal) < 0 ? -1.0 : 1.0
                let solvedCenter = projection + normal * radius * side
                result[curveIndex].params["cx"] = solvedCenter.x; result[curveIndex].params["cy"] = solvedCenter.y
            } else if ["circle", "arc"].contains(first.kind), ["circle", "arc"].contains(second.kind),
                      let firstX = first.params["cx"], let firstY = first.params["cy"], let firstRadius = first.params["radius"],
                      let secondX = second.params["cx"], let secondY = second.params["cy"], let secondRadius = second.params["radius"] {
                let firstCenter = SIMD2(firstX, firstY), secondCenter = SIMD2(secondX, secondY), delta = secondCenter - firstCenter
                let distance = simd_length(delta), target = firstRadius + secondRadius
                guard distance > 0.000_001, target > 0 else { throw CADValidationError.invalidValue }
                let solvedCenter = firstCenter + delta / distance * target
                result[secondIndex].params["cx"] = solvedCenter.x; result[secondIndex].params["cy"] = solvedCenter.y
            } else { throw CADValidationError.invalidValue }
        default: throw CADValidationError.invalidValue
        }
        guard validate(constraint: constraint, entities: result) == nil else { throw CADValidationError.invalidValue }
        return result
    }

    static func solving(_ constraints: [CADSketchConstraint], entities: [CADSketchEntity]) throws -> [CADSketchEntity] {
        guard !constraints.isEmpty else { return entities }
        var result = entities
        let maximumPasses = min(128, max(16, constraints.count * 2))
        for _ in 0..<maximumPasses {
            // Symmetric Gauss-Seidel projection prevents constraint arrival
            // order (UI vs. MCP batch) from consistently favouring the last
            // entity in a coupled chain. It remains bounded and deterministic
            // while the general residual/Jacobian solver is introduced.
            for constraint in constraints + Array(constraints.reversed()) {
                do { result = try enforcing(constraint, entities: result) }
                catch {
                    throw CADValidationError.constraintConflict("‘\(constraint.id)’ is invalid or degenerate.")
                }
            }
            if constraints.allSatisfy({ validate(constraint: $0, entities: result) == nil }) { return result }
        }
        let unsatisfied = constraints.compactMap { constraint in
            validate(constraint: constraint, entities: result).map { "‘\(constraint.id)’ (\($0))" }
        }
        throw CADValidationError.constraintConflict(unsatisfied.prefix(3).joined(separator: ", "))
    }

    static func trimmingOrExtending(line: CADSketchEntity, to reference: CADSketchEntity, endpoint endpointName: String, mode: String) throws -> CADSketchEntity {
        guard line.kind == "line", reference.kind == "line", line.id != reference.id,
              ["start", "end"].contains(endpointName), ["trim", "extend"].contains(mode),
              let start = endpoint(line, start: true), let end = endpoint(line, start: false),
              let referenceStart = endpoint(reference, start: true), let referenceEnd = endpoint(reference, start: false) else { throw CADValidationError.invalidValue }
        let direction = end - start, referenceDirection = referenceEnd - referenceStart
        let denominator = direction.x * referenceDirection.y - direction.y * referenceDirection.x
        guard abs(denominator) > 0.000_001 else { throw CADValidationError.invalidValue }
        let delta = referenceStart - start
        let lineParameter = (delta.x * referenceDirection.y - delta.y * referenceDirection.x) / denominator
        let referenceParameter = (delta.x * direction.y - delta.y * direction.x) / denominator
        guard referenceParameter >= -0.000_001, referenceParameter <= 1.000_001 else { throw CADValidationError.invalidValue }
        if mode == "trim" { guard lineParameter > 0.000_001, lineParameter < 0.999_999 else { throw CADValidationError.invalidValue } }
        else if endpointName == "start" { guard lineParameter < -0.000_001 else { throw CADValidationError.invalidValue } }
        else { guard lineParameter > 1.000_001 else { throw CADValidationError.invalidValue } }
        let intersection = start + direction * lineParameter
        var result = line; let suffix = endpointName == "start" ? "1" : "2"
        result.params["x\(suffix)"] = intersection.x; result.params["y\(suffix)"] = intersection.y
        guard let solvedStart = endpoint(result, start: true), let solvedEnd = endpoint(result, start: false), simd_distance(solvedStart, solvedEnd) > 0.000_001 else { throw CADValidationError.invalidValue }
        return result
    }

    private static func validate(constraint: CADSketchConstraint, entities: [CADSketchEntity]) -> String? {
        var byId: [String: CADSketchEntity] = [:]
        for entity in entities { byId[entity.id] = entity }
        switch constraint.kind {
        case "horizontal", "vertical":
            guard constraint.entities.count == 1, let entity = byId[constraint.entities[0]], entity.kind == "line",
                  let start = endpoint(entity, start: true), let end = endpoint(entity, start: false) else { return "requires one line" }
            let error = constraint.kind == "horizontal" ? abs(start.y - end.y) : abs(start.x - end.x)
            return error <= 0.001 ? nil : "geometry does not satisfy \(constraint.kind)"
        case "length":
            guard constraint.entities.count == 1, let entity = byId[constraint.entities[0]], entity.kind == "line", let value = constraint.value, value > 0,
                  let start = endpoint(entity, start: true), let end = endpoint(entity, start: false) else { return "requires one line and a positive value" }
            return abs(simd_distance(start, end) - value) <= 0.001 ? nil : "line length does not match \(value)"
        case "radius":
            guard constraint.entities.count == 1, let entity = byId[constraint.entities[0]], ["circle", "arc"].contains(entity.kind), let value = constraint.value, value > 0 else { return "requires one circle/arc and a positive value" }
            return abs((entity.params["radius"] ?? 0) - value) <= 0.001 ? nil : "radius does not match \(value)"
        case "coincident":
            guard constraint.entities.count == 2, let first = referencedPoint(constraint.entities[0], entities: entities), let second = referencedPoint(constraint.entities[1], entities: entities) else { return "requires two endpoint references such as line-1:end" }
            return simd_distance(first, second) <= 0.001 ? nil : "referenced endpoints are not coincident"
        case "parallel", "perpendicular":
            guard constraint.entities.count == 2, let first = byId[constraint.entities[0]], let second = byId[constraint.entities[1]], first.kind == "line", second.kind == "line",
                  let a1 = endpoint(first, start: true), let a2 = endpoint(first, start: false), let b1 = endpoint(second, start: true), let b2 = endpoint(second, start: false) else { return "requires two lines" }
            let a = simd_normalize(a2 - a1), b = simd_normalize(b2 - b1)
            let error = constraint.kind == "parallel" ? abs(a.x * b.y - a.y * b.x) : abs(simd_dot(a, b))
            return error <= 0.001 ? nil : "lines do not satisfy \(constraint.kind)"
        case "angle":
            guard constraint.entities.count == 2, let target = constraint.value, target > 0, target < 180,
                  let first = byId[constraint.entities[0]], let second = byId[constraint.entities[1]], first.kind == "line", second.kind == "line",
                  let a1 = endpoint(first, start: true), let a2 = endpoint(first, start: false), let b1 = endpoint(second, start: true), let b2 = endpoint(second, start: false) else { return "requires two lines and an angle from 0 to 180 degrees" }
            let a = a2 - a1, b = b2 - b1, lengthA = simd_length(a), lengthB = simd_length(b)
            guard lengthA > 0.000_001, lengthB > 0.000_001 else { return "lines must have nonzero length" }
            let measured = acos(max(-1, min(1, simd_dot(a, b) / (lengthA * lengthB)))) * 180 / .pi
            return abs(measured - target) <= 0.05 ? nil : "line angle does not match \(target) degrees"
        case "equal":
            guard constraint.entities.count == 2, let first = byId[constraint.entities[0]], let second = byId[constraint.entities[1]] else { return "requires two entities" }
            if first.kind == "line", second.kind == "line", let a1 = endpoint(first, start: true), let a2 = endpoint(first, start: false), let b1 = endpoint(second, start: true), let b2 = endpoint(second, start: false) {
                return abs(simd_distance(a1, a2) - simd_distance(b1, b2)) <= 0.001 ? nil : "line lengths are not equal"
            }
            if ["circle", "arc"].contains(first.kind), ["circle", "arc"].contains(second.kind) { return abs((first.params["radius"] ?? 0) - (second.params["radius"] ?? 0)) <= 0.001 ? nil : "radii are not equal" }
            return "requires two lines or two circles/arcs"
        case "tangent":
            guard constraint.entities.count == 2, let first = byId[constraint.entities[0]], let second = byId[constraint.entities[1]] else { return "requires two entities" }
            if first.kind == "line" || second.kind == "line" {
                let line = first.kind == "line" ? first : second, curve = first.kind == "line" ? second : first
                guard ["circle", "arc"].contains(curve.kind), let start = endpoint(line, start: true), let end = endpoint(line, start: false),
                      let centerX = curve.params["cx"], let centerY = curve.params["cy"], let radius = curve.params["radius"] else { return "requires one line and one circle/arc" }
                let direction = end - start, length = simd_length(direction); guard length > 0.000_001 else { return "line must have nonzero length" }
                let distance = abs(direction.x * (start.y - centerY) - (start.x - centerX) * direction.y) / length
                return abs(distance - radius) <= 0.001 ? nil : "line and curve are not tangent"
            }
            if ["circle", "arc"].contains(first.kind), ["circle", "arc"].contains(second.kind),
               let firstX = first.params["cx"], let firstY = first.params["cy"], let firstRadius = first.params["radius"],
               let secondX = second.params["cx"], let secondY = second.params["cy"], let secondRadius = second.params["radius"] {
                return abs(simd_distance(SIMD2(firstX, firstY), SIMD2(secondX, secondY)) - firstRadius - secondRadius) <= 0.001 ? nil : "curves are not externally tangent"
            }
            return "requires a line and circle/arc, or two circles/arcs"
        default: return "unsupported constraint kind '\(constraint.kind)'"
        }
    }

    private static func referencedPoint(_ reference: String, entities: [CADSketchEntity]) -> SIMD2<Double>? {
        let parts = reference.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let entity = entities.first(where: { $0.id == parts[0] }) else { return nil }
        if parts[1] == "start" { return endpoint(entity, start: true) }
        if parts[1] == "end" { return endpoint(entity, start: false) }
        if parts[1] == "center", let x = entity.params["cx"], let y = entity.params["cy"] { return SIMD2(x, y) }
        return nil
    }

    static func endpoint(_ entity: CADSketchEntity, start: Bool) -> SIMD2<Double>? {
        if entity.kind == "line", let x = entity.params[start ? "x1" : "x2"], let y = entity.params[start ? "y1" : "y2"] { return SIMD2(x, y) }
        if entity.kind == "arc", let cx = entity.params["cx"], let cy = entity.params["cy"], let radius = entity.params["radius"], let angle = entity.params[start ? "start_angle" : "end_angle"] {
            return SIMD2(cx + cos(angle) * radius, cy + sin(angle) * radius)
        }
        return nil
    }

    private static func polygon(for entities: [CADSketchEntity]) -> [SIMD2<Double>] {
        if entities.count == 1, let entity = entities.first, entity.kind == "circle", let cx = entity.params["cx"], let cy = entity.params["cy"], let radius = entity.params["radius"] {
            return (0..<64).map { index in let angle = Double(index) * 2 * .pi / 64; return SIMD2(cx + cos(angle) * radius, cy + sin(angle) * radius) }
        }
        return entities.flatMap { entity -> [SIMD2<Double>] in
            if entity.kind == "line" { return endpoint(entity, start: true).map { [$0] } ?? [] }
            guard entity.kind == "arc", let cx = entity.params["cx"], let cy = entity.params["cy"], let radius = entity.params["radius"], let start = entity.params["start_angle"], let end = entity.params["end_angle"] else { return [] }
            let ccw = entity.params["ccw"] != 0
            var sweep = end - start
            if ccw, sweep < 0 { sweep += 2 * .pi }
            if !ccw, sweep > 0 { sweep -= 2 * .pi }
            let steps = max(4, Int(ceil(abs(sweep) / (.pi / 16))))
            return (0..<steps).map { index in let angle = start + sweep * Double(index) / Double(steps); return SIMD2(cx + cos(angle) * radius, cy + sin(angle) * radius) }
        }
    }

    private static func contains(_ point: SIMD2<Double>, polygon: [SIMD2<Double>]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false, previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[current], b = polygon[previous]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            previous = current
        }
        return inside
    }

    private static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
        let ab = b - a, ac = c - a
        return ab.x * ac.y - ab.y * ac.x
    }

    private static func onSegment(_ point: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>, tolerance: Double = 0.000_001) -> Bool {
        abs(cross(a, b, point)) <= tolerance
            && point.x >= min(a.x, b.x) - tolerance && point.x <= max(a.x, b.x) + tolerance
            && point.y >= min(a.y, b.y) - tolerance && point.y <= max(a.y, b.y) + tolerance
    }

    private static func segmentsIntersect(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>) -> Bool {
        let abC = cross(a, b, c), abD = cross(a, b, d), cdA = cross(c, d, a), cdB = cross(c, d, b)
        if ((abC > 0 && abD < 0) || (abC < 0 && abD > 0)), ((cdA > 0 && cdB < 0) || (cdA < 0 && cdB > 0)) { return true }
        return (abs(abC) <= 0.000_001 && onSegment(c, a, b)) || (abs(abD) <= 0.000_001 && onSegment(d, a, b))
            || (abs(cdA) <= 0.000_001 && onSegment(a, c, d)) || (abs(cdB) <= 0.000_001 && onSegment(b, c, d))
    }

    private static func polygonsIntersect(_ first: [SIMD2<Double>], _ second: [SIMD2<Double>]) -> Bool {
        guard first.count >= 2, second.count >= 2 else { return false }
        for firstIndex in first.indices {
            let a = first[firstIndex], b = first[(firstIndex + 1) % first.count]
            for secondIndex in second.indices {
                let c = second[secondIndex], d = second[(secondIndex + 1) % second.count]
                if segmentsIntersect(a, b, c, d) { return true }
            }
        }
        return false
    }

    private static func selfIntersects(_ polygon: [SIMD2<Double>]) -> Bool {
        guard polygon.count >= 4 else { return false }
        for first in polygon.indices {
            let nextFirst = (first + 1) % polygon.count
            for second in polygon.indices where second > first {
                let nextSecond = (second + 1) % polygon.count
                if second == nextFirst || nextSecond == first { continue }
                if segmentsIntersect(polygon[first], polygon[nextFirst], polygon[second], polygon[nextSecond]) { return true }
            }
        }
        return false
    }
}
