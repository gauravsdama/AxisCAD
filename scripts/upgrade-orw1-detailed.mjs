#!/usr/bin/env node
/**
 * Turns the ORW-1 engineering blockout into a readable, surface-led concept
 * model.  All geometry is still native Axis features/instances: cushions are
 * scaled sphere occurrences, tubes are cylinders, and the cockpit keeps
 * editable structure rather than a flattened render-only mesh.
 */
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const client = new Client({ name: "axis-orw1-surface-upgrade", version: "1.0.0" });
await client.connect(new StdioClientTransport({ command: process.execPath, args: ["mcp/server.mjs"] }));
const call = async (name, arguments_) => {
  const response = await client.callTool({ name, arguments: arguments_ });
  if (response.structuredContent) return response.structuredContent;
  const text = response.content?.map((part) => part.text || "").join("\n") || "";
  if (response.isError) throw new Error(`${name}: ${text}`);
  return JSON.parse(text.slice(text.indexOf("{")));
};
const revision = async () => (await call("axis_cad_get_document", {})).revision;
const addSource = async (id, name, kind, params, material) => {
  await call("axis_cad_create_feature", { expected_revision: await revision(), feature_id: id, name, kind, params });
  await call("axis_cad_set_material", { expected_revision: await revision(), feature_id: id, material });
};
const addInstance = async (id, name, source, position, rotation = { x: 0, y: 0, z: 0 }, scale = { x: 1, y: 1, z: 1 }) =>
  call("axis_cad_create_instance", { expected_revision: await revision(), feature_id: id, name, source_feature_id: source, position, rotation, scale });

const document = await call("axis_cad_get_document", {});
if (document.name !== "Orbit Recline Workstation ORW-1") throw new Error("Open the ORW-1 document before running the surface upgrade.");
await call("axis_cad_checkpoint_document", { label: "before-orw1-surface-upgrade" });
// Permit a safe repeat after an interrupted build: remove generated instances
// first, then their reusable source catalogue.
for (const feature of [...document.features.filter((f) => f.id.startsWith("orw2-") && f.kind === "assembly_instance"), ...document.features.filter((f) => f.id.startsWith("orw2-") && f.kind !== "assembly_instance")]) {
  await call("axis_cad_delete_feature", { expected_revision: await revision(), feature_id: feature.id, confirm: true });
}
// Keep the original parametric engineering blockout in the tree, but hide it
// while the richer review geometry is shown.
const oldVisible = document.features.filter((f) => f.visible && !f.id.startsWith("orw2-")).map((f) => ({ action: "set_visibility", feature_id: f.id, visible: false }));
if (oldVisible.length) await call("axis_cad_apply_edits", { expected_revision: await revision(), edits: oldVisible });

// Reusable source catalogue.
await addSource("orw2-cushion-core", "ORW-1 sculpted foam cushion core", "sphere", { radius: 1, x: 0, y: 0, z: 0 }, "abs_plastic");
await addSource("orw2-leather-piping", "ORW-1 leather piping ring", "torus", { major_radius: 1, tube_radius: 0.16, x: 0, y: 0, z: 0 }, "abs_plastic");
await addSource("orw2-steel-tube", "ORW-1 powder-coated structural tube", "cylinder", { radius: 1, height: 2, x: 0, y: 0, z: 0 }, "mild_steel");
await addSource("orw2-aluminum-tube", "ORW-1 aluminum monitor arm tube", "cylinder", { radius: 1, height: 2, x: 0, y: 0, z: 0 }, "aluminum_6061");
await addSource("orw2-wheel", "ORW-1 soft lockable caster wheel", "torus", { major_radius: 32, tube_radius: 12, x: 0, y: 0, z: 0 }, "abs_plastic");
await addSource("orw2-hub", "ORW-1 star-base hub", "cylinder", { radius: 118, height: 42, x: 0, y: 0, z: 32 }, "mild_steel");
await addSource("orw2-screen", "ORW-1 27 inch display with bezel", "box", { width: 610, height: 34, depth: 355, x: 0, y: 0, z: 0 }, "abs_plastic");
await addSource("orw2-screen-glass", "ORW-1 anti-glare display glass", "box", { width: 575, height: 10, depth: 322, x: 0, y: -18, z: 0 }, "aluminum_6061");
await addSource("orw2-desk-surface", "ORW-1 rounded desktop surface", "box", { width: 930, height: 36, depth: 560, x: 0, y: 0, z: 0 }, "aluminum_6061");
await addSource("orw2-keyboard", "ORW-1 retained keyboard tray", "box", { width: 560, height: 24, depth: 250, x: 0, y: 0, z: 0 }, "aluminum_6061");

// Five-spoke base, central column, and individual soft casters.
await addInstance("orw2-hub-inst", "Ballasted star base hub", "orw2-hub", { x: 0, y: 0, z: 0 });
for (let i = 0; i < 5; i += 1) {
  const angle = i * 72;
  await addInstance(`orw2-spoke-${i}`, `Swept structural spoke ${i + 1}`, "orw2-steel-tube", { x: 0, y: 280, z: 46 }, { x: 90, y: 0, z: angle }, { x: 26, y: 26, z: 300 });
  await addInstance(`orw2-caster-${i}`, `Lockable soft caster ${i + 1}`, "orw2-wheel", { x: 0, y: 610, z: 24 }, { x: 90, y: 0, z: angle });
}
await addInstance("orw2-column", "Telescoping gas-lift column", "orw2-steel-tube", { x: 0, y: 0, z: 310 }, { x: 0, y: 0, z: 0 }, { x: 58, y: 58, z: 260 });

// Upholstered ergonomic seat, lumbar/back, headrest, calf, and arm support.
await addInstance("orw2-seat-foam", "Contoured leather seat cushion", "orw2-cushion-core", { x: 0, y: 80, z: 640 }, { x: 0, y: 0, z: 0 }, { x: 300, y: 255, z: 76 });
await addInstance("orw2-seat-piping", "Seat perimeter piping", "orw2-leather-piping", { x: 0, y: 80, z: 650 }, { x: 0, y: 0, z: 0 }, { x: 300, y: 255, z: 40 });
await addInstance("orw2-back-foam", "Reclined leather back cushion", "orw2-cushion-core", { x: 0, y: 300, z: 960 }, { x: 28, y: 0, z: 0 }, { x: 300, y: 92, z: 420 });
await addInstance("orw2-lumbar", "Adjustable lumbar bolster", "orw2-cushion-core", { x: 0, y: 185, z: 830 }, { x: 28, y: 0, z: 0 }, { x: 185, y: 62, z: 110 });
await addInstance("orw2-headrest", "Articulated headrest cushion", "orw2-cushion-core", { x: 0, y: 520, z: 1280 }, { x: 28, y: 0, z: 0 }, { x: 175, y: 70, z: 112 });
await addInstance("orw2-calf", "Floating calf cushion", "orw2-cushion-core", { x: 0, y: -610, z: 530 }, { x: -14, y: 0, z: 0 }, { x: 265, y: 142, z: 58 });
for (const [side, x] of [["left", -345], ["right", 345]]) {
  await addInstance(`orw2-arm-${side}`, `${side} leather armrest`, "orw2-cushion-core", { x, y: 35, z: 740 }, { x: 0, y: 0, z: 0 }, { x: 72, y: 140, z: 48 });
}

// Two visible recline rails, actuator, and a monitor-cockpit spine.
for (const [side, x] of [["left", -295], ["right", 295]]) {
  await addInstance(`orw2-rail-${side}`, `${side} recline rail`, "orw2-steel-tube", { x, y: 120, z: 760 }, { x: 28, y: 0, z: 0 }, { x: 24, y: 24, z: 410 });
}
await addInstance("orw2-actuator", "Protected recline actuator", "orw2-steel-tube", { x: -215, y: 55, z: 505 }, { x: -30, y: 0, z: 0 }, { x: 38, y: 38, z: 250 });
await addInstance("orw2-cockpit-spine", "Coupled cockpit spine", "orw2-aluminum-tube", { x: 0, y: -310, z: 900 }, { x: 28, y: 0, z: 0 }, { x: 44, y: 44, z: 540 });
await addInstance("orw2-desktop", "Tilt-synchronous desktop", "orw2-desk-surface", { x: 0, y: -545, z: 1080 }, { x: 70, y: 0, z: 0 });
await addInstance("orw2-keyboard-inst", "Negative-tilt keyboard tray", "orw2-keyboard", { x: 0, y: -635, z: 980 }, { x: 62, y: 0, z: 0 });
await addInstance("orw2-mouse-pad", "Armrest mouse surface", "orw2-cushion-core", { x: 390, y: -30, z: 745 }, { x: 0, y: 0, z: 0 }, { x: 120, y: 105, z: 18 });

// Triple monitor array with physical bezels, glass, and two monitor arms.
for (const [id, x, zRot] of [["left", -355, 20], ["center", 0, 0], ["right", 355, -20]]) {
  await addInstance(`orw2-screen-${id}`, `${id} 27 inch display bezel`, "orw2-screen", { x, y: -810, z: 1320 }, { x: 70, y: 0, z: zRot });
  await addInstance(`orw2-glass-${id}`, `${id} anti-glare display surface`, "orw2-screen-glass", { x, y: -810, z: 1320 }, { x: 70, y: 0, z: zRot });
}
await addInstance("orw2-monitor-arm-left", "Left articulated monitor arm", "orw2-aluminum-tube", { x: -180, y: -565, z: 1160 }, { x: 45, y: 0, z: -24 }, { x: 22, y: 22, z: 300 });
await addInstance("orw2-monitor-arm-right", "Right articulated monitor arm", "orw2-aluminum-tube", { x: 180, y: -565, z: 1160 }, { x: 45, y: 0, z: 24 }, { x: 22, y: 22, z: 300 });

const final = await call("axis_cad_get_document", {});
// Source features are a reusable catalogue and must not appear at the origin.
// The assembly occurrences are the review model, so do not rely on the MCP's
// conservative hidden-instance default.
const visibilityEdits = final.features
  .filter((feature) => feature.id.startsWith("orw2-"))
  .map((feature) => ({
    action: "set_visibility",
    feature_id: feature.id,
    visible: feature.kind === "assembly_instance"
  }));
await call("axis_cad_apply_edits", { expected_revision: final.revision, edits: visibilityEdits });
const visibleFinal = await call("axis_cad_get_document", {});
await call("axis_cad_validate_document", { expected_revision: visibleFinal.revision });
console.log(JSON.stringify({ revision: visibleFinal.revision, features: visibleFinal.features.length }, null, 2));
await client.close();
