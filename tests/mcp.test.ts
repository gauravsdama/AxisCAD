import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

let dataDir: string;
let client: Client;

beforeAll(async () => {
  dataDir = await mkdtemp(path.join(tmpdir(), "axis-cad-mcp-"));
  client = new Client({ name: "axis-cad-test", version: "0.1.0" });
  await client.connect(new StdioClientTransport({
    command: process.execPath,
    args: [path.resolve("mcp/server.mjs")],
    env: { ...process.env, AXIS_CAD_DATA_DIR: dataDir } as Record<string, string>
  }));
});

afterAll(async () => {
  await client.close();
  await rm(dataDir, { recursive: true, force: true });
});

describe("Axis CAD MCP", () => {
  it("advertises the safe core tool surface", async () => {
    const tools = await client.listTools();
    expect(tools.tools.map((tool) => tool.name)).toEqual([
      "axis_cad_get_document",
      "axis_cad_get_selection",
      "axis_cad_get_view",
      "axis_cad_set_isolate",
      "axis_cad_set_exploded_view",
      "axis_cad_set_motion_study",
      "axis_cad_set_section",
      "axis_cad_set_measurement",
      "axis_cad_new_document",
      "axis_cad_create_profile_sketch",
      "axis_cad_add_sketch_entity",
      "axis_cad_delete_sketch_entity",
      "axis_cad_set_sketch_entity_construction",
      "axis_cad_add_sketch_constraint",
      "axis_cad_delete_sketch_constraint",
      "axis_cad_update_sketch_constraint",
      "axis_cad_trim_extend_sketch_line",
      "axis_cad_create_extrusion",
      "axis_cad_create_pocket",
      "axis_cad_create_revolve",
      "axis_cad_create_sweep",
      "axis_cad_create_spline_sweep",
      "axis_cad_create_composite_sweep",
      "axis_cad_create_helix_sweep",
      "axis_cad_create_loft",
      "axis_cad_set_parameter",
      "axis_cad_transform_feature",
      "axis_cad_rotate_feature",
      "axis_cad_create_body_transform",
      "axis_cad_scale_feature",
      "axis_cad_get_assembly",
      "axis_cad_set_material",
      "axis_cad_get_bom",
      "axis_cad_add_sourcing_candidate",
      "axis_cad_list_sourcing_candidates",
      "axis_cad_validate_sourcing_candidate",
      "axis_cad_create_instance",
      "axis_cad_create_mate",
      "axis_cad_get_sketch",
      "axis_cad_set_sketch_dimensions",
      "axis_cad_validate_sketch",
      "axis_cad_apply_edits",
      "axis_cad_create_feature",
      "axis_cad_create_boolean",
      "axis_cad_create_modifier",
      "axis_cad_delete_feature",
      "axis_cad_validate_document",
      "axis_cad_measure_document",
      "axis_cad_measure_selected_edge",
      "axis_cad_measure_selected_face",
      "axis_cad_get_kernel_status",
      "axis_cad_check_clearance",
      "axis_cad_import_step",
      "axis_cad_validate_with_kernel",
      "axis_cad_export_step",
      "axis_cad_export_assembly_step",
      "axis_cad_get_drawing",
      "axis_cad_export_drawing",
      "axis_cad_checkpoint_document",
      "axis_cad_list_checkpoints",
      "axis_cad_restore_checkpoint"
    ]);
  });

  it("stores research-only sourcing candidates and flags interface gaps", async () => {
    const added = await client.callTool({ name: "axis_cad_add_sourcing_candidate", arguments: {
      id: "fixture-actuator", manufacturer: "Fixture Motion", part_number: "FM-200", description: "24 V seating actuator",
      source_url: "https://example.com/FM-200", category: "actuator", interface_notes: "Fixture only; 1,500 N, 200 mm, 24 V.",
      load_rating_n: 1500, stroke_mm: 200, voltage_v: 24, license_notes: "Fixture supplier data."
    } });
    expect(added.structuredContent).toMatchObject({ id: "fixture-actuator", status: "candidate", load_rating_n: 1500, stroke_mm: 200, voltage_v: 24 });

    const listed = await client.callTool({ name: "axis_cad_list_sourcing_candidates", arguments: {} });
    expect(listed.structuredContent).toMatchObject({ count: 1, candidates: [expect.objectContaining({ id: "fixture-actuator" })] });

    const compatible = await client.callTool({ name: "axis_cad_validate_sourcing_candidate", arguments: {
      candidate_id: "fixture-actuator", feature_id: "pad-base", required_load_n: 1200, required_stroke_mm: 150, required_voltage_v: 24
    } });
    expect(compatible.structuredContent).toMatchObject({ candidate_id: "fixture-actuator", feature_id: "pad-base", compatible: true });

    const insufficient = await client.callTool({ name: "axis_cad_validate_sourcing_candidate", arguments: {
      candidate_id: "fixture-actuator", feature_id: "pad-base", required_load_n: 1600, required_stroke_mm: 220, required_voltage_v: 48
    } });
    expect(insufficient.structuredContent).toMatchObject({ compatible: false });
    expect((insufficient.structuredContent as { warnings: string[] }).warnings).toEqual(expect.arrayContaining([
      expect.stringContaining("below required 1600 N"), expect.stringContaining("below required 220 mm"), expect.stringContaining("differs from required 48 V")
    ]));
  });

  it("inspects, edits, and validates one revisioned document", async () => {
    const inspected = await client.callTool({ name: "axis_cad_get_document", arguments: {} });
    expect(inspected.structuredContent).toMatchObject({ revision: 18, backend: "native-metal" });

    const edited = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 18, feature_id: "pocket-holes", parameter: "diameter", value: 6 } });
    expect(edited.structuredContent).toMatchObject({ ok: true, revision: 19, previous_value: 5, value: 6 });

    const validated = await client.callTool({ name: "axis_cad_validate_document", arguments: {} });
    expect(validated.structuredContent).toMatchObject({ ok: true, revision: 19, errors: [] });
    const measured = await client.callTool({ name: "axis_cad_measure_document", arguments: {} });
    expect(measured.structuredContent).toMatchObject({ revision: 19, units: "mm", bounds: { size: { x: 86, y: 54, z: 6 } }, exact_mass_properties: false });
  });

  it("applies multi-feature edits atomically and checkpoints the result", async () => {
    const edited = await client.callTool({
      name: "axis_cad_apply_edits",
      arguments: {
        expected_revision: 19,
        edits: [
          { action: "set_parameter", feature_id: "sketch-base", parameter: "width", value: 100 },
          { action: "rename_feature", feature_id: "sketch-base", name: "Wider base profile" }
        ]
      }
    });
    expect(edited.structuredContent).toMatchObject({ ok: true, revision: 20, edits_applied: 2 });

    const checkpoint = await client.callTool({ name: "axis_cad_checkpoint_document", arguments: { label: "wider bracket" } });
    expect(checkpoint.structuredContent).toMatchObject({ ok: true, revision: 20, checkpoint_id: "r20-wider-bracket" });

    const listed = await client.callTool({ name: "axis_cad_list_checkpoints", arguments: {} });
    expect(listed.structuredContent).toMatchObject({ total_count: 1, checkpoint_ids: ["r20-wider-bracket"] });
  });

  it("solves one symmetric constrained sketch atomically", async () => {
    const solved = await client.callTool({
      name: "axis_cad_set_sketch_dimensions",
      arguments: { expected_revision: 20, width: 96, height: 60, hole_diameter: 6, hole_offset: 14 }
    });
    expect(solved.structuredContent).toMatchObject({ ok: true, revision: 21, sketch: { fully_constrained: true, degrees_of_freedom: 0, constraint_count: 11 } });

    const inspected = await client.callTool({ name: "axis_cad_get_sketch", arguments: {} });
    expect(inspected.structuredContent).toMatchObject({ width: 96, height: 60, hole_diameter: 6, hole_offset: 14 });
    const validated = await client.callTool({ name: "axis_cad_validate_sketch", arguments: {} });
    expect(validated.structuredContent).toMatchObject({ ok: true, revision: 21, fully_constrained: true });
  });

  it("returns an actionable tool error for stale edits without changing state", async () => {
    const stale = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 18, feature_id: "pad-base", parameter: "length", value: 9 } });
    expect(stale.isError).toBe(true);
    expect(stale.content).toEqual(expect.arrayContaining([expect.objectContaining({ text: expect.stringContaining("revision_conflict") })]));
    const inspected = await client.callTool({ name: "axis_cad_get_document", arguments: {} });
    expect(inspected.structuredContent).toMatchObject({ revision: 21 });
  });

  it("checkpoints before creating a new AI-editable part", async () => {
    const created = await client.callTool({ name: "axis_cad_new_document", arguments: { expected_revision: 21, name: "Fresh fixture", confirm: true } });
    expect(created.structuredContent).toMatchObject({ ok: true, revision: 22, document_id: "part-r22", name: "Fresh fixture", checkpoint_id: "r21-before-new-document" });
    const inspected = await client.callTool({ name: "axis_cad_get_document", arguments: {} });
    expect(inspected.structuredContent).toMatchObject({ revision: 22, name: "Fresh fixture" });
  });

  it("reads native selection context without changing revision", async () => {
    const selection = await client.callTool({ name: "axis_cad_get_selection", arguments: {} });
    expect(selection.structuredContent).toMatchObject({ revision: 22, feature_ids: [], features: [], surface: null });
    await writeFile(path.join(dataDir, "active-selection.json"), JSON.stringify({ revision: 22, feature_ids: ["pad-base"], surface: {
      feature_id: "pad-base", triangle_index: 4, topology_face_id: 2, topology_edge_id: 7, topology_edge_face_ids: [2, 5], position: { x: 2, y: 3, z: 3 }, normal: { x: 0, y: 0, z: 1 }
    } }));
    const surface = await client.callTool({ name: "axis_cad_get_selection", arguments: {} });
    expect(surface.structuredContent).toMatchObject({ revision: 22, feature_ids: ["pad-base"], features: [{ id: "pad-base" }], surface: {
      feature_id: "pad-base", triangle_index: 4, topology_face_id: 2, topology_edge_id: 7, topology_edge_face_ids: [2, 5], position: { x: 2, y: 3, z: 3 }, normal: { x: 0, y: 0, z: 1 }
    } });
    const initialView = await client.callTool({ name: "axis_cad_get_view", arguments: {} });
    expect(initialView.structuredContent).toMatchObject({ revision: 22, section: null, measurement: null, isolated_feature_id: null, exploded_distance: 0, motion_study: null });
    const isolated = await client.callTool({ name: "axis_cad_set_isolate", arguments: { expected_revision: 22, enabled: true, feature_id: "pad-base" } });
    expect(isolated.structuredContent).toMatchObject({ ok: true, revision: 22, isolated_feature_id: "pad-base" });
    const section = await client.callTool({ name: "axis_cad_set_section", arguments: { expected_revision: 22, enabled: true, axis: "x", offset: 5, flipped: true } });
    expect(section.structuredContent).toMatchObject({ ok: true, revision: 22, section: { axis: "x", offset: 5, flipped: true } });
    const view = await client.callTool({ name: "axis_cad_get_view", arguments: {} });
    expect(view.structuredContent).toMatchObject({ revision: 22, section: { axis: "x", offset: 5, flipped: true } });
    const exploded = await client.callTool({ name: "axis_cad_set_exploded_view", arguments: { expected_revision: 22, distance: 35 } });
    expect(exploded.structuredContent).toMatchObject({ ok: true, revision: 22, exploded_distance: 35 });
    const measured = await client.callTool({ name: "axis_cad_set_measurement", arguments: {
      expected_revision: 22, enabled: true, start: { x: 0, y: 0, z: 0 }, end: { x: 3, y: 4, z: 12 }
    } });
    expect(measured.structuredContent).toMatchObject({ ok: true, revision: 22, measurement: {
      revision: 22, distance: 13, delta: { x: 3, y: 4, z: 12 }
    } });
    const cleared = await client.callTool({ name: "axis_cad_set_section", arguments: { expected_revision: 22, enabled: false } });
    expect(cleared.structuredContent).toMatchObject({ ok: true, revision: 22, section: null });
    const measurementPreserved = await client.callTool({ name: "axis_cad_get_view", arguments: {} });
    expect(measurementPreserved.structuredContent).toMatchObject({ revision: 22, section: null, measurement: { distance: 13 }, isolated_feature_id: "pad-base", exploded_distance: 35 });
    const measurementCleared = await client.callTool({ name: "axis_cad_set_measurement", arguments: { expected_revision: 22, enabled: false } });
    expect(measurementCleared.structuredContent).toMatchObject({ ok: true, revision: 22, measurement: null });
    const shown = await client.callTool({ name: "axis_cad_set_isolate", arguments: { expected_revision: 22, enabled: false } });
    expect(shown.structuredContent).toMatchObject({ ok: true, revision: 22, isolated_feature_id: null });
    const collapsed = await client.callTool({ name: "axis_cad_set_exploded_view", arguments: { expected_revision: 22, distance: 0 } });
    expect(collapsed.structuredContent).toMatchObject({ ok: true, revision: 22, exploded_distance: 0 });
  });

  it("moves a primitive atomically through the same transform contract as the viewport", async () => {
    const created = await client.callTool({
      name: "axis_cad_create_feature",
      arguments: { expected_revision: 22, feature_id: "box-transform", name: "Transform fixture", kind: "box", params: { width: 10, height: 12, depth: 8, x: 0, y: 0, z: 10 } }
    });
    expect(created.structuredContent).toMatchObject({ ok: true, revision: 23 });
    const staleSurface = await client.callTool({ name: "axis_cad_get_selection", arguments: {} });
    expect(staleSurface.structuredContent).toMatchObject({ revision: 23, feature_ids: ["pad-base"], surface: null });
    const moved = await client.callTool({
      name: "axis_cad_transform_feature",
      arguments: { expected_revision: 23, feature_id: "box-transform", x: -15, y: 8, z: 12 }
    });
    expect(moved.structuredContent).toMatchObject({ ok: true, revision: 24, previous_position: { x: 0, y: 0, z: 10 }, position: { x: -15, y: 8, z: 12 } });
  });

  it("loads the external BRep kernel, surfaces manifold evidence, and exports STEP", async () => {
    const status = await client.callTool({ name: "axis_cad_get_kernel_status", arguments: {} });
    expect(status.structuredContent).toMatchObject({ available: true, adapter: "vcad-wasm", version: "0.9.4", bundled_with_app: false });

    const base = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "pad-base" } });
    expect(base.structuredContent).toMatchObject({
      revision: 24, feature_id: "base-bracket", kernel_mass_properties: true, can_export_step: true, volume_within_one_percent: true,
      ok: true, closed_manifold_mesh: true, boundary_edge_segments: 0, step_roundtrip: { passed: true, body_count: 1 }
    });
    const analyticVolume = 86 * 54 * 6 - 4 * Math.PI * 2.5 * 2.5 * 6;
    expect(Math.abs((base.structuredContent as { volume: number }).volume - analyticVolume)).toBeLessThan(2);
    expect((base.structuredContent as { warnings: string[] }).warnings).toEqual([]);

    const primitive = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "box-transform" } });
    expect(primitive.structuredContent).toMatchObject({ ok: true, feature_id: "box-transform", volume: 960, closed_manifold_mesh: true, can_export_step: true });
    await writeFile(path.join(dataDir, "active-selection.json"), JSON.stringify({ revision: 24, feature_ids: ["box-transform"], surface: {
      feature_id: "box-transform", triangle_index: 0, topology_face_id: 0, topology_edge_id: 0, topology_edge_face_ids: [0, 2], position: { x: -20, y: 2, z: 8 }, normal: { x: 0, y: 0, z: -1 }
    } }));
    const edgeMeasurement = await client.callTool({ name: "axis_cad_measure_selected_edge", arguments: {} });
    expect(edgeMeasurement.structuredContent).toMatchObject({ revision: 24, units: "mm", feature_id: "box-transform", topology_edge_id: 0, adjacent_face_ids: [0, 2], segment_count: 1, exact: true, exact_for_linear_edge: true, curve_kind: "line", radius: null, evidence: "exact-linear-brep-boundary" });
    expect((edgeMeasurement.structuredContent as { length: number }).length).toBeGreaterThan(0);
    await writeFile(path.join(dataDir, "active-selection.json"), JSON.stringify({ revision: 24, feature_ids: ["box-transform"], surface: {
      feature_id: "box-transform", triangle_index: 0, topology_face_id: 0, position: { x: -20, y: 2, z: 8 }, normal: { x: 0, y: 0, z: -1 }
    } }));
    const faceMeasurement = await client.callTool({ name: "axis_cad_measure_selected_face", arguments: {} });
    expect(faceMeasurement.structuredContent).toMatchObject({ revision: 24, units: "mm", feature_id: "box-transform", topology_face_id: 0, exact: true, surface_kind: "plane", radius: null, evidence: "exact-analytic-brep-face" });
    expect((faceMeasurement.structuredContent as { area: number }).area).toBeGreaterThan(0);

    const exported = await client.callTool({ name: "axis_cad_export_step", arguments: { feature_id: "pad-base", filename_prefix: "fixture" } });
    expect(exported.structuredContent).toMatchObject({ ok: true, revision: 24, feature_id: "base-bracket", adapter: "vcad-wasm" });
    const step = await readFile((exported.structuredContent as { path: string }).path, "utf8");
    expect(step).toMatch(/^ISO-10303-21;/);
    expect(step).toContain("AUTOMOTIVE_DESIGN");
    expect(step).toContain("MANIFOLD_SOLID_BREP");
  });

  it("creates, measures, and kernel-validates advanced GPU primitives", async () => {
    const fixtures = [
      { feature_id: "cone-fixture", name: "Cone fixture", kind: "cone", params: { radius_bottom: 10, radius_top: 4, height: 24, x: 0, y: 28, z: 15 } },
      { feature_id: "sphere-fixture", name: "Sphere fixture", kind: "sphere", params: { radius: 9, x: 30, y: 0, z: 14 } },
      { feature_id: "torus-fixture", name: "Torus fixture", kind: "torus", params: { major_radius: 14, tube_radius: 4, x: -30, y: 0, z: 14 } }
    ] as const;
    let revision = 24;
    for (const fixture of fixtures) {
      const created = await client.callTool({ name: "axis_cad_create_feature", arguments: { expected_revision: revision, ...fixture } });
      revision += 1;
      expect(created.structuredContent).toMatchObject({ ok: true, revision, feature: { id: fixture.feature_id, kind: fixture.kind } });
      const validated = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: fixture.feature_id } });
      expect(validated.structuredContent).toMatchObject({ ok: true, revision, feature_id: fixture.feature_id, closed_manifold_mesh: true, can_export_step: true, step_roundtrip: { attempted: true, passed: true, body_count: 1 } });
    }
    const clearance = await client.callTool({ name: "axis_cad_check_clearance", arguments: { feature_id: "box-transform", second_feature_id: "sphere-fixture" } });
    expect(clearance.structuredContent).toMatchObject({ ok: true, revision: 27, feature_id: "box-transform", second_feature_id: "sphere-fixture", classification: "clear", intersecting: false, adapter: "vcad-wasm" });
    expect((clearance.structuredContent as { distance: number }).distance).toBeGreaterThan(0);
    const rotated = await client.callTool({
      name: "axis_cad_rotate_feature", arguments: { expected_revision: 27, feature_id: "torus-fixture", x_degrees: 90, y_degrees: 0, z_degrees: 0 }
    });
    expect(rotated.structuredContent).toMatchObject({ ok: true, revision: 28, feature_id: "torus-fixture", previous_rotation: { x_degrees: 0, y_degrees: 0, z_degrees: 0 }, rotation: { x_degrees: 90, y_degrees: 0, z_degrees: 0 } });
    const rotatedKernel = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "torus-fixture" } });
    expect(rotatedKernel.structuredContent).toMatchObject({ ok: true, revision: 28, feature_id: "torus-fixture" });
    const measured = await client.callTool({ name: "axis_cad_measure_document", arguments: {} });
    expect(measured.structuredContent).toMatchObject({ revision: 28 });
    expect((measured.structuredContent as { bounds: { maximum: { z: number } } }).bounds.maximum.z).toBe(32);

    const invalid = await client.callTool({
      name: "axis_cad_set_parameter", arguments: { expected_revision: 28, feature_id: "torus-fixture", parameter: "major_radius", value: 2 }
    });
    expect(invalid.isError).toBe(true);
    expect((await client.callTool({ name: "axis_cad_get_document", arguments: {} })).structuredContent).toMatchObject({ revision: 28 });
  });

  it("creates a dependency-aware boolean and restores inputs when deleted", async () => {
    const left = await client.callTool({ name: "axis_cad_create_feature", arguments: {
      expected_revision: 28, feature_id: "boolean-box", name: "Boolean box", kind: "box", params: { width: 24, height: 24, depth: 18, x: 0, y: 0, z: 14 }
    } });
    expect(left.structuredContent).toMatchObject({ revision: 29 });
    const right = await client.callTool({ name: "axis_cad_create_feature", arguments: {
      expected_revision: 29, feature_id: "boolean-cylinder", name: "Boolean cylinder", kind: "cylinder", params: { radius: 9, height: 24, x: 0, y: 0, z: 14 }
    } });
    expect(right.structuredContent).toMatchObject({ revision: 30 });
    const combined = await client.callTool({ name: "axis_cad_create_boolean", arguments: {
      expected_revision: 30, feature_id: "boolean-union", name: "Joined fixture", operation: "union", left_feature_id: "boolean-box", right_feature_id: "boolean-cylinder"
    } });
    expect(combined.structuredContent).toMatchObject({ ok: true, revision: 31, feature: { id: "boolean-union", kind: "boolean_union", input_feature_ids: ["boolean-box", "boolean-cylinder"] }, suppressed_feature_ids: ["boolean-box", "boolean-cylinder"] });
    const kernel = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "boolean-union" } });
    expect(kernel.structuredContent).toMatchObject({ revision: 31, feature_id: "boolean-union", can_export_step: true });
    expect((kernel.structuredContent as { triangle_count: number }).triangle_count).toBeGreaterThan(20);
    const protectedInput = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 31, feature_id: "boolean-box", confirm: true } });
    expect(protectedInput.isError).toBe(true);
    expect((await client.callTool({ name: "axis_cad_get_document", arguments: {} })).structuredContent).toMatchObject({ revision: 31 });
    const removed = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 31, feature_id: "boolean-union", confirm: true } });
    expect(removed.structuredContent).toMatchObject({ ok: true, revision: 32, deleted_feature_id: "boolean-union" });
    const document = await client.callTool({ name: "axis_cad_get_document", arguments: {} });
    const features = (document.structuredContent as { features: Array<{ id: string; visible: boolean }> }).features;
    expect(features.find((feature) => feature.id === "boolean-box")?.visible).toBe(true);
    expect(features.find((feature) => feature.id === "boolean-cylinder")?.visible).toBe(true);
  });

  it("creates an editable kernel modifier and preserves its source dependency", async () => {
    const modified = await client.callTool({ name: "axis_cad_create_modifier", arguments: {
      expected_revision: 32, feature_id: "fillet-fixture", name: "Filleted fixture", modifier: "edge_fillet", input_feature_id: "boolean-box", params: { radius: 1.5 },
      edge_selector: { type: "topology", edge_id: 0, adjacent_face_ids: [0, 2], fallback_point: { x: -18, y: -10, z: 5 }, topology_face_id: 0 }
    } });
    expect(modified.structuredContent).toMatchObject({ ok: true, revision: 33, feature: { id: "fillet-fixture", kind: "edge_fillet", params: { radius: 1.5, selector_mode: 3, selector_edge_id: 0, selector_edge_face_a: 0, selector_edge_face_b: 2, selector_x: -18, selector_y: -10, selector_z: 5, selector_face_id: 0 }, input_feature_ids: ["boolean-box"] }, suppressed_feature_ids: ["boolean-box"] });
    const kernel = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "fillet-fixture" } });
    expect(kernel.structuredContent).toMatchObject({ revision: 33, feature_id: "fillet-fixture", can_export_step: true });
    expect((kernel.structuredContent as { triangle_count: number }).triangle_count).toBeGreaterThan(12);
    const resized = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 33, feature_id: "fillet-fixture", parameter: "radius", value: 2 } });
    expect(resized.structuredContent).toMatchObject({ ok: true, revision: 34, value: 2 });
    const measured = await client.callTool({ name: "axis_cad_measure_document", arguments: {} });
    expect(measured.structuredContent).toMatchObject({ revision: 34 });
    expect((measured.structuredContent as { warning: string }).warning).toContain("kernel-derived properties");
    const removed = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 34, feature_id: "fillet-fixture", confirm: true } });
    expect(removed.structuredContent).toMatchObject({ ok: true, revision: 35 });
  });

  it("creates an arbitrary closed profile and kernel-backed extrusion", async () => {
    const sketch = await client.callTool({ name: "axis_cad_create_profile_sketch", arguments: { expected_revision: 35, feature_id: "custom-profile", name: "Custom profile", plane: "XY" } });
    expect(sketch.structuredContent).toMatchObject({ ok: true, revision: 36, feature: { id: "custom-profile", kind: "profile_sketch", sketch: { plane: "XY", entities: [] } } });
    const lines = [
      { entity_id: "edge-a", params: { x1: -10, y1: -5, x2: 10, y2: -5 } },
      { entity_id: "edge-b", params: { x1: 10, y1: -5, x2: 10, y2: 5 } },
      { entity_id: "edge-c", params: { x1: 10, y1: 5, x2: -10, y2: 5 } },
      { entity_id: "edge-d", params: { x1: -10, y1: 5, x2: -10, y2: -5 } }
    ];
    let revision = 36;
    for (const line of lines) {
      const added = await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: revision, sketch_id: "custom-profile", kind: "line", construction: false, ...line } });
      revision += 1;
      expect(added.structuredContent).toMatchObject({ ok: true, revision, profile: { closed: revision === 40, entity_count: revision - 36 } });
    }
    const extruded = await client.callTool({ name: "axis_cad_create_extrusion", arguments: { expected_revision: 40, feature_id: "custom-extrude", name: "Custom extrusion", sketch_id: "custom-profile", length: 8, symmetric: true } });
    expect(extruded.structuredContent).toMatchObject({ ok: true, revision: 41, feature: { id: "custom-extrude", kind: "extrude_feature", params: { length: 8, symmetric: 1 }, input_feature_ids: ["custom-profile"] }, profile_entity_count: 4 });
    const kernel = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "custom-extrude" } });
    expect(kernel.structuredContent).toMatchObject({ ok: true, revision: 41, feature_id: "custom-extrude", can_export_step: true, closed_manifold_mesh: true });
    expect((kernel.structuredContent as { volume: number }).volume).toBeCloseTo(1600, 5);
    const resized = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 41, feature_id: "custom-extrude", parameter: "length", value: 12 } });
    expect(resized.structuredContent).toMatchObject({ revision: 42, value: 12 });
    const removedExtrude = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 42, feature_id: "custom-extrude", confirm: true } });
    expect(removedExtrude.structuredContent).toMatchObject({ revision: 43 });
    const removedSketch = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 43, feature_id: "custom-profile", confirm: true } });
    expect(removedSketch.structuredContent).toMatchObject({ revision: 44 });
  });

  it("cuts a reversible sketch-driven pocket through an existing solid", async () => {
    const sketch = await client.callTool({ name: "axis_cad_create_profile_sketch", arguments: { expected_revision: 44, feature_id: "pocket-profile", name: "Pocket profile", plane: "XY" } });
    expect(sketch.structuredContent).toMatchObject({ ok: true, revision: 45 });
    const circle = await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: {
      expected_revision: 45, sketch_id: "pocket-profile", entity_id: "pocket-circle", kind: "circle", params: { cx: 0, cy: 0, radius: 3 }, construction: false
    } });
    expect(circle.structuredContent).toMatchObject({ ok: true, revision: 46, profile: { closed: true, entity_count: 1 } });
    const pocket = await client.callTool({ name: "axis_cad_create_pocket", arguments: {
      expected_revision: 46, feature_id: "custom-pocket", name: "Center pocket", target_feature_id: "boolean-box", sketch_id: "pocket-profile", length: 40, symmetric: false
    } });
    expect(pocket.structuredContent).toMatchObject({
      ok: true, revision: 47,
      feature: { id: "custom-pocket", kind: "pocket_feature", params: { length: 40, symmetric: 0 }, input_feature_ids: ["boolean-box", "pocket-profile"] },
      suppressed_feature_ids: ["boolean-box", "pocket-profile"]
    });
    const kernel = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "custom-pocket" } });
    expect(kernel.structuredContent).toMatchObject({ ok: true, revision: 47, feature_id: "custom-pocket", can_export_step: true, closed_manifold_mesh: true, boundary_edge_segments: 0, step_roundtrip: { passed: true } });
    expect((kernel.structuredContent as { volume: number }).volume).toBeLessThan(11_520);
    const removedPocket = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 47, feature_id: "custom-pocket", confirm: true } });
    expect(removedPocket.structuredContent).toMatchObject({ revision: 48 });
    const document = await client.callTool({ name: "axis_cad_get_document", arguments: {} });
    const features = (document.structuredContent as { features: Array<{ id: string; visible: boolean }> }).features;
    expect(features.find((feature) => feature.id === "boolean-box")?.visible).toBe(true);
    expect(features.find((feature) => feature.id === "pocket-profile")?.visible).toBe(true);
    const removedSketch = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 48, feature_id: "pocket-profile", confirm: true } });
    expect(removedSketch.structuredContent).toMatchObject({ revision: 49 });
  });

  it("revolves an offset closed profile around an arbitrary axis", async () => {
    const sketch = await client.callTool({ name: "axis_cad_create_profile_sketch", arguments: { expected_revision: 49, feature_id: "revolve-profile", name: "Revolve profile", plane: "XY" } });
    expect(sketch.structuredContent).toMatchObject({ ok: true, revision: 50 });
    const lines = [
      { entity_id: "revolve-a", params: { x1: 5, y1: -4, x2: 10, y2: -4 } },
      { entity_id: "revolve-b", params: { x1: 10, y1: -4, x2: 10, y2: 4 } },
      { entity_id: "revolve-c", params: { x1: 10, y1: 4, x2: 5, y2: 4 } },
      { entity_id: "revolve-d", params: { x1: 5, y1: 4, x2: 5, y2: -4 } }
    ];
    let revision = 50;
    for (const line of lines) {
      const added = await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: revision, sketch_id: "revolve-profile", kind: "line", construction: false, ...line } });
      revision += 1;
      expect(added.structuredContent).toMatchObject({ ok: true, revision });
    }
    const revolved = await client.callTool({ name: "axis_cad_create_revolve", arguments: {
      expected_revision: 54, feature_id: "custom-revolve", name: "Revolved ring", sketch_id: "revolve-profile", angle: 360,
      axis: { x: 0, y: 2, z: 0 }, origin: { x: 0, y: 0, z: 0 }
    } });
    expect(revolved.structuredContent).toMatchObject({
      ok: true, revision: 55,
      feature: { id: "custom-revolve", kind: "revolve_feature", params: { angle: 360, axis_x: 0, axis_y: 1, axis_z: 0 }, input_feature_ids: ["revolve-profile"] },
      profile_entity_count: 4
    });
    const kernel = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "custom-revolve" } });
    expect(kernel.structuredContent).toMatchObject({
      ok: true, revision: 55, feature_id: "custom-revolve", can_export_step: true,
      closed_manifold_mesh: true, boundary_edge_segments: 0, step_roundtrip: { passed: true }, warnings: []
    });
    const expectedVolume = Math.PI * 75 * 8;
    expect(Math.abs((kernel.structuredContent as { volume: number }).volume - expectedVolume) / expectedVolume).toBeLessThan(0.01);
    const resized = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 55, feature_id: "custom-revolve", parameter: "angle", value: 180 } });
    expect(resized.structuredContent).toMatchObject({ ok: true, revision: 56, value: 180 });
    const halfKernel = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "custom-revolve" } });
    expect(halfKernel.structuredContent).toMatchObject({ ok: true, revision: 56, closed_manifold_mesh: true, boundary_edge_segments: 0, step_roundtrip: { passed: true }, warnings: [] });
    const removed = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 56, feature_id: "custom-revolve", confirm: true } });
    expect(removed.structuredContent).toMatchObject({ revision: 57 });
    const removedSketch = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 57, feature_id: "revolve-profile", confirm: true } });
    expect(removedSketch.structuredContent).toMatchObject({ revision: 58 });
  });

  it("sweeps a closed profile along an editable line path", async () => {
    const sketch = await client.callTool({ name: "axis_cad_create_profile_sketch", arguments: { expected_revision: 58, feature_id: "sweep-profile", name: "Sweep profile", plane: "XY" } });
    expect(sketch.structuredContent).toMatchObject({ ok: true, revision: 59 });
    const circle = await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: {
      expected_revision: 59, sketch_id: "sweep-profile", entity_id: "sweep-circle", kind: "circle", params: { cx: 0, cy: 0, radius: 2 }, construction: false
    } });
    expect(circle.structuredContent).toMatchObject({ ok: true, revision: 60, profile: { closed: true } });
    const swept = await client.callTool({ name: "axis_cad_create_sweep", arguments: {
      expected_revision: 60, feature_id: "custom-sweep", name: "Swept tube", sketch_id: "sweep-profile",
      start: { x: 0, y: 0, z: 0 }, end: { x: 0, y: 0, z: 40 }, twist_angle: 0, scale_start: 1, scale_end: 1
    } });
    expect(swept.structuredContent).toMatchObject({
      ok: true, revision: 61, path_length: 40,
      feature: { id: "custom-sweep", kind: "sweep_feature", params: { end_z: 40, twist_angle: 0, scale_start: 1, scale_end: 1 }, input_feature_ids: ["sweep-profile"] }
    });
    const kernel = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "custom-sweep" } });
    expect(kernel.structuredContent).toMatchObject({ revision: 61, feature_id: "custom-sweep", can_export_step: true });
    const expectedVolume = Math.PI * 4 * 40;
    expect(Math.abs((kernel.structuredContent as { volume: number }).volume - expectedVolume) / expectedVolume).toBeLessThan(0.01);
    const extended = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 61, feature_id: "custom-sweep", parameter: "end_z", value: 60 } });
    expect(extended.structuredContent).toMatchObject({ ok: true, revision: 62, value: 60 });
    const removed = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 62, feature_id: "custom-sweep", confirm: true } });
    expect(removed.structuredContent).toMatchObject({ revision: 63 });
    const removedSketch = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 63, feature_id: "sweep-profile", confirm: true } });
    expect(removedSketch.structuredContent).toMatchObject({ revision: 64 });
  });

  it("lofts between editable offset profile sections", async () => {
    const lower = await client.callTool({ name: "axis_cad_create_profile_sketch", arguments: { expected_revision: 64, feature_id: "loft-lower", name: "Lower section", plane: "XY", offset: 0 } });
    expect(lower.structuredContent).toMatchObject({ ok: true, revision: 65, feature: { params: { offset: 0 } } });
    await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: 65, sketch_id: "loft-lower", entity_id: "lower-circle", kind: "circle", params: { cx: 0, cy: 0, radius: 5 }, construction: false } });
    const upper = await client.callTool({ name: "axis_cad_create_profile_sketch", arguments: { expected_revision: 66, feature_id: "loft-upper", name: "Upper section", plane: "XY", offset: 20 } });
    expect(upper.structuredContent).toMatchObject({ ok: true, revision: 67, feature: { params: { offset: 20 } } });
    await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: 67, sketch_id: "loft-upper", entity_id: "upper-circle", kind: "circle", params: { cx: 0, cy: 0, radius: 2 }, construction: false } });
    const lofted = await client.callTool({ name: "axis_cad_create_loft", arguments: {
      expected_revision: 68, feature_id: "custom-loft", name: "Tapered loft", sketch_ids: ["loft-lower", "loft-upper"], closed: false
    } });
    expect(lofted.structuredContent).toMatchObject({
      ok: true, revision: 69, profile_count: 2, suppressed_feature_ids: ["loft-lower", "loft-upper"],
      feature: { id: "custom-loft", kind: "loft_feature", params: { closed: 0 }, input_feature_ids: ["loft-lower", "loft-upper"] }
    });
    const initial = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "custom-loft" } });
    expect(initial.structuredContent).toMatchObject({ revision: 69, feature_id: "custom-loft", can_export_step: true });
    const initialVolume = (initial.structuredContent as { volume: number }).volume;
    expect(initialVolume).toBeGreaterThan(400);
    expect(initialVolume).toBeLessThan(1_200);
    const moved = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 69, feature_id: "loft-upper", parameter: "offset", value: 30 } });
    expect(moved.structuredContent).toMatchObject({ ok: true, revision: 70, value: 30 });
    const extended = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "custom-loft" } });
    expect(Math.abs((extended.structuredContent as { volume: number }).volume / initialVolume - 1.5)).toBeLessThan(0.03);
    const removed = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 70, feature_id: "custom-loft", confirm: true } });
    expect(removed.structuredContent).toMatchObject({ revision: 71 });
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 71, feature_id: "loft-lower", confirm: true } });
    const removedUpper = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 72, feature_id: "loft-upper", confirm: true } });
    expect(removedUpper.structuredContent).toMatchObject({ revision: 73 });
  });

  it("solves persistent general sketch constraints and manages construction geometry", async () => {
    await client.callTool({ name: "axis_cad_create_profile_sketch", arguments: { expected_revision: 73, feature_id: "constraint-sketch", name: "Constraint sketch", plane: "XY", offset: 0 } });
    await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: 74, sketch_id: "constraint-sketch", entity_id: "constraint-line-a", kind: "line", params: { x1: 0, y1: 0, x2: 9, y2: 2 }, construction: false } });
    await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: 75, sketch_id: "constraint-sketch", entity_id: "constraint-line-b", kind: "line", params: { x1: 12, y1: 3, x2: 14, y2: 10 }, construction: false } });
    const horizontal = await client.callTool({ name: "axis_cad_add_sketch_constraint", arguments: {
      expected_revision: 76, sketch_id: "constraint-sketch", constraint_id: "horizontal-a", kind: "horizontal", entities: ["constraint-line-a"]
    } });
    expect(horizontal.structuredContent).toMatchObject({ ok: true, revision: 77, constraint: { kind: "horizontal" }, profile: { constraint_count: 1, degrees_of_freedom: 7 } });
    const coincident = await client.callTool({ name: "axis_cad_add_sketch_constraint", arguments: {
      expected_revision: 77, sketch_id: "constraint-sketch", constraint_id: "join-lines", kind: "coincident", entities: ["constraint-line-a:end", "constraint-line-b:start"]
    } });
    expect(coincident.structuredContent).toMatchObject({ ok: true, revision: 78, profile: { constraint_count: 2, degrees_of_freedom: 5 } });
    const vertical = await client.callTool({ name: "axis_cad_add_sketch_constraint", arguments: {
      expected_revision: 78, sketch_id: "constraint-sketch", constraint_id: "vertical-b", kind: "vertical", entities: ["constraint-line-b"]
    } });
    expect(vertical.structuredContent).toMatchObject({ ok: true, revision: 79, profile: { constraint_count: 3, degrees_of_freedom: 4 } });
    const length = await client.callTool({ name: "axis_cad_add_sketch_constraint", arguments: {
      expected_revision: 79, sketch_id: "constraint-sketch", constraint_id: "length-a", kind: "length", entities: ["constraint-line-a"], value: 9
    } });
    expect(length.structuredContent).toMatchObject({ ok: true, revision: 80, constraint: { value: 9 }, profile: { constraint_count: 4, degrees_of_freedom: 3 } });
    await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: 80, sketch_id: "constraint-sketch", entity_id: "constraint-line-c", kind: "line", params: { x1: 20, y1: 0, x2: 24, y2: 7 }, construction: false } });
    const parallel = await client.callTool({ name: "axis_cad_add_sketch_constraint", arguments: {
      expected_revision: 81, sketch_id: "constraint-sketch", constraint_id: "parallel-c", kind: "parallel", entities: ["constraint-line-a", "constraint-line-c"]
    } });
    expect(parallel.structuredContent).toMatchObject({ ok: true, revision: 82, profile: { constraint_count: 5, degrees_of_freedom: 6 } });
    const equal = await client.callTool({ name: "axis_cad_add_sketch_constraint", arguments: {
      expected_revision: 82, sketch_id: "constraint-sketch", constraint_id: "equal-c", kind: "equal", entities: ["constraint-line-a", "constraint-line-c"]
    } });
    expect(equal.structuredContent).toMatchObject({ ok: true, revision: 83, profile: { constraint_count: 6, degrees_of_freedom: 5 } });
    await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: 83, sketch_id: "constraint-sketch", entity_id: "constraint-line-d", kind: "line", params: { x1: -10, y1: 0, x2: -6, y2: 3 }, construction: false } });
    const perpendicular = await client.callTool({ name: "axis_cad_add_sketch_constraint", arguments: {
      expected_revision: 84, sketch_id: "constraint-sketch", constraint_id: "perpendicular-d", kind: "perpendicular", entities: ["constraint-line-a", "constraint-line-d"]
    } });
    expect(perpendicular.structuredContent).toMatchObject({ ok: true, revision: 85, profile: { constraint_count: 7, degrees_of_freedom: 8 } });
    const arc = await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: {
      expected_revision: 85, sketch_id: "constraint-sketch", entity_id: "construction-arc", kind: "arc", params: { cx: 0, cy: 0, radius: 4, start_angle: 0, end_angle: 1.57079632679, ccw: 1 }, construction: false
    } });
    expect(arc.structuredContent).toMatchObject({ ok: true, revision: 86, entity: { kind: "arc" } });
    const tangent = await client.callTool({ name: "axis_cad_add_sketch_constraint", arguments: {
      expected_revision: 86, sketch_id: "constraint-sketch", constraint_id: "tangent-guide", kind: "tangent", entities: ["constraint-line-d", "construction-arc"]
    } });
    expect(tangent.structuredContent).toMatchObject({ ok: true, revision: 87, profile: { constraint_count: 8, degrees_of_freedom: 12 } });
    const construction = await client.callTool({ name: "axis_cad_set_sketch_entity_construction", arguments: {
      expected_revision: 87, sketch_id: "constraint-sketch", entity_id: "construction-arc", construction: true
    } });
    expect(construction.structuredContent).toMatchObject({ ok: true, revision: 88, entity: { construction: true }, profile: { entity_count: 4 } });
    const deletedArc = await client.callTool({ name: "axis_cad_delete_sketch_entity", arguments: { expected_revision: 88, sketch_id: "constraint-sketch", entity_id: "construction-arc" } });
    expect(deletedArc.structuredContent).toMatchObject({ ok: true, revision: 89, removed_constraint_ids: ["tangent-guide"] });
    const resized = await client.callTool({ name: "axis_cad_update_sketch_constraint", arguments: { expected_revision: 89, sketch_id: "constraint-sketch", constraint_id: "length-a", value: 11 } });
    expect(resized.structuredContent).toMatchObject({ ok: true, revision: 90, constraint: { value: 11 }, profile: { constraint_count: 7, degrees_of_freedom: 8 } });
    const deletedVertical = await client.callTool({ name: "axis_cad_delete_sketch_constraint", arguments: { expected_revision: 90, sketch_id: "constraint-sketch", constraint_id: "vertical-b" } });
    expect(deletedVertical.structuredContent).toMatchObject({ ok: true, revision: 91, profile: { constraint_count: 6 } });
    const deletedLine = await client.callTool({ name: "axis_cad_delete_sketch_entity", arguments: { expected_revision: 91, sketch_id: "constraint-sketch", entity_id: "constraint-line-b" } });
    expect(deletedLine.structuredContent).toMatchObject({ ok: true, revision: 92, removed_constraint_ids: ["join-lines"] });
    const removedSketch = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 92, feature_id: "constraint-sketch", confirm: true } });
    expect(removedSketch.structuredContent).toMatchObject({ revision: 93 });
  });

  it("inspects and exports a local vector technical drawing", async () => {
    const drawing = await client.callTool({ name: "axis_cad_get_drawing", arguments: {} });
    expect(drawing.structuredContent).toMatchObject({ revision: 93, sheet: "A4 landscape", projections: [{ id: "front" }, { id: "top" }, { id: "right" }] });
    const exported = await client.callTool({ name: "axis_cad_export_drawing", arguments: { format: "pdf", filename_prefix: "fixture" } });
    expect(exported.structuredContent).toMatchObject({ ok: true, revision: 93, format: "pdf" });
    const bytes = await readFile((exported.structuredContent as { path: string }).path);
    expect(bytes.subarray(0, 4).toString()).toBe("%PDF");
    expect(bytes.length).toBeGreaterThan(3000);
    const dxf = await client.callTool({ name: "axis_cad_export_drawing", arguments: { format: "dxf", filename_prefix: "fixture" } });
    expect(dxf.structuredContent).toMatchObject({ ok: true, revision: 93, format: "dxf" });
    const dxfText = await readFile((dxf.structuredContent as { path: string }).path, "utf8");
    expect(dxfText).toContain("$INSUNITS\n70\n4");
    expect(dxfText).toContain("\nCIRCLE\n");
    expect(dxfText).toMatch(/0\nEOF\n$/);
  });

  it("extrudes editable multi-loop profiles with kernel-backed holes", async () => {
    await client.callTool({ name: "axis_cad_create_profile_sketch", arguments: { expected_revision: 93, feature_id: "washer-sketch", name: "Washer profile", plane: "XY", offset: 0 } });
    const outer = await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: 94, sketch_id: "washer-sketch", entity_id: "washer-outer", kind: "circle", params: { cx: 0, cy: 0, radius: 10 }, loop_id: "outer", construction: false } });
    expect(outer.structuredContent).toMatchObject({ revision: 95, entity: { loop_id: "outer" }, profile: { closed: true } });
    const invalidHole = await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: 95, sketch_id: "washer-sketch", entity_id: "outside-hole", kind: "circle", params: { cx: 6, cy: 0, radius: 4 }, loop_id: "hole-outside", construction: false } });
    expect(invalidHole.structuredContent).toMatchObject({ revision: 96, profile: { closed: false, errors: ["hole loop 'hole-outside' intersects or touches the outer loop"] } });
    await client.callTool({ name: "axis_cad_delete_sketch_entity", arguments: { expected_revision: 96, sketch_id: "washer-sketch", entity_id: "outside-hole" } });
    const hole = await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: 97, sketch_id: "washer-sketch", entity_id: "washer-hole", kind: "circle", params: { cx: 0, cy: 0, radius: 4 }, loop_id: "hole-1", construction: false } });
    expect(hole.structuredContent).toMatchObject({ revision: 98, entity: { loop_id: "hole-1" }, profile: { closed: true, entity_count: 2 } });
    await client.callTool({ name: "axis_cad_create_extrusion", arguments: { expected_revision: 98, feature_id: "washer-solid", name: "Washer", sketch_id: "washer-sketch", length: 5, symmetric: false } });
    const initial = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "washer-solid" } });
    const initialVolume = (initial.structuredContent as { volume: number }).volume;
    expect(initial.structuredContent).toMatchObject({ revision: 99, feature_id: "washer-solid", can_export_step: true });
    expect(Math.abs(initialVolume - Math.PI * 84 * 5) / (Math.PI * 84 * 5)).toBeLessThan(0.01);
    await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 99, feature_id: "washer-solid", parameter: "length", value: 6 } });
    const resized = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "washer-solid" } });
    expect(Math.abs((resized.structuredContent as { volume: number }).volume / initialVolume - 1.2)).toBeLessThan(0.01);
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 100, feature_id: "washer-solid", confirm: true } });
    const removed = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 101, feature_id: "washer-sketch", confirm: true } });
    expect(removed.structuredContent).toMatchObject({ revision: 102 });
  });

  it("trims and extends sketch lines against finite references", async () => {
    await client.callTool({ name: "axis_cad_create_profile_sketch", arguments: { expected_revision: 102, feature_id: "trim-sketch", name: "Trim fixture", plane: "XY", offset: 0 } });
    await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: 103, sketch_id: "trim-sketch", entity_id: "trim-target", kind: "line", params: { x1: 0, y1: 0, x2: 10, y2: 0 }, construction: false } });
    await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: 104, sketch_id: "trim-sketch", entity_id: "trim-reference", kind: "line", params: { x1: 6, y1: -5, x2: 6, y2: 5 }, construction: true } });
    const trimmed = await client.callTool({ name: "axis_cad_trim_extend_sketch_line", arguments: { expected_revision: 105, sketch_id: "trim-sketch", line_id: "trim-target", reference_line_id: "trim-reference", endpoint: "end", mode: "trim" } });
    expect(trimmed.structuredContent).toMatchObject({ ok: true, revision: 106, entity: { params: { x1: 0, y1: 0, x2: 6, y2: 0 } } });
    await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: 106, sketch_id: "trim-sketch", entity_id: "extend-target", kind: "line", params: { x1: 0, y1: 2, x2: 4, y2: 2 }, construction: false } });
    await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: 107, sketch_id: "trim-sketch", entity_id: "extend-reference", kind: "line", params: { x1: 8, y1: -1, x2: 8, y2: 3 }, construction: true } });
    const extended = await client.callTool({ name: "axis_cad_trim_extend_sketch_line", arguments: { expected_revision: 108, sketch_id: "trim-sketch", line_id: "extend-target", reference_line_id: "extend-reference", endpoint: "end", mode: "extend" } });
    expect(extended.structuredContent).toMatchObject({ ok: true, revision: 109, entity: { params: { x1: 0, y1: 2, x2: 8, y2: 2 } } });
    const parallel = await client.callTool({ name: "axis_cad_trim_extend_sketch_line", arguments: { expected_revision: 109, sketch_id: "trim-sketch", line_id: "trim-target", reference_line_id: "extend-target", endpoint: "end", mode: "extend" } });
    expect(parallel.isError).toBe(true);
    const removed = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 109, feature_id: "trim-sketch", confirm: true } });
    expect(removed.structuredContent).toMatchObject({ revision: 110 });
  });

  it("sweeps a profile along an editable curved helix path", async () => {
    await client.callTool({ name: "axis_cad_create_profile_sketch", arguments: { expected_revision: 110, feature_id: "helix-profile", name: "Helix profile", plane: "XY", offset: 0 } });
    await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: 111, sketch_id: "helix-profile", entity_id: "helix-circle", kind: "circle", params: { cx: 0, cy: 0, radius: 1.5 }, construction: false } });
    const swept = await client.callTool({ name: "axis_cad_create_helix_sweep", arguments: { expected_revision: 112, feature_id: "curved-sweep", name: "Helical tube", sketch_id: "helix-profile", radius: 10, pitch: 8, turns: 4, twist_angle: 0, scale_start: 1, scale_end: 1 } });
    expect(swept.structuredContent).toMatchObject({ ok: true, revision: 113, path_height: 32, feature: { kind: "sweep_feature", params: { helix_radius: 10, helix_pitch: 8, helix_turns: 4 } } });
    const initial = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "curved-sweep" } });
    expect(initial.structuredContent).toMatchObject({ revision: 113, feature_id: "curved-sweep", can_export_step: true });
    const initialVolume = (initial.structuredContent as { volume: number }).volume;
    expect(initialVolume).toBeGreaterThan(1_500);
    await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 113, feature_id: "curved-sweep", parameter: "helix_turns", value: 5 } });
    const extended = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "curved-sweep" } });
    expect(Math.abs((extended.structuredContent as { volume: number }).volume / initialVolume - 1.25)).toBeLessThan(0.03);
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 114, feature_id: "curved-sweep", confirm: true } });
    const removed = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 115, feature_id: "helix-profile", confirm: true } });
    expect(removed.structuredContent).toMatchObject({ revision: 116 });
  });

  it("moves a kernel-derived body through a reversible transform feature", async () => {
    await client.callTool({ name: "axis_cad_create_profile_sketch", arguments: { expected_revision: 116, feature_id: "move-profile", name: "Move profile", plane: "XY", offset: 0 } });
    await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: 117, sketch_id: "move-profile", entity_id: "move-circle", kind: "circle", params: { cx: 0, cy: 0, radius: 3 }, construction: false } });
    await client.callTool({ name: "axis_cad_create_extrusion", arguments: { expected_revision: 118, feature_id: "move-source", name: "Move source", sketch_id: "move-profile", length: 10, symmetric: false } });
    const created = await client.callTool({ name: "axis_cad_create_body_transform", arguments: {
      expected_revision: 119, feature_id: "moved-body", name: "Moved body", input_feature_id: "move-source",
      x: 20, y: -5, z: 3, x_degrees: 90, y_degrees: 0, z_degrees: 0
    } });
    expect(created.structuredContent).toMatchObject({ ok: true, revision: 120, suppressed_feature_ids: ["move-source"], feature: {
      id: "moved-body", kind: "body_transform", input_feature_ids: ["move-source"], params: { x: 20, y: -5, z: 3, rotation_x: 90 }
    } });
    const initial = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "moved-body" } });
    expect(initial.structuredContent).toMatchObject({ revision: 120, feature_id: "moved-body", can_export_step: true });
    const initialCenter = (initial.structuredContent as { center_of_mass: { x: number; y: number; z: number } }).center_of_mass;
    const initialVolume = (initial.structuredContent as { volume: number }).volume;
    expect(initialCenter.x).toBeCloseTo(20, 2); expect(initialCenter.y).toBeCloseTo(-5, 2); expect(initialCenter.z).toBeCloseTo(8, 2);
    const moved = await client.callTool({ name: "axis_cad_transform_feature", arguments: { expected_revision: 120, feature_id: "moved-body", x: 30, y: -5, z: 3 } });
    expect(moved.structuredContent).toMatchObject({ revision: 121, previous_position: { x: 20, y: -5, z: 3 }, position: { x: 30, y: -5, z: 3 } });
    const rotated = await client.callTool({ name: "axis_cad_rotate_feature", arguments: { expected_revision: 121, feature_id: "moved-body", x_degrees: 0, y_degrees: 90, z_degrees: 0 } });
    expect(rotated.structuredContent).toMatchObject({ revision: 122, previous_rotation: { x_degrees: 90 }, rotation: { x_degrees: 0, y_degrees: 90, z_degrees: 0 } });
    const scaled = await client.callTool({ name: "axis_cad_scale_feature", arguments: { expected_revision: 122, feature_id: "moved-body", x_scale: 1.5, y_scale: 1.5, z_scale: 1.5 } });
    expect(scaled.structuredContent).toMatchObject({ revision: 123, previous_scale: { x_scale: 1, y_scale: 1, z_scale: 1 }, scale: { x_scale: 1.5, y_scale: 1.5, z_scale: 1.5 } });
    const final = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "moved-body" } });
    expect(final.structuredContent).toMatchObject({ revision: 123, feature_id: "moved-body", can_export_step: true });
    const finalCenter = (final.structuredContent as { center_of_mass: { x: number; y: number; z: number } }).center_of_mass;
    expect((final.structuredContent as { volume: number }).volume / initialVolume).toBeCloseTo(3.375, 2);
    expect(finalCenter.x).toBeCloseTo(30, 2); expect(finalCenter.y).toBeCloseTo(-5, 2); expect(finalCenter.z).toBeCloseTo(8, 2);
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 123, feature_id: "moved-body", confirm: true } });
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 124, feature_id: "move-source", confirm: true } });
    const removed = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 125, feature_id: "move-profile", confirm: true } });
    expect(removed.structuredContent).toMatchObject({ revision: 126 });
  });

  it("non-uniformly scales a planar BRep and preserves STEP output", async () => {
    await client.callTool({ name: "axis_cad_create_feature", arguments: {
      expected_revision: 126, feature_id: "scale-box", name: "Scale box", kind: "box",
      params: { width: 10, height: 8, depth: 6, x: 0, y: 0, z: 0 }
    } });
    await client.callTool({ name: "axis_cad_create_body_transform", arguments: {
      expected_revision: 127, feature_id: "scaled-box", name: "Scaled box", input_feature_id: "scale-box"
    } });
    const scaled = await client.callTool({ name: "axis_cad_scale_feature", arguments: {
      expected_revision: 128, feature_id: "scaled-box", x_scale: 2, y_scale: 0.5, z_scale: 1.5
    } });
    expect(scaled.structuredContent).toMatchObject({ revision: 129, scale: { x_scale: 2, y_scale: 0.5, z_scale: 1.5 } });
    const validated = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "scaled-box" } });
    expect(validated.structuredContent).toMatchObject({ revision: 129, volume: 720, can_export_step: true, closed_manifold_mesh: true });
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 129, feature_id: "scaled-box", confirm: true } });
    const removed = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 130, feature_id: "scale-box", confirm: true } });
    expect(removed.structuredContent).toMatchObject({ revision: 131 });
  });

  it("sweeps a profile through editable 3D spline guide points", async () => {
    await client.callTool({ name: "axis_cad_create_profile_sketch", arguments: { expected_revision: 131, feature_id: "spline-profile", name: "Spline profile", plane: "XY", offset: 0 } });
    await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: 132, sketch_id: "spline-profile", entity_id: "spline-circle", kind: "circle", params: { cx: 0, cy: 0, radius: 2 }, construction: false } });
    const swept = await client.callTool({ name: "axis_cad_create_spline_sweep", arguments: {
      expected_revision: 133, feature_id: "spline-sweep", name: "Spline tube", sketch_id: "spline-profile",
      points: [{ x: 0, y: 0, z: 0 }, { x: 0, y: 10, z: 12 }, { x: 10, y: 10, z: 26 }, { x: 14, y: 0, z: 40 }],
      twist_angle: 0, scale_start: 1, scale_end: 1, frame_mode: "fixed_up", up_direction: { x: 0, y: 0, z: 1 },
      guide_points: [{ x: 8, y: 0, z: 0 }, { x: 8, y: 10, z: 12 }, { x: 18, y: 10, z: 26 }, { x: 22, y: 0, z: 40 }],
      start_tangent: { x: 0, y: 16, z: 8 }, end_tangent: { x: 12, y: 0, z: 8 }
    } });
    expect(swept.structuredContent).toMatchObject({ ok: true, revision: 134, point_count: 4, feature: { kind: "sweep_feature", params: { path_point_count: 4, path_3_z: 40, frame_mode: 2, guide_point_count: 4, guide_3_x: 22, tangent_mode: 3, start_tangent_y: 16 } } });
    const initial = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "spline-sweep" } });
    expect(initial.structuredContent).toMatchObject({ revision: 134, feature_id: "spline-sweep", can_export_step: true, boundary_edge_segments: 0, closed_manifold_mesh: true });
    expect((initial.structuredContent as { triangle_count: number }).triangle_count).toBeGreaterThan(500);
    const initialVolume = (initial.structuredContent as { volume: number }).volume;
    const topologyEdit = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 134, feature_id: "spline-sweep", parameter: "path_point_count", value: 3 } });
    expect(topologyEdit.isError).toBe(true);
    const edited = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 134, feature_id: "spline-sweep", parameter: "path_1_y", value: 18 } });
    expect(edited.structuredContent).toMatchObject({ ok: true, revision: 135, previous_value: 10, value: 18 });
    const reshaped = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "spline-sweep" } });
    expect(Math.abs((reshaped.structuredContent as { volume: number }).volume - initialVolume)).toBeGreaterThan(1);
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 135, feature_id: "spline-sweep", confirm: true } });
    const removed = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 136, feature_id: "spline-profile", confirm: true } });
    expect(removed.structuredContent).toMatchObject({ revision: 137 });
  });

  it("sweeps a profile along editable connected line and circular-arc segments", async () => {
    await client.callTool({ name: "axis_cad_create_profile_sketch", arguments: { expected_revision: 137, feature_id: "composite-profile", name: "Composite profile", plane: "XY", offset: 0 } });
    await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: 138, sketch_id: "composite-profile", entity_id: "composite-circle", kind: "circle", params: { cx: 0, cy: 0, radius: 2 }, construction: false } });
    const swept = await client.callTool({ name: "axis_cad_create_composite_sweep", arguments: {
      expected_revision: 139, feature_id: "composite-sweep", name: "Line arc tube", sketch_id: "composite-profile",
      segments: [
        { type: "line", start: { x: 0, y: 0, z: 0 }, end: { x: 0, y: 0, z: 12 } },
        { type: "arc", start: { x: 0, y: 0, z: 12 }, mid: { x: 8, y: 0, z: 20 }, end: { x: 0, y: 0, z: 28 } },
        { type: "line", start: { x: 0, y: 0, z: 28 }, end: { x: 0, y: 0, z: 40 } }
      ],
      twist_angle: 0, scale_start: 1, scale_end: 1, continuity: "position", tangent_tolerance_degrees: 1
    } });
    expect(swept.structuredContent).toMatchObject({ ok: true, revision: 140, segment_count: 3, feature: { kind: "sweep_feature", params: { path_segment_count: 3, path_1_kind: 1, path_1_mid_x: 8, continuity_mode: 0, tangent_tolerance: 1 } } });
    const initial = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "composite-sweep" } });
    expect(initial.structuredContent).toMatchObject({ revision: 140, feature_id: "composite-sweep", can_export_step: true, boundary_edge_segments: 0, closed_manifold_mesh: true });
    expect((initial.structuredContent as { triangle_count: number }).triangle_count).toBeGreaterThan(500);
    const initialVolume = (initial.structuredContent as { volume: number }).volume;
    const topologyEdit = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 140, feature_id: "composite-sweep", parameter: "path_1_kind", value: 0 } });
    expect(topologyEdit.isError).toBe(true);
    const invalidContinuity = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 140, feature_id: "composite-sweep", parameter: "continuity_mode", value: 1 } });
    expect(invalidContinuity.isError).toBe(true);
    const edited = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 140, feature_id: "composite-sweep", parameter: "path_1_mid_x", value: 12 } });
    expect(edited.structuredContent).toMatchObject({ ok: true, revision: 141, previous_value: 8, value: 12 });
    const reshaped = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "composite-sweep" } });
    expect(Math.abs((reshaped.structuredContent as { volume: number }).volume - initialVolume)).toBeGreaterThan(1);
    const junction = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 141, feature_id: "composite-sweep", parameter: "path_0_end_x", value: 2 } });
    expect(junction.structuredContent).toMatchObject({ ok: true, revision: 142, previous_value: 0, value: 2 });
    const document = await client.callTool({ name: "axis_cad_get_document", arguments: {} });
    expect((document.structuredContent as { features: Array<{ id: string; params: Record<string, number> }> }).features.find((feature) => feature.id === "composite-sweep")?.params).toMatchObject({ path_0_end_x: 2, path_1_start_x: 2 });
    const connected = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "composite-sweep" } });
    expect(connected.structuredContent).toMatchObject({ revision: 142, boundary_edge_segments: 0, closed_manifold_mesh: true });
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 142, feature_id: "composite-sweep", confirm: true } });
    const removed = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 143, feature_id: "composite-profile", confirm: true } });
    expect(removed.structuredContent).toMatchObject({ revision: 144 });
  });

  it("creates and regenerates a variable-profile sweep with ordered scale stations", async () => {
    await client.callTool({ name: "axis_cad_create_profile_sketch", arguments: { expected_revision: 144, feature_id: "variable-profile", name: "Variable profile", plane: "XY", offset: 0 } });
    await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: 145, sketch_id: "variable-profile", entity_id: "variable-circle", kind: "circle", params: { cx: 0, cy: 0, radius: 2 }, construction: false } });
    const swept = await client.callTool({ name: "axis_cad_create_sweep", arguments: {
      expected_revision: 146, feature_id: "variable-sweep", name: "Variable tube", sketch_id: "variable-profile",
      start: { x: 0, y: 0, z: 0 }, end: { x: 0, y: 0, z: 40 }, scale_start: 1, scale_end: 1,
      scale_stations: [{ position: 0.5, scale: 1.5 }]
    } });
    expect(swept.structuredContent).toMatchObject({ ok: true, revision: 147, scale_station_count: 1, feature: { params: { scale_station_count: 1, scale_station_0_position: 0.5, scale_station_0_factor: 1.5 } } });
    const initial = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "variable-sweep" } });
    expect(initial.structuredContent).toMatchObject({ revision: 147, can_export_step: true, boundary_edge_segments: 0, closed_manifold_mesh: true });
    const initialVolume = (initial.structuredContent as { volume: number }).volume;
    const invalidPosition = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 147, feature_id: "variable-sweep", parameter: "scale_station_0_position", value: 1 } });
    expect(invalidPosition.isError).toBe(true);
    const topologyEdit = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 147, feature_id: "variable-sweep", parameter: "scale_station_count", value: 2 } });
    expect(topologyEdit.isError).toBe(true);
    const edited = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 147, feature_id: "variable-sweep", parameter: "scale_station_0_factor", value: 2 } });
    expect(edited.structuredContent).toMatchObject({ ok: true, revision: 148, previous_value: 1.5, value: 2 });
    const expanded = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "variable-sweep" } });
    expect((expanded.structuredContent as { volume: number }).volume).toBeGreaterThan(initialVolume * 1.35);
    expect(expanded.structuredContent).toMatchObject({ revision: 148, can_export_step: true, step_roundtrip: { passed: true }, closed_manifold_mesh: true });
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 148, feature_id: "variable-sweep", confirm: true } });
    const removed = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 149, feature_id: "variable-profile", confirm: true } });
    expect(removed.structuredContent).toMatchObject({ revision: 150 });
  });

  it("builds a solved assembly with reusable instances, mates, BOM, and interference", async () => {
    await client.callTool({ name: "axis_cad_create_feature", arguments: { expected_revision: 150, feature_id: "assembly-block", name: "Assembly block", kind: "box", params: { width: 10, height: 10, depth: 10, x: 0, y: 0, z: 0 } } });
    const base = await client.callTool({ name: "axis_cad_create_instance", arguments: { expected_revision: 151, feature_id: "block-base", name: "Block base", source_feature_id: "assembly-block", position: { x: 0, y: 0, z: 0 } } });
    expect(base.structuredContent).toMatchObject({ ok: true, revision: 152, source_feature_id: "assembly-block", feature: { kind: "assembly_instance", params: { fixed: 0 } } });
    await client.callTool({ name: "axis_cad_create_instance", arguments: { expected_revision: 152, feature_id: "block-follower", name: "Block follower", source_feature_id: "assembly-block", position: { x: 30, y: 0, z: 0 } } });
    const fixed = await client.callTool({ name: "axis_cad_create_mate", arguments: { expected_revision: 153, feature_id: "ground-base", name: "Ground base", type: "fixed", moving_instance_id: "block-base" } });
    expect(fixed.structuredContent).toMatchObject({ ok: true, revision: 154, solved_position: { x: 0, y: 0, z: 0 } });
    const coincident = await client.callTool({ name: "axis_cad_create_mate", arguments: { expected_revision: 154, feature_id: "space-blocks", name: "Space blocks", type: "coincident", reference_instance_id: "block-base", moving_instance_id: "block-follower", offset: { x: 20, y: 0, z: 0 } } });
    expect(coincident.structuredContent).toMatchObject({ ok: true, revision: 155, solved_position: { x: 20, y: 0, z: 0 } });
    const assembly = await client.callTool({ name: "axis_cad_get_assembly", arguments: {} });
    expect(assembly.structuredContent).toMatchObject({ revision: 155, instance_count: 2, mate_count: 2, instances: [
      { id: "block-base", fixed: true, degrees_of_freedom: 0 },
      { id: "block-follower", fixed: false, driven_by: "space-blocks", degrees_of_freedom: 3, position: { x: 20, y: 0, z: 0 } }
    ] });
    const bom = await client.callTool({ name: "axis_cad_get_bom", arguments: {} });
    expect(bom.structuredContent).toMatchObject({ revision: 155, total_instances: 2, unique_parts: 1, items: [{ part_number: "assembly-block", quantity: 2 }] });
    const fixedMove = await client.callTool({ name: "axis_cad_transform_feature", arguments: { expected_revision: 155, feature_id: "block-base", x: 1, y: 0, z: 0 } });
    expect(fixedMove.isError).toBe(true);
    const drivenMove = await client.callTool({ name: "axis_cad_transform_feature", arguments: { expected_revision: 155, feature_id: "block-follower", x: 25, y: 0, z: 0 } });
    expect(drivenMove.isError).toBe(true);
    const clear = await client.callTool({ name: "axis_cad_check_clearance", arguments: { feature_id: "block-base", second_feature_id: "block-follower" } });
    expect(clear.structuredContent).toMatchObject({ revision: 155, classification: "clear" });
    expect((clear.structuredContent as { distance: number }).distance).toBeCloseTo(10, 2);
    const moved = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 155, feature_id: "space-blocks", parameter: "offset_x", value: 5 } });
    expect(moved.structuredContent).toMatchObject({ ok: true, revision: 156, previous_value: 20, value: 5 });
    const interference = await client.callTool({ name: "axis_cad_check_clearance", arguments: { feature_id: "block-base", second_feature_id: "block-follower" } });
    expect(interference.structuredContent).toMatchObject({ revision: 156, classification: "interference", intersecting: true });
    const follower = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "block-follower" } });
    expect(follower.structuredContent).toMatchObject({ revision: 156, can_export_step: true, step_roundtrip: { passed: true }, closed_manifold_mesh: true });
    const structurallyValid = await client.callTool({ name: "axis_cad_validate_document", arguments: {} });
    expect(structurallyValid.structuredContent).toMatchObject({ ok: true, revision: 156, errors: [] });
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 156, feature_id: "space-blocks", confirm: true } });
    const invalidDistance = await client.callTool({ name: "axis_cad_create_mate", arguments: { expected_revision: 157, feature_id: "invalid-distance", name: "Invalid distance", type: "distance", reference_instance_id: "block-base", moving_instance_id: "block-follower", axis: { x: 0, y: 0, z: 0 }, distance: 25 } });
    expect(invalidDistance.isError).toBe(true);
    const distanceMate = await client.callTool({ name: "axis_cad_create_mate", arguments: { expected_revision: 157, feature_id: "distance-blocks", name: "Distance blocks", type: "distance", reference_instance_id: "block-base", moving_instance_id: "block-follower", axis: { x: 0, y: 2, z: 0 }, distance: 25 } });
    expect(distanceMate.structuredContent).toMatchObject({ ok: true, revision: 158, feature: { params: { mate_type: 2, axis_y: 2, distance: 25 } }, solved_position: { x: 0, y: 25, z: 0 } });
    const distanceAssembly = await client.callTool({ name: "axis_cad_get_assembly", arguments: {} });
    expect(distanceAssembly.structuredContent).toMatchObject({ revision: 158 });
    const distanceState = distanceAssembly.structuredContent as { mates: unknown[]; instances: unknown[] };
    expect(distanceState.mates).toEqual(expect.arrayContaining([expect.objectContaining({ id: "distance-blocks", type: "distance", reference_instance_id: "block-base", moving_instance_id: "block-follower" })]));
    expect(distanceState.instances).toEqual(expect.arrayContaining([expect.objectContaining({ id: "block-follower", driven_by: "distance-blocks", degrees_of_freedom: 3, position: { x: 0, y: 25, z: 0 } })]));
    const spaced = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 158, feature_id: "distance-blocks", parameter: "distance", value: 15 } });
    expect(spaced.structuredContent).toMatchObject({ ok: true, revision: 159, previous_value: 25, value: 15 });
    const distanceValid = await client.callTool({ name: "axis_cad_validate_document", arguments: {} });
    expect(distanceValid.structuredContent).toMatchObject({ ok: true, revision: 159, errors: [] });
    const motion = await client.callTool({ name: "axis_cad_set_motion_study", arguments: { expected_revision: 159, enabled: true, mate_id: "distance-blocks", parameter: "distance", minimum: 5, maximum: 30, progress: 0.5, playing: false } });
    expect(motion.structuredContent).toMatchObject({ ok: true, revision: 159, motion_study: { mate_id: "distance-blocks", parameter: "distance", minimum: 5, maximum: 30, progress: 0.5, playing: false, value: 17.5 } });
    const motionView = await client.callTool({ name: "axis_cad_get_view", arguments: {} });
    expect(motionView.structuredContent).toMatchObject({ revision: 159, motion_study: { mate_id: "distance-blocks", value: 17.5 } });
    const stoppedMotion = await client.callTool({ name: "axis_cad_set_motion_study", arguments: { expected_revision: 159, enabled: false } });
    expect(stoppedMotion.structuredContent).toMatchObject({ ok: true, revision: 159, motion_study: null });
    const assemblyStep = await client.callTool({ name: "axis_cad_export_assembly_step", arguments: { filename_prefix: "fixture-assembly" } });
    expect(assemblyStep.structuredContent).toMatchObject({ ok: true, revision: 159, instance_count: 2, body_count: 2, instance_ids: ["block-base", "block-follower"], step_roundtrip: { attempted: true, passed: true, body_count: 2 } });
    expect((assemblyStep.structuredContent as { volume: number }).volume).toBeCloseTo(2_000, 2);
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 159, feature_id: "distance-blocks", confirm: true } });
    const planeMate = await client.callTool({ name: "axis_cad_create_mate", arguments: { expected_revision: 160, feature_id: "plane-blocks", name: "Plane blocks", type: "plane", reference_instance_id: "block-base", moving_instance_id: "block-follower", reference_normal: { x: 0, y: 0, z: 1 }, moving_normal: { x: 1, y: 0, z: 0 }, distance: 25, spin: 0 } });
    expect(planeMate.structuredContent).toMatchObject({ ok: true, revision: 161, feature: { params: { mate_type: 3, distance: 25, spin: 0 } }, solved_position: { x: 0, y: 0, z: 25 } });
    const planeAssembly = await client.callTool({ name: "axis_cad_get_assembly", arguments: {} });
    expect(planeAssembly.structuredContent).toMatchObject({ revision: 161, instances: [{ id: "block-base", degrees_of_freedom: 0 }, { id: "block-follower", driven_by: "plane-blocks", degrees_of_freedom: 1, position: { x: 0, y: 0, z: 25 } }] });
    const planeRotate = await client.callTool({ name: "axis_cad_rotate_feature", arguments: { expected_revision: 161, feature_id: "block-follower", x: 0, y: 0, z: 0 } });
    expect(planeRotate.isError).toBe(true);
    const negativePlaneOffset = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 161, feature_id: "plane-blocks", parameter: "distance", value: -1 } });
    expect(negativePlaneOffset.isError).toBe(true);
    const spun = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 161, feature_id: "plane-blocks", parameter: "spin", value: 45 } });
    expect(spun.structuredContent).toMatchObject({ ok: true, revision: 162, previous_value: 0, value: 45 });
    const planeStep = await client.callTool({ name: "axis_cad_export_assembly_step", arguments: { filename_prefix: "fixture-plane-assembly" } });
    expect(planeStep.structuredContent).toMatchObject({ ok: true, revision: 162, body_count: 2, step_roundtrip: { passed: true } });
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 162, feature_id: "plane-blocks", confirm: true } });
    const concentricMate = await client.callTool({ name: "axis_cad_create_mate", arguments: { expected_revision: 163, feature_id: "concentric-blocks", name: "Concentric blocks", type: "concentric", reference_instance_id: "block-base", moving_instance_id: "block-follower", reference_axis: { x: 0, y: 0, z: 1 }, moving_axis: { x: 1, y: 0, z: 0 }, axial_offset: 30, spin: 0 } });
    expect(concentricMate.structuredContent).toMatchObject({ ok: true, revision: 164, feature: { params: { mate_type: 4, axial_offset: 30, spin: 0 } }, solved_position: { x: 0, y: 0, z: 30 } });
    const concentricAssembly = await client.callTool({ name: "axis_cad_get_assembly", arguments: {} });
    expect(concentricAssembly.structuredContent).toMatchObject({ revision: 164, instances: [{ id: "block-base", degrees_of_freedom: 0 }, { id: "block-follower", driven_by: "concentric-blocks", degrees_of_freedom: 2, position: { x: 0, y: 0, z: 30 } }] });
    const slid = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 164, feature_id: "concentric-blocks", parameter: "axial_offset", value: -10 } });
    expect(slid.structuredContent).toMatchObject({ ok: true, revision: 165, previous_value: 30, value: -10 });
    const concentricSpin = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 165, feature_id: "concentric-blocks", parameter: "spin", value: 30 } });
    expect(concentricSpin.structuredContent).toMatchObject({ ok: true, revision: 166, previous_value: 0, value: 30 });
    const concentricStep = await client.callTool({ name: "axis_cad_export_assembly_step", arguments: { filename_prefix: "fixture-concentric-assembly" } });
    expect(concentricStep.structuredContent).toMatchObject({ ok: true, revision: 166, body_count: 2, step_roundtrip: { passed: true } });
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 166, feature_id: "concentric-blocks", confirm: true } });
    await client.callTool({ name: "axis_cad_create_mate", arguments: { expected_revision: 167, feature_id: "composed-distance", name: "Composed distance", type: "distance", reference_instance_id: "block-base", moving_instance_id: "block-follower", axis: { x: 1, y: 0, z: 0 }, distance: 20 } });
    const angleMate = await client.callTool({ name: "axis_cad_create_mate", arguments: { expected_revision: 168, feature_id: "angle-blocks", name: "Angle blocks", type: "angle", reference_instance_id: "block-base", moving_instance_id: "block-follower", reference_normal: { x: 0, y: 0, z: 1 }, moving_normal: { x: 0, y: 0, z: 1 }, hinge_axis: { x: 1, y: 0, z: 0 }, angle: 90, spin: 0 } });
    expect(angleMate.structuredContent).toMatchObject({ ok: true, revision: 169, feature: { params: { mate_type: 5, angle: 90, spin: 0 } }, solved_position: { x: 20, y: 0, z: 0 } });
    const composedAssembly = await client.callTool({ name: "axis_cad_get_assembly", arguments: {} });
    expect(composedAssembly.structuredContent).toMatchObject({ revision: 169, instances: [{ id: "block-base", degrees_of_freedom: 0 }, { id: "block-follower", driven_by: "composed-distance", driving_mate_ids: ["composed-distance", "angle-blocks"], degrees_of_freedom: 1, position: { x: 20, y: 0, z: 0 } }] });
    const overconstrained = await client.callTool({ name: "axis_cad_create_mate", arguments: { expected_revision: 169, feature_id: "second-angle", name: "Second angle", type: "angle", reference_instance_id: "block-base", moving_instance_id: "block-follower", angle: 45 } });
    expect(overconstrained.isError).toBe(true);
    const editedAngle = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: 169, feature_id: "angle-blocks", parameter: "angle", value: 60 } });
    expect(editedAngle.structuredContent).toMatchObject({ ok: true, revision: 170, previous_value: 90, value: 60 });
    const composedStep = await client.callTool({ name: "axis_cad_export_assembly_step", arguments: { filename_prefix: "fixture-composed-assembly" } });
    expect(composedStep.structuredContent).toMatchObject({ ok: true, revision: 170, body_count: 2, step_roundtrip: { passed: true } });
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 170, feature_id: "angle-blocks", confirm: true } });
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 171, feature_id: "composed-distance", confirm: true } });
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 172, feature_id: "ground-base", confirm: true } });
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 173, feature_id: "block-follower", confirm: true } });
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 174, feature_id: "block-base", confirm: true } });
    const removed = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 175, feature_id: "assembly-block", confirm: true } });
    expect(removed.structuredContent).toMatchObject({ revision: 176 });
  });

  it("assigns a reusable part material and reports exact assembly mass", async () => {
    await client.callTool({ name: "axis_cad_create_feature", arguments: { expected_revision: 176, feature_id: "mass-block", name: "Mass block", kind: "box", params: { width: 10, height: 10, depth: 10, x: 0, y: 0, z: 0 } } });
    const assigned = await client.callTool({ name: "axis_cad_set_material", arguments: { expected_revision: 177, feature_id: "mass-block", material: "aluminum_6061" } });
    expect(assigned.structuredContent).toMatchObject({ ok: true, revision: 178, source_feature_id: "mass-block", material: "aluminum_6061", density_g_per_mm3: 0.0027 });
    await client.callTool({ name: "axis_cad_create_instance", arguments: { expected_revision: 178, feature_id: "mass-block-a", name: "Mass block A", source_feature_id: "mass-block", position: { x: 0, y: 0, z: 0 } } });
    await client.callTool({ name: "axis_cad_create_instance", arguments: { expected_revision: 179, feature_id: "mass-block-b", name: "Mass block B", source_feature_id: "mass-block", position: { x: 20, y: 0, z: 0 } } });
    const bom = await client.callTool({ name: "axis_cad_get_bom", arguments: {} });
    expect(bom.structuredContent).toMatchObject({
      revision: 180, total_instances: 2, unique_parts: 1, assigned_mass_instances: 2,
      items: [{ part_number: "mass-block", quantity: 2, material: "aluminum_6061", density_g_per_mm3: 0.0027 }]
    });
    const content = bom.structuredContent as { total_mass_grams: number; items: Array<{ exact_volume_mm3: number; unit_mass_grams: number; total_mass_grams: number }> };
    expect(content.items[0].exact_volume_mm3).toBeCloseTo(1_000, 2);
    expect(content.items[0].unit_mass_grams).toBeCloseTo(2.7, 3);
    expect(content.items[0].total_mass_grams).toBeCloseTo(5.4, 3);
    expect(content.total_mass_grams).toBeCloseTo(5.4, 3);
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 180, feature_id: "mass-block-b", confirm: true } });
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 181, feature_id: "mass-block-a", confirm: true } });
    const removed = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 182, feature_id: "mass-block", confirm: true } });
    expect(removed.structuredContent).toMatchObject({ revision: 183 });
  });

  it("imports a retained STEP body and keeps it editable through the kernel", async () => {
    await client.callTool({ name: "axis_cad_create_feature", arguments: { expected_revision: 183, feature_id: "step-source", name: "STEP source", kind: "box", params: { width: 10, height: 10, depth: 10, x: 0, y: 0, z: 0 } } });
    const exported = await client.callTool({ name: "axis_cad_export_step", arguments: { feature_id: "step-source", filename_prefix: "import-fixture" } });
    const sourcePath = (exported.structuredContent as { path: string }).path;
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 184, feature_id: "step-source", confirm: true } });
    const imported = await client.callTool({ name: "axis_cad_import_step", arguments: { expected_revision: 185, source_path: sourcePath, feature_prefix: "imported-box", name: "Imported box" } });
    expect(imported.structuredContent).toMatchObject({ ok: true, revision: 186, body_count: 1, exact_volume_mm3: 1_000, features: [{ id: "imported-box", name: "Imported box", kind: "imported_step", visible: true, params: { body_number: 1 } }] });
    expect((imported.structuredContent as { asset_path: string }).asset_path).toContain(path.join(dataDir, "assets"));
    const validation = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "imported-box" } });
    expect(validation.structuredContent).toMatchObject({ ok: true, revision: 186, feature_id: "imported-box", can_export_step: true, step_roundtrip: { passed: true, body_count: 1 } });
    expect((validation.structuredContent as { volume: number }).volume).toBeCloseTo(1_000, 2);
    const moved = await client.callTool({ name: "axis_cad_create_body_transform", arguments: { expected_revision: 186, feature_id: "moved-import", name: "Moved import", input_feature_id: "imported-box", position: { x: 20, y: 0, z: 0 } } });
    expect(moved.structuredContent).toMatchObject({ ok: true, revision: 187, feature: { kind: "body_transform", input_feature_ids: ["imported-box"] } });
    const movedValidation = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "moved-import" } });
    expect(movedValidation.structuredContent).toMatchObject({ revision: 187, can_export_step: true, step_roundtrip: { passed: true } });
    await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 187, feature_id: "moved-import", confirm: true } });
    const removed = await client.callTool({ name: "axis_cad_delete_feature", arguments: { expected_revision: 188, feature_id: "imported-box", confirm: true } });
    expect(removed.structuredContent).toMatchObject({ revision: 189 });
  });
});
