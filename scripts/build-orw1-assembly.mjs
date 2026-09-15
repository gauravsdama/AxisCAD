#!/usr/bin/env node
/**
 * Builds the ORW-1 concept only through Axis CAD's public MCP contract.
 * It intentionally uses primitive source parts + assembly occurrences so the
 * chair remains editable and the BOM has reusable part identities.
 */
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const client = new Client({ name: "axis-orw1-builder", version: "1.0.0" });
await client.connect(new StdioClientTransport({ command: process.execPath, args: ["mcp/server.mjs"] }));
const call = async (name, arguments_) => {
  const response = await client.callTool({ name, arguments: arguments_ });
  if (response.structuredContent) return response.structuredContent;
  const body = response.content?.map((item) => item.text || "").join("\n") || "";
  if (response.isError) throw new Error(`${name}: ${body}`);
  const jsonStart = body.indexOf("{");
  if (jsonStart < 0) throw new Error(`${name} returned no structured result: ${body}`);
  return JSON.parse(body.slice(jsonStart));
};
const revision = async () => (await call("axis_cad_get_document", {})).revision;
const create = async (id, name, kind, params, material) => {
  await call("axis_cad_create_feature", { expected_revision: await revision(), feature_id: id, name, kind, params });
  if (material) await call("axis_cad_set_material", { expected_revision: await revision(), feature_id: id, material });
};
const instance = async (id, name, source, position, rotation = { x: 0, y: 0, z: 0 }, visible = true) => {
  await call("axis_cad_create_instance", { expected_revision: await revision(), feature_id: id, name, source_feature_id: source, position, rotation, scale: { x: 1, y: 1, z: 1 } });
  if (!visible) await call("axis_cad_apply_edits", { expected_revision: await revision(), edits: [{ action: "set_visibility", feature_id: id, visible: false }] });
};

const doc = await call("axis_cad_get_document", {});
if (doc.name !== "Orbit Recline Workstation ORW-1") throw new Error(`Expected ORW-1 active document, found '${doc.name}'.`);
await client.callTool({ name: "axis_cad_checkpoint_document", arguments: { label: "before-orw1-assembly" } });

// Suppress the starter mounting plate retained by the new-document template.
await call("axis_cad_apply_edits", { expected_revision: await revision(), edits: doc.features.map((feature) => ({ action: "set_visibility", feature_id: feature.id, visible: false })) });

const box = (width, height, depth, x = 0, y = 0, z = 0, rotation_x = 0, rotation_y = 0, rotation_z = 0) => ({ width, height, depth, x, y, z, rotation_x, rotation_y, rotation_z });
const cylinder = (radius, height, x = 0, y = 0, z = 0) => ({ radius, height, x, y, z });

// Source parts: units are mm. Structural parts reserve a robust, intentionally
// conservative envelope for later FEA and manufacturing refinement.
await create("orw-base-hub", "ORW-1 ballasted base hub", "cylinder", cylinder(150, 70, 0, 0, 70), "mild_steel");
await create("orw-base-leg", "ORW-1 five-star steel leg", "box", box(110, 700, 52, 0, 330, 35), "mild_steel");
await create("orw-caster", "ORW-1 lockable caster envelope", "sphere", { radius: 58, x: 0, y: 650, z: 0 }, "abs_plastic");
await create("orw-column", "ORW-1 reinforced central column", "cylinder", cylinder(62, 520, 0, 0, 330), "mild_steel");
await create("orw-side-plate", "ORW-1 bilateral recline side plate", "box", box(28, 620, 280, 0, 100, 650, 70), "mild_steel");
await create("orw-seat-pan", "ORW-1 ergonomic seat pan", "box", box(560, 520, 95, 0, 80, 645), "abs_plastic");
await create("orw-back-shell", "ORW-1 reclined back shell", "box", box(560, 120, 760, 0, 280, 965, 70), "abs_plastic");
await create("orw-headrest", "ORW-1 adjustable headrest", "box", box(330, 150, 210, 0, 555, 1215, 70), "abs_plastic");
await create("orw-footrest", "ORW-1 calf and foot support", "box", box(520, 330, 70, 0, -650, 560, 18), "abs_plastic");
await create("orw-actuator", "ORW-1 recline actuator housing", "cylinder", cylinder(42, 380, -230, 0, 515), "stainless_steel");
await create("orw-cockpit-spine", "ORW-1 aluminum cockpit spine", "box", box(90, 980, 80, 0, -310, 875, 70), "aluminum_6061");
await create("orw-desktop", "ORW-1 tilting desktop frame", "box", box(920, 540, 38, 0, -555, 1075, 70), "aluminum_6061");
await create("orw-keyboard-tray", "ORW-1 negative tilt keyboard tray", "box", box(560, 260, 28, 0, -655, 990, 62), "aluminum_6061");
await create("orw-mouse-pod", "ORW-1 armrest mouse pod", "box", box(270, 240, 30, 390, -20, 730, 70), "abs_plastic");
await create("orw-vesa-display", "ORW-1 27-inch VESA display envelope", "box", box(610, 44, 360, 0, 0, 0), "aluminum_6061");
await create("orw-laptop-tray", "ORW-1 retained laptop tray", "box", box(420, 300, 32, 0, 0, 0), "aluminum_6061");

// Visible triple-monitor configuration. Instances carry all operational poses;
// source solids become hidden reusable catalog components.
await instance("orw-hub-inst", "Base hub", "orw-base-hub", { x: 0, y: 0, z: 0 });
for (let index = 0; index < 5; index += 1) {
  const angle = index * 72;
  await instance(`orw-leg-${index + 1}`, `Five-star leg ${index + 1}`, "orw-base-leg", { x: 0, y: 0, z: 0 }, { x: 0, y: 0, z: angle });
  await instance(`orw-caster-${index + 1}`, `Lockable caster ${index + 1}`, "orw-caster", { x: 0, y: 0, z: 0 }, { x: 0, y: 0, z: angle });
}
await instance("orw-column-inst", "Central column", "orw-column", { x: 0, y: 0, z: 0 });
await instance("orw-left-recline", "Left recline plate", "orw-side-plate", { x: -300, y: 0, z: 0 });
await instance("orw-right-recline", "Right recline plate", "orw-side-plate", { x: 300, y: 0, z: 0 }, { x: 0, y: 0, z: 180 });
for (const [id, name, source] of [["orw-seat-inst", "Seat pan", "orw-seat-pan"], ["orw-back-inst", "70 degree back shell", "orw-back-shell"], ["orw-headrest-inst", "Headrest", "orw-headrest"], ["orw-footrest-inst", "Footrest", "orw-footrest"], ["orw-actuator-inst", "Recline actuator", "orw-actuator"], ["orw-spine-inst", "Coupled cockpit spine", "orw-cockpit-spine"], ["orw-desk-inst", "Tilting desktop", "orw-desktop"], ["orw-keyboard-inst", "Keyboard tray", "orw-keyboard-tray"], ["orw-mouse-inst", "Right mouse pod", "orw-mouse-pod"]]) await instance(id, name, source, { x: 0, y: 0, z: 0 });
await instance("orw-display-center", "Centre display", "orw-vesa-display", { x: 0, y: -800, z: 1275 }, { x: 70, y: 0, z: 0 });
await instance("orw-display-left", "Left display", "orw-vesa-display", { x: -370, y: -770, z: 1265 }, { x: 70, y: 0, z: 24 });
await instance("orw-display-right", "Right display", "orw-vesa-display", { x: 370, y: -770, z: 1265 }, { x: 70, y: 0, z: -24 });

// Alternate laptop layout is catalogued, deliberately hidden, and retained for
// later configuration switching without contaminating the triple-monitor view.
await instance("orw-alt-display-left", "ALT two-monitor left", "orw-vesa-display", { x: -210, y: -800, z: 1275 }, { x: 70, y: 0, z: 12 }, false);
await instance("orw-alt-display-right", "ALT two-monitor right", "orw-vesa-display", { x: 210, y: -800, z: 1275 }, { x: 70, y: 0, z: -12 }, false);
await instance("orw-alt-laptop", "ALT retained laptop", "orw-laptop-tray", { x: 0, y: -670, z: 1120 }, { x: 70, y: 0, z: 0 }, false);

// Fix the ground assembly reference; the other instances are deliberately free
// in this concept model until articulated linkage dimensions are refined.
await call("axis_cad_create_mate", { expected_revision: await revision(), feature_id: "orw-ground-base", name: "Ground ORW base", type: "fixed", moving_instance_id: "orw-hub-inst" });

const report = {
  document: await call("axis_cad_get_document", {}),
  assembly: await call("axis_cad_get_assembly", {}),
  bom: await call("axis_cad_get_bom", {})
};
console.log(JSON.stringify(report, null, 2));
await client.close();
