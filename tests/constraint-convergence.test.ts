import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

let dataDir: string;
let client: Client;

beforeAll(async () => {
  dataDir = await mkdtemp(path.join(tmpdir(), "axis-cad-constraint-"));
  client = new Client({ name: "axis-cad-constraint-test", version: "0.1.0" });
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

describe("coupled MCP sketch constraints", () => {
  it("converges a reverse-ordered chain beyond the legacy pass limit", async () => {
    const initial = await client.callTool({ name: "axis_cad_get_document", arguments: {} });
    let revision = (initial.structuredContent as { revision: number }).revision;
    const created = await client.callTool({ name: "axis_cad_create_profile_sketch", arguments: {
      expected_revision: revision, feature_id: "coupled-chain", name: "Coupled chain", plane: "XY", offset: 0
    } });
    revision = (created.structuredContent as { revision: number }).revision;

    for (let index = 0; index < 12; index += 1) {
      const added = await client.callTool({ name: "axis_cad_add_sketch_entity", arguments: {
        expected_revision: revision, sketch_id: "coupled-chain", entity_id: `chain-${index}`, kind: "line",
        params: { x1: index * 10, y1: index, x2: index * 10 + 4, y2: index + 2 }, construction: true
      } });
      revision = (added.structuredContent as { revision: number }).revision;
    }

    for (let index = 10; index >= 0; index -= 1) {
      const constrained = await client.callTool({ name: "axis_cad_add_sketch_constraint", arguments: {
        expected_revision: revision, sketch_id: "coupled-chain", constraint_id: `join-${index}`, kind: "coincident",
        entities: [`chain-${index}:start`, `chain-${index + 1}:start`]
      } });
      expect(constrained.isError).not.toBe(true);
      revision = (constrained.structuredContent as { revision: number }).revision;
    }

    const inspected = await client.callTool({ name: "axis_cad_get_document", arguments: {} });
    const feature = (inspected.structuredContent as { features: Array<{ id: string; sketch?: { entities?: Array<{ params: Record<string, number> }> } }> })
      .features.find((candidate) => candidate.id === "coupled-chain");
    expect(feature?.sketch?.entities).toHaveLength(12);
    for (const entity of feature?.sketch?.entities ?? []) {
      expect(entity.params.x1).toBeCloseTo(0, 6);
      expect(entity.params.y1).toBeCloseTo(0, 6);
    }

    const invalid = await client.callTool({ name: "axis_cad_add_sketch_constraint", arguments: {
      expected_revision: revision, sketch_id: "coupled-chain", constraint_id: "missing-link", kind: "coincident",
      entities: ["chain-0:start", "missing:start"]
    } });
    expect(invalid.isError).toBe(true);
    const invalidContent = invalid.content as Array<{ type: string; text: string }>;
    expect(invalidContent[0].text).toContain("'missing-link'");
    const unchanged = await client.callTool({ name: "axis_cad_get_document", arguments: {} });
    expect((unchanged.structuredContent as { revision: number }).revision).toBe(revision);
  });
});
