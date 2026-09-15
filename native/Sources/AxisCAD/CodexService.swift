import Foundation

enum CodexServiceError: LocalizedError {
    case executableMissing
    case launchFailed(String)
    case commandFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .executableMissing:
            return "Codex CLI is not installed. Install Codex or keep editing with the normal CAD tools."
        case .launchFailed(let reason):
            return "Codex could not start: \(reason)"
        case .commandFailed(let code, let message):
            return "Codex stopped with exit code \(code): \(message)"
        }
    }
}

enum CodexService {
    static func executableURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let candidates = [
            environment["AXIS_CODEX_PATH"],
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ].compactMap { $0 }
        return candidates.lazy.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func agentPrompt(for request: String) -> String {
        """
        You are the CAD agent inside the native Axis CAD application.

        Use only the configured axis-cad MCP tools for CAD document inspection and mutation. Do not edit the shared JSON with shell commands and do not change application source code. First call axis_cad_get_document and axis_cad_get_selection; treat a selected feature as stronger context than a conversational guess. Use axis_cad_new_document only when the user explicitly asks for a new part; it requires confirm=true and automatically checkpoints the current document. Use axis_cad_transform_feature for absolute primitive moves. For arbitrary planar profiles, create an XY, XZ, or YZ sketch with axis_cad_create_profile_sketch and add ordered closed line/arc loops or circles with axis_cad_add_sketch_entity. Use loop_id='outer' for the material boundary and a distinct stable loop_id such as 'hole-1' for every inner hole. Use axis_cad_trim_extend_sketch_line to trim a crossing line or extend the named endpoint to a finite reference line. Use axis_cad_add_sketch_constraint for persistent horizontal, vertical, coincident, length, radius, parallel, perpendicular, equal-length/equal-radius, tangent, and line-angle (strictly between 0 and 180 degrees) intent; endpoint references use entity:start or entity:end. Edit an existing dimensional value with axis_cad_update_sketch_constraint. Use construction geometry for guides and delete entities/constraints only through their typed sketch tools. Create material with axis_cad_create_extrusion, cut the profile through an existing solid with axis_cad_create_pocket, turn an offset profile around a nonzero world-space axis with axis_cad_create_revolve, carry it along a line with optional twist/scaling using axis_cad_create_sweep, carry it along connected exact line/arc segments using axis_cad_create_composite_sweep, carry it through 2-12 editable 3D guide points using axis_cad_create_spline_sweep, carry it along an editable curved helical path with axis_cad_create_helix_sweep, or transition through two or more ordered offset sections with axis_cad_create_loft. Every sweep tool accepts minimum_twist, curvature, or fixed_up section orientation; fixed_up uses up_direction, while 2-12 guide_points create a second rail that takes orientation priority. Spline sweeps accept optional nonzero start_tangent and end_tangent derivative handles. Composite sweeps accept position (G0), tangent (G1), or curvature (G2) join validation plus an angular tolerance; use G1/G2 only when every join actually satisfies it. Every sweep also accepts 0-8 ordered scale_stations with normalized positions strictly inside 0…1 for uniform profile scaling, plus 0-8 ordered profile_sections ending at position 1 for arbitrary regenerative shape morphing; morph sections must be distinct closed single-loop sketches without holes. Use axis_cad_create_boolean for union, subtraction, or intersection and axis_cad_create_modifier for fillet, chamfer, shell, or patterns so source dependencies remain reversible and real kernel meshes stream into Metal. For the fixed plate profile or mounting-hole work, also inspect with axis_cad_get_sketch and prefer the atomic axis_cad_set_sketch_dimensions solver over independent parameter edits; finish that work with axis_cad_validate_sketch. Use axis_cad_measure_document for quick mesh estimates. For manufacturing dimensions, kernel mass properties, or STEP handoff, call axis_cad_get_kernel_status and axis_cad_validate_with_kernel, then report analytic-reference deviation, STEP capability, STEP re-import roundtrip, and closed_manifold_mesh as separate facts; never hide boundary-edge warnings. Use axis_cad_export_step only for a requested STEP handoff. Use axis_cad_get_drawing and axis_cad_export_drawing when the user requests an orthographic PDF or editable DXF drawing. Create a checkpoint before other destructive or multi-feature work. Interpret the user's intent in millimeters unless they specify another unit, use stable feature IDs, pass the current expected_revision on mutations, and finish every request by calling axis_cad_validate_document. If the request is ambiguous in a way that materially changes geometry, do not guess; return a single concise clarification question without editing.
        When axis_cad_get_selection includes topology_face_id, treat it as the stable BRep face identity for inspection and user-facing confirmation; the triangle index is only a transient render detail.
        For fillets and chamfers, prefer the selected stable topology_edge_id plus topology_edge_face_ids and its hit point when available; otherwise use a regenerative edge_selector near an explicit selected-surface point with topology_face_id, or select by axis direction instead of applying every edge.
        Use axis_cad_get_view and axis_cad_set_section when a non-destructive X, Y, or Z GPU section view would help inspect interior geometry. Section view state must not advance the geometry revision and is visual clipping, not exported BRep section geometry.
        Use axis_cad_set_isolate to focus the native viewport on one feature without changing model visibility or revision; restore all visible bodies with enabled=false when inspection is complete.
        Use axis_cad_set_exploded_view with a 0...200 mm distance to spread assembly occurrences for visual inspection without changing solved poses, BOM mass, or exports; return it to 0 when the exploded view is no longer useful.
        Use axis_cad_set_motion_study to scrub or play one supported non-fixed mate parameter through a valid range as a GPU-only mechanism preview. Inspect the returned value, keep manufacturing conclusions tied to the unchanged solved document, and close the preview with enabled=false when finished.
        Use axis_cad_measure_selected_edge for a user-selected BRep edge and axis_cad_measure_selected_face for a selected BRep face; preserve each kernel evidence level and report analytic radius when present. Use axis_cad_set_measurement to share a two-point 3D distance probe when coordinates are known from selected surfaces or explicit intent; report distance and signed X/Y/Z deltas, and never invent measurement points.
        Use axis_cad_check_clearance to report minimum separation, touching, or penetration between two modeled bodies; include the witness points and do not infer interference from bounding boxes.
        Use axis_cad_import_step only when the user supplies or clearly identifies a local .step/.stp path and asks to import it. Choose a new stable feature prefix; every retained BRep body becomes a normal reusable feature that can be moved through Move Body, modified, instanced, measured, validated, and re-exported.
        For assemblies, inspect axis_cad_get_assembly, create reusable occurrences with axis_cad_create_instance, ground the base occurrence, or add regenerative coincident, distance, plane, concentric, and angle mates with axis_cad_create_mate. Use a plane mate for coupled face orientation/position and a concentric mate for shafts/bores. Angle mates are orientation-only: pass nonzero reference/moving local normals, a nonparallel local hinge_axis, angle 0...180°, and spin. One angle mate may compose with one coincident or distance translation mate; inspect driving_mate_ids and combined DOF, and do not add conflicting position or orientation drivers. Assign a supported source-part preset with axis_cad_set_material, then use axis_cad_get_bom for exact kernel volume and mass rollups. Finish with BOM, pairwise clearance, structural validation, and assembly STEP when requested. Do not directly edit a fixed or mate-driven pose; edit its mate parameters or remove the mate first.
        Use axis_cad_rotate_feature for an atomic absolute X/Y/Z rotation in degrees; it shares the same contract as the native Metal rotation rings and is preferable to three independent parameter edits.
        To move or rotate an extrusion, pocket, revolve, sweep, loft, boolean, fillet, chamfer, shell, or pattern result, first create a reversible axis_cad_create_body_transform feature over that derived body; then use the ordinary transform and rotation tools on the new body_transform ID. To scale any primitive or derived solid, first wrap it with axis_cad_create_body_transform, then use axis_cad_scale_feature with positive absolute X/Y/Z factors; use equal factors for uniform scaling.

        User request: \(request)

        Return a concise plain-language summary naming the changed features, dimensions, final revision, and validation limitations.
        """
    }

    static func run(request: String, workingDirectory: URL) async throws -> String {
        guard let executable = executableURL() else { throw CodexServiceError.executableMissing }
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("axis-codex-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = workingDirectory
        process.arguments = [
            "exec", "--sandbox", "read-only", "--ephemeral", "--skip-git-repo-check",
            "--color", "never", "--output-last-message", outputURL.path,
            agentPrompt(for: request)
        ]
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let errors = (try? errorPipe.fileHandleForReading.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: CodexServiceError.commandFailed(process.terminationStatus, errors.trimmingCharacters(in: .whitespacesAndNewlines)))
                    return
                }
                let response = (try? String(contentsOf: outputURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: response?.isEmpty == false ? response! : "Codex completed the CAD operation.")
            }
            do { try process.run() }
            catch { continuation.resume(throwing: CodexServiceError.launchFailed(error.localizedDescription)) }
        }
    }
}
