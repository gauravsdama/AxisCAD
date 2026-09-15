import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

let dataDir: string;
let client: Client;

beforeAll(async () => {
  dataDir = await mkdtemp(path.join(tmpdir(), "axis-cad-morph-"));
  client = new Client({ name: "axis-cad-morph-test", version: "0.1.0" });
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

describe("multi-section morph sweep", () => {
  it("regenerates a closed STEP-capable circle-to-rectangle-to-circle BRep", async () => {
    const initialDocument = await client.callTool({ name: "axis_cad_get_document", arguments: {} });
    let revision = (initialDocument.structuredContent as { revision: number }).revision;
    const createSketch = async (id: string, name: string) => {
      const response = await client.callTool({ name: "axis_cad_create_profile_sketch", arguments: { expected_revision: revision, feature_id: id, name, plane: "XY", offset: 0 } });
      revision = (response.structuredContent as { revision: number }).revision;
    };
    const addEntity = async (sketchId: string, entityId: string, kind: "line" | "circle", params: Record<string, number>) => {
      const response = await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: { expected_revision: revision, sketch_id: sketchId, entity_id: entityId, kind, params, construction: false } });
      revision = (response.structuredContent as { revision: number }).revision;
    };

    await createSketch("morph-start", "Round start");
    await addEntity("morph-start", "start-circle", "circle", { cx: 0, cy: 0, radius: 2 });
    await createSketch("morph-middle", "Wide middle");
    const corners = [[-4, -1], [4, -1], [4, 1], [-4, 1]];
    for (let index = 0; index < corners.length; index += 1) {
      const a = corners[index], b = corners[(index + 1) % corners.length];
      await addEntity("morph-middle", `middle-${index}`, "line", { x1: a[0], y1: a[1], x2: b[0], y2: b[1] });
    }
    await createSketch("morph-end", "Round end");
    await addEntity("morph-end", "end-circle", "circle", { cx: 0, cy: 0, radius: 3 });

    const swept = await client.callTool({ name: "axis_cad_create_sweep", arguments: {
      expected_revision: revision, feature_id: "mixed-morph", name: "Mixed morph", sketch_id: "morph-start",
      start: { x: 0, y: 0, z: 0 }, end: { x: 0, y: 0, z: 40 },
      profile_sections: [{ sketch_id: "morph-middle", position: 0.5 }, { sketch_id: "morph-end", position: 1 }]
    } });
    expect(swept.isError).not.toBe(true);
    revision = (swept.structuredContent as { revision: number }).revision;
    expect(swept.structuredContent).toMatchObject({
      profile_section_count: 3,
      feature: { input_feature_ids: ["morph-start", "morph-middle", "morph-end"], params: { profile_station_count: 2, profile_station_0_position: 0.5, profile_station_1_position: 1 } }
    });
    const firstKernel = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "mixed-morph" } });
    expect(firstKernel.structuredContent).toMatchObject({ can_export_step: true, closed_manifold_mesh: true, boundary_edge_segments: 0, step_roundtrip: { passed: true } });
    const firstVolume = (firstKernel.structuredContent as { volume: number }).volume;

    const moved = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: revision, feature_id: "mixed-morph", parameter: "profile_station_0_position", value: 0.3 } });
    revision = (moved.structuredContent as { revision: number }).revision;
    const secondKernel = await client.callTool({ name: "axis_cad_validate_with_kernel", arguments: { feature_id: "mixed-morph" } });
    expect(secondKernel.structuredContent).toMatchObject({ closed_manifold_mesh: true, boundary_edge_segments: 0, step_roundtrip: { passed: true } });
    expect(Math.abs((secondKernel.structuredContent as { volume: number }).volume - firstVolume)).toBeGreaterThan(5);

    const invalid = await client.callTool({ name: "axis_cad_set_parameter", arguments: { expected_revision: revision, feature_id: "mixed-morph", parameter: "profile_station_1_position", value: 0.9 } });
    expect(invalid.isError).toBe(true);
    const unchanged = await client.callTool({ name: "axis_cad_get_document", arguments: {} });
    expect((unchanged.structuredContent as { revision: number }).revision).toBe(revision);
  });
});
