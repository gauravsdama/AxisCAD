import Foundation

struct CADKernelAdapterStatus: Decodable {
    let available: Bool
    let adapter: String
    let version: String?
    let execution: String?
    let bundledWithApp: Bool?
    let error: String?
}

struct CADKernelValidation: Decodable {
    struct Point: Decodable { let x: Double; let y: Double; let z: Double }
    struct Bounds: Decodable { let minimum: Point; let maximum: Point }
    struct StepRoundtrip: Decodable {
        let attempted: Bool; let passed: Bool; let reader: String
        let bodyCount: Int; let triangleCount: Int
        let volume: Double?; let volumeRelativeError: Double?; let boundsMaxDeviation: Double?
        let error: String?
    }

    let ok: Bool
    let revision: Int
    let featureId: String
    let adapter: String
    let kernelMassProperties: Bool
    let bounds: Bounds
    let volume: Double
    let analyticReferenceVolume: Double?
    let volumeDeviation: Double?
    let volumeRelativeError: Double?
    let volumeWithinOnePercent: Bool?
    let surfaceArea: Double
    let centerOfMass: Point
    let triangleCount: Int
    let boundaryEdgeSegments: Int
    let closedManifoldMesh: Bool
    let canExportStep: Bool
    let stepRoundtrip: StepRoundtrip
    let warnings: [String]
}

struct CADKernelStepExport: Decodable {
    let ok: Bool
    let revision: Int
    let featureId: String
    let path: String
    let byteCount: Int
    let adapter: String
    let validation: CADKernelExportValidation
}

struct CADKernelAssemblyStepExport: Decodable {
    let ok: Bool
    let revision: Int
    let path: String
    let byteCount: Int
    let adapter: String
    let instanceCount: Int
    let bodyCount: Int
    let instanceIds: [String]
    let bounds: CADKernelValidation.Bounds
    let volume: Double
    let stepRoundtrip: CADKernelValidation.StepRoundtrip
}

struct CADKernelStepInspection: Decodable {
    struct Body: Decodable {
        let bodyNumber: Int
        let bounds: CADKernelValidation.Bounds
        let volume: Double
        let surfaceArea: Double
        let triangleCount: Int
        let canExportStep: Bool
    }
    let ok: Bool
    let adapter: String
    let sourcePath: String
    let byteCount: Int
    let bodyCount: Int
    let bodies: [Body]
}

struct CADKernelExportValidation: Decodable {
    let boundaryEdgeSegments: Int
    let closedManifoldMesh: Bool
    let canExportStep: Bool
    let stepRoundtrip: CADKernelValidation.StepRoundtrip
    let warnings: [String]
}

struct CADKernelClearance: Decodable, Equatable, Sendable {
    struct Point: Decodable, Equatable, Sendable { let x: Double; let y: Double; let z: Double }
    let ok: Bool
    let revision: Int
    let featureId: String
    let secondFeatureId: String
    let distance: Double
    let intersecting: Bool
    let classification: String
    let pointA: Point
    let pointB: Point
    let adapter: String
    let tessellationSegments: Int
}

struct CADKernelRenderMesh: Decodable, Equatable, Sendable {
    let ok: Bool
    let revision: Int
    let featureId: String
    let sourceFeatures: [String]
    let positions: [Float]
    let normals: [Float]
    let indices: [UInt32]
    let faceIds: [UInt32]?
    let topologyEdges: [CADKernelTopologyEdge]?
    let topologyFaces: [CADKernelTopologyFace]?
    let boundaryEdgeSegments: Int

    func renderMesh(selected: Bool) -> CADRenderMesh {
        let color: SIMD4<Float> = selected ? SIMD4(0.35, 0.96, 0.67, 1) : SIMD4(0.73, 0.55, 0.93, 1)
        let vertices = indices.map { rawIndex -> GPUVertex in
            let index = Int(rawIndex), positionOffset = index * 3
            let position = positionOffset + 2 < positions.count ? SIMD3(positions[positionOffset], positions[positionOffset + 1], positions[positionOffset + 2]) : .zero
            let normal = positionOffset + 2 < normals.count ? SIMD3(normals[positionOffset], normals[positionOffset + 1], normals[positionOffset + 2]) : SIMD3<Float>(0, 0, 1)
            return GPUVertex(position: SIMD4(position, 1), normal: SIMD4(normal, 0), color: color)
        }
        return CADRenderMesh(featureId: featureId, vertices: vertices, faceIds: faceIds ?? [], topologyEdges: topologyEdges ?? [])
    }
}

struct CADKernelTopologyEdge: Decodable, Equatable, Sendable {
    let id: UInt32
    let faceIds: [UInt32]
    var positions: [Float]
    var anchor: [Float]
    var length: Double? = nil
    var lengthExact: Bool? = nil
    var curveKind: String? = nil
    var radius: Double? = nil

    var segmentCount: Int { positions.count / 6 }

    private var polylineLength: Double {
        stride(from: 0, to: positions.count - 5, by: 6).reduce(0) { length, offset in
            let dx = Double(positions[offset + 3] - positions[offset])
            let dy = Double(positions[offset + 4] - positions[offset + 1])
            let dz = Double(positions[offset + 5] - positions[offset + 2])
            return length + sqrt(dx * dx + dy * dy + dz * dz)
        }
    }

    var measuredLength: Double { length ?? polylineLength }
    var hasExactLength: Bool { lengthExact ?? (segmentCount == 1) }
    var hasExactLinearLength: Bool { hasExactLength && (curveKind ?? (segmentCount == 1 ? "line" : "tessellated")) == "line" }
}

struct CADKernelTopologyFace: Decodable, Equatable, Sendable {
    let id: UInt32
    let area: Double
    let areaExact: Bool
    let surfaceKind: String
    let radius: Double?
}

enum KernelServiceError: LocalizedError {
    case unavailable(String)
    case failed(String)
    case timedOut(Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail): "Kernel adapter unavailable: \(detail)"
        case .failed(let detail): "Kernel operation failed: \(detail)"
        case .timedOut(let seconds): "Kernel operation stopped after \(seconds) seconds. The document was not changed."
        case .cancelled: "Kernel operation cancelled. The document was not changed."
        }
    }
}

final class KernelProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    var didTimeOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }

    func attach(_ process: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    func detach() {
        lock.lock(); process = nil; lock.unlock()
    }

    func cancel() {
        lock.lock(); cancelled = true; let active = process; lock.unlock()
        if active?.isRunning == true { active?.terminate() }
    }

    func timeOut() {
        lock.lock(); let active = process
        if active?.isRunning == true { timedOut = true }
        lock.unlock()
        if active?.isRunning == true { active?.terminate() }
    }
}

enum KernelService {
    private struct Request: Encodable {
        let action: String
        let documentPath: String?
        let featureId: String?
        let secondFeatureId: String?
        let outputPath: String?
        let inputPath: String?
    }

    private struct AdapterError: Decodable { let error: String? }

    static func status() async throws -> CADKernelAdapterStatus {
        try await invoke(Request(action: "status", documentPath: nil, featureId: nil, secondFeatureId: nil, outputPath: nil, inputPath: nil), as: CADKernelAdapterStatus.self)
    }

    static func validate(documentURL: URL, featureId: String?) async throws -> CADKernelValidation {
        try await invoke(Request(action: "validate", documentPath: documentURL.path, featureId: featureId ?? "pad-base", secondFeatureId: nil, outputPath: nil, inputPath: nil), as: CADKernelValidation.self)
    }

    static func exportStep(documentURL: URL, featureId: String?, to outputURL: URL) async throws -> CADKernelStepExport {
        try await invoke(Request(action: "export_step", documentPath: documentURL.path, featureId: featureId ?? "pad-base", secondFeatureId: nil, outputPath: outputURL.path, inputPath: nil), as: CADKernelStepExport.self)
    }

    static func exportAssemblyStep(documentURL: URL, to outputURL: URL) async throws -> CADKernelAssemblyStepExport {
        try await invoke(Request(action: "export_assembly_step", documentPath: documentURL.path, featureId: nil, secondFeatureId: nil, outputPath: outputURL.path, inputPath: nil), as: CADKernelAssemblyStepExport.self)
    }

    static func renderMesh(documentURL: URL, featureId: String) async throws -> CADKernelRenderMesh {
        try await invoke(Request(action: "mesh", documentPath: documentURL.path, featureId: featureId, secondFeatureId: nil, outputPath: nil, inputPath: nil), as: CADKernelRenderMesh.self)
    }

    static func clearance(documentURL: URL, featureId: String, secondFeatureId: String) async throws -> CADKernelClearance {
        try await invoke(Request(action: "clearance", documentPath: documentURL.path, featureId: featureId, secondFeatureId: secondFeatureId, outputPath: nil, inputPath: nil), as: CADKernelClearance.self)
    }

    static func inspectStep(at inputURL: URL) async throws -> CADKernelStepInspection {
        try await invoke(Request(action: "inspect_step", documentPath: nil, featureId: nil, secondFeatureId: nil, outputPath: nil, inputPath: inputURL.path), as: CADKernelStepInspection.self)
    }

    private static func invoke<Response: Decodable>(_ request: Request, as type: Response.Type) async throws -> Response {
        let controller = KernelProcessController()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) {
            let input = Pipe(), output = Pipe(), errorOutput = Pipe()
            let process = Process()
            if let bundledWorker = bundledWorkerURL() {
                process.executableURL = bundledWorker
                process.arguments = []
            } else {
                let workerURL = try workerURL()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["node", workerURL.path]
            }
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errorOutput
            var environment = ProcessInfo.processInfo.environment
            if environment["AXIS_VCAD_KERNEL_DIR"] == nil, let configured = configuredKernelDirectory() {
                environment["AXIS_VCAD_KERNEL_DIR"] = configured.path
                if configured.path.hasPrefix(Bundle.main.bundleURL.path + "/") {
                    environment["AXIS_CAD_BUNDLED_KERNEL"] = "1"
                }
            }
            if bundledWorkerURL() != nil {
                environment["AXIS_CAD_COMPILED_WORKER"] = "1"
            }
            process.environment = environment
            let timeoutSeconds = min(600, max(5, Int(environment["AXIS_CAD_KERNEL_TIMEOUT_SECONDS"] ?? "90") ?? 90))

            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let requestData = try encoder.encode(request)
            guard controller.attach(process) else { throw KernelServiceError.cancelled }
            defer { controller.detach() }
            try process.run()
            let watchdog = DispatchWorkItem { controller.timeOut() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: watchdog)
            defer { watchdog.cancel() }
            input.fileHandleForWriting.write(requestData)
            try input.fileHandleForWriting.close()
            let responseData = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: errorOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            if controller.didTimeOut { throw KernelServiceError.timedOut(timeoutSeconds) }
            if controller.wasCancelled { throw KernelServiceError.cancelled }
            if process.terminationStatus != 0 {
                let adapterError = try? JSONDecoder.axis.decode(AdapterError.self, from: responseData)
                throw KernelServiceError.failed(adapterError?.error ?? stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            do { return try JSONDecoder.axis.decode(Response.self, from: responseData) }
            catch {
                let text = String(data: responseData, encoding: .utf8) ?? "No response"
                throw KernelServiceError.failed("Could not decode adapter response: \(text.prefix(240))")
            }
            }.value
        }, onCancel: {
            controller.cancel()
        })
    }

    private static func bundledWorkerURL() -> URL? {
        let candidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/AxisKernelWorker")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    private static func workerURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["AXIS_VCAD_WORKER_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let bundled = Bundle.main.url(forResource: "vcad-kernel", withExtension: "mjs") { return bundled }
        let sourceFallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kernel/vcad-kernel.mjs")
        guard FileManager.default.fileExists(atPath: sourceFallback.path) else {
            throw KernelServiceError.unavailable("vcad-kernel.mjs is not bundled; set AXIS_VCAD_WORKER_PATH")
        }
        return sourceFallback
    }

    private static func configuredKernelDirectory() -> URL? {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("kernel-wasm", isDirectory: true)
            let binding = bundled.appendingPathComponent("vcad_kernel_wasm.js").path
            let wasm = bundled.appendingPathComponent("vcad_kernel_wasm_bg.wasm").path
            if FileManager.default.fileExists(atPath: binding), FileManager.default.fileExists(atPath: wasm) {
                return bundled
            }
        }
        if let configURL = Bundle.main.url(forResource: "kernel-config", withExtension: "json"),
           let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode([String: String].self, from: data),
           let path = config["kernel_directory"] { return URL(fileURLWithPath: path, isDirectory: true) }
        let sourceFallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("third_party/vcad-kernel", isDirectory: true)
        return FileManager.default.fileExists(atPath: sourceFallback.path) ? sourceFallback : nil
    }
}

private extension JSONDecoder {
    static var axis: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
