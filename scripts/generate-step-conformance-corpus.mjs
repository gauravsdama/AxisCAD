#!/usr/bin/env node

import { mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { exportAssemblyStep, exportStep } from "../kernel/vcad-kernel.mjs";

const outputDirectory = path.resolve(process.argv[2] || "conformance/generated");
await rm(outputDirectory, { recursive: true, force: true });
await mkdir(outputDirectory, { recursive: true });

const document = (features) => ({ id: "conformance", name: "STEP conformance", units: "mm", revision: 1, backend: "native-metal", features, operations: [] });
const manifestCase = (name, file, bodyCount, volume, bounds) => ({ name, file, units: "mm", body_count: bodyCount, volume, bounds });
const cases = [];

async function exportFeature(name, featureDocument, featureId, expectedVolume, bodyCount = 1) {
  const filename = `${name}.step`;
  const exported = await exportStep(featureDocument, featureId, path.join(outputDirectory, filename));
  const validation = exported.validation;
  if (expectedVolume !== undefined) {
    const relativeError = Math.abs(validation.volume - expectedVolume) / Math.max(Math.abs(expectedVolume), Number.EPSILON);
    if (relativeError > 0.01) {
      throw new Error(`${name}: internal kernel volume differs from the analytic value by ${relativeError}`);
    }
  }
  cases.push(manifestCase(name, filename, bodyCount, expectedVolume ?? validation.volume, validation.bounds));
}

await exportFeature("box-10x20x30", document([
  { id: "box", name: "Box", kind: "box", visible: true, params: { width: 10, height: 20, depth: 30, x: 4, y: -3, z: 8 } }
]), "box");

await exportFeature("cylinder-r7-h25", document([
  { id: "cylinder", name: "Cylinder", kind: "cylinder", visible: true, params: { radius: 7, height: 25, x: -12, y: 5, z: 2 } }
]), "cylinder");

await exportFeature("frustum-r8-r3-h20", document([
  { id: "frustum", name: "Frustum", kind: "cone", visible: true, params: { radius_bottom: 8, radius_top: 3, height: 20, x: 6, y: -9, z: 4 } }
]), "frustum", Math.PI * 20 * (8 * 8 + 8 * 3 + 3 * 3) / 3);

await exportFeature("pointed-cone-r6-h18", document([
  { id: "cone", name: "Pointed cone", kind: "cone", visible: true, params: { radius_bottom: 6, radius_top: 0, height: 18, x: -8, y: 11, z: -2 } }
]), "cone", Math.PI * 6 * 6 * 18 / 3);

await exportFeature("torus-r12-r3", document([
  { id: "torus", name: "Torus", kind: "torus", visible: true, params: { major_radius: 12, tube_radius: 3, x: 14, y: -7, z: 5 } }
]), "torus", 2 * Math.PI ** 2 * 12 * 3 ** 2);

const modifierDocument = (id, kind, params) => document([
  { id: `${id}-source`, name: "Modifier source", kind: "box", visible: false, params: { width: 18, height: 14, depth: 10, x: 0, y: 0, z: 0 } },
  { id, name: id, kind, visible: true, params, input_feature_ids: [`${id}-source`] }
]);
await exportFeature("all-edge-fillet-r2", modifierDocument("fillet", "edge_fillet", { radius: 2 }), "fillet");
await exportFeature("all-edge-chamfer-d2", modifierDocument("chamfer", "edge_chamfer", { distance: 2 }), "chamfer");
await exportFeature("shell-t1.5", modifierDocument("shell", "shell_feature", { thickness: 1.5 }), "shell");
await exportFeature("linear-pattern-3", modifierDocument("linear", "linear_pattern", { direction_x: 1, direction_y: 0, direction_z: 0, count: 3, spacing: 30 }), "linear", undefined, 3);
await exportFeature("circular-pattern-4", modifierDocument("circular", "circular_pattern", { origin_x: 0, origin_y: 0, origin_z: 0, axis_x: 0, axis_y: 0, axis_z: 1, count: 4, angle: 360 }), "circular");

await exportFeature("notched-block-boolean", document([
  { id: "notch-base", name: "Notch base", kind: "box", visible: false, params: { width: 50, height: 34, depth: 12, x: 0, y: 0, z: 0 } },
  { id: "notch-tool", name: "Notch tool", kind: "box", visible: false, params: { width: 18, height: 16, depth: 16, x: 20, y: 0, z: 0 } },
  { id: "notched-block", name: "Notched block", kind: "boolean_difference", visible: true, params: {}, input_feature_ids: ["notch-base", "notch-tool"] }
]), "notched-block");

await exportFeature("four-hole-plate", {
  id: "plate", name: "Four-hole plate", units: "mm", revision: 1, backend: "native-metal", operations: [],
  features: [
    { id: "sketch-base", name: "Base profile", kind: "sketch", visible: true, params: { width: 86, height: 54 }, sketch: { plane: "XY", profile: "centered-rectangle-four-holes", constraints: [] } },
    { id: "pad-base", name: "Base extrusion", kind: "pad", visible: true, params: { length: 6 } },
    { id: "pocket-holes", name: "Mounting holes", kind: "pocket", visible: true, params: { diameter: 5, offset: 12 } }
  ]
}, "pad-base");

const circle = (id, radius) => ({ id, name: id, kind: "profile_sketch", visible: false, params: { offset: 0 }, sketch: { plane: "XY", profile: "custom-profile", constraints: [], entities: [{ id: `${id}-circle`, kind: "circle", params: { cx: 0, cy: 0, radius }, construction: false, loop_id: "outer" }] } });
const rectangle = {
  id: "morph-middle", name: "Morph middle", kind: "profile_sketch", visible: false, params: { offset: 0 },
  sketch: { plane: "XY", profile: "custom-profile", constraints: [], entities: [
    { id: "r0", kind: "line", params: { x1: -4, y1: -1, x2: 4, y2: -1 }, loop_id: "outer" },
    { id: "r1", kind: "line", params: { x1: 4, y1: -1, x2: 4, y2: 1 }, loop_id: "outer" },
    { id: "r2", kind: "line", params: { x1: 4, y1: 1, x2: -4, y2: 1 }, loop_id: "outer" },
    { id: "r3", kind: "line", params: { x1: -4, y1: 1, x2: -4, y2: -1 }, loop_id: "outer" }
  ] }
};
await exportFeature("mixed-profile-morph", document([
  circle("morph-start", 2), rectangle, circle("morph-end", 3),
  { id: "morph", name: "Morph", kind: "sweep_feature", visible: true, params: { start_x: 0, start_y: 0, start_z: 0, end_x: 0, end_y: 0, end_z: 40, twist_angle: 0, scale_start: 1, scale_end: 1, profile_station_count: 2, profile_station_0_position: 0.5, profile_station_1_position: 1 }, input_feature_ids: ["morph-start", "morph-middle", "morph-end"] }
]), "morph");

const assemblyDocument = document([
  { id: "source", name: "Source", kind: "box", visible: false, params: { width: 10, height: 12, depth: 8, x: 0, y: 0, z: 0 } },
  { id: "instance-a", name: "Instance A", kind: "assembly_instance", visible: true, params: { x: -15, y: 0, z: 0, rotation_x: 0, rotation_y: 0, rotation_z: 0, scale_x: 1, scale_y: 1, scale_z: 1, fixed: 0 }, input_feature_ids: ["source"] },
  { id: "instance-b", name: "Instance B", kind: "assembly_instance", visible: true, params: { x: 20, y: 5, z: 3, rotation_x: 0, rotation_y: 0, rotation_z: 30, scale_x: 1, scale_y: 1, scale_z: 1, fixed: 0 }, input_feature_ids: ["source"] }
]);
const assemblyFilename = "two-body-assembly.step";
const assembly = await exportAssemblyStep(assemblyDocument, path.join(outputDirectory, assemblyFilename));
cases.push(manifestCase("two-body-assembly", assemblyFilename, assembly.body_count, assembly.volume, assembly.bounds));

await writeFile(path.join(outputDirectory, "manifest.json"), `${JSON.stringify({ schema: 1, generator: "Axis CAD vcad STEP writer", cases }, null, 2)}\n`);
process.stdout.write(`${path.join(outputDirectory, "manifest.json")}\n`);
