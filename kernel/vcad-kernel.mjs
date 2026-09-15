#!/usr/bin/env node

import { access, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const adapterDirectory = path.dirname(fileURLToPath(import.meta.url));
const defaultKernelDirectory = path.resolve(adapterDirectory, "../third_party/vcad-kernel");
const kernelDirectory = path.resolve(process.env.AXIS_VCAD_KERNEL_DIR || defaultKernelDirectory);
const bindingsPath = path.join(kernelDirectory, "vcad_kernel_wasm.js");
const wasmPath = path.join(kernelDirectory, "vcad_kernel_wasm_bg.wasm");
const packagePath = path.join(kernelDirectory, "package.json");

let kernelPromise;

async function quietly(operation) {
  const original = { log: console.log, info: console.info, debug: console.debug, warn: console.warn };
  console.log = console.info = console.debug = console.warn = () => {};
  try { return await operation(); }
  finally { Object.assign(console, original); }
}

async function loadKernel() {
  kernelPromise ||= quietly(async () => {
    await Promise.all([access(bindingsPath), access(wasmPath)]);
    const [module, wasm] = await Promise.all([
      import(`${pathToFileURL(bindingsPath).href}?axis-cad=1`),
      readFile(wasmPath)
    ]);
    module.initSync({ module: wasm });
    return module;
  });
  return kernelPromise;
}

function featureById(document, featureId) {
  const feature = document.features.find((candidate) => candidate.id === featureId);
  if (!feature) throw new Error(`invalid_reference: feature '${featureId}' does not exist`);
  return feature;
}

function replaceSolid(current, next) {
  current.free();
  return next;
}

function translated(solid, x, y, z) {
  return replaceSolid(solid, solid.translate(x, y, z));
}

function rotated(solid, x, y, z) {
  return x || y || z ? replaceSolid(solid, solid.rotate(x, y, z)) : solid;
}

function scaled(solid, x, y, z) {
  return x !== 1 || y !== 1 || z !== 1 ? replaceSolid(solid, solid.scale(x, y, z)) : solid;
}

function placedAroundCenter(solid, params) {
  const x = params.x || 0, y = params.y || 0, z = params.z || 0;
  const rx = params.rotation_x || 0, ry = params.rotation_y || 0, rz = params.rotation_z || 0;
  const sx = params.scale_x ?? 1, sy = params.scale_y ?? 1, sz = params.scale_z ?? 1;
  if (!x && !y && !z && !rx && !ry && !rz && sx === 1 && sy === 1 && sz === 1) return solid;
  const bounds = Array.from(solid.boundingBox());
  const center = [(bounds[0] + bounds[3]) / 2, (bounds[1] + bounds[4]) / 2, (bounds[2] + bounds[5]) / 2];
  solid = translated(solid, -center[0], -center[1], -center[2]);
  solid = scaled(solid, sx, sy, sz);
  solid = rotated(solid, rx, ry, rz);
  return translated(solid, center[0] + x, center[1] + y, center[2] + z);
}

function selectedEdgeBlend(solid, feature) {
  const p = feature.params, mode = p.selector_mode;
  if (mode === undefined) return feature.kind === "edge_fillet" ? solid.fillet(p.radius) : solid.chamfer(p.distance);
  let stableEdge;
  if (mode === 3) {
    const requestedId = Math.round(p.selector_edge_id);
    stableEdge = Array.from(solid.getMesh(48).topologyEdges || []).find((edge) => {
      if (edge.id !== requestedId) return false;
      if (p.selector_edge_face_a === undefined || p.selector_edge_face_b === undefined) return true;
      return edge.faceIds?.[0] === Math.round(p.selector_edge_face_a) && edge.faceIds?.[1] === Math.round(p.selector_edge_face_b);
    });
  }
  const stablePoint = stableEdge?.anchor ? { x: stableEdge.anchor[0], y: stableEdge.anchor[1], z: stableEdge.anchor[2] } : undefined;
  const edges = mode === 3 && stablePoint
    ? { type: "NearOnFace", point: stablePoint, face_ordinal: Math.round(p.selector_face_id ?? stableEdge.faceIds[0]) }
    : mode === 1 || mode === 3
    ? p.selector_face_id === undefined
      ? { type: "Near", point: { x: p.selector_x, y: p.selector_y, z: p.selector_z } }
      : { type: "NearOnFace", point: { x: p.selector_x, y: p.selector_y, z: p.selector_z }, face_ordinal: Math.round(p.selector_face_id) }
    : mode === 2
      ? { type: "Direction", axis: { x: p.selector_x, y: p.selector_y, z: p.selector_z }, tol_deg: p.selector_tolerance }
      : { type: "All" };
  const size = feature.kind === "edge_fillet" ? p.radius : p.distance;
  return solid.edgeBlend(JSON.stringify({ edges, profile: { type: "Constant", size, shape: feature.kind === "edge_fillet" ? 1 : 0 } }));
}

function buildBasePlate(Solid, document, allowHidden = false) {
  const sketch = featureById(document, "sketch-base");
  const pad = featureById(document, "pad-base");
  const pockets = featureById(document, "pocket-holes");
  if (!allowHidden && (sketch.visible === false || pad.visible === false)) throw new Error("kernel_empty: the base sketch or pad is hidden");
  const width = sketch.params.width, height = sketch.params.height, depth = pad.params.length;
  if (!allowHidden && pockets.visible === false) {
    let solid = Solid.cube(width, height, depth);
    return translated(solid, -width / 2, -height / 2, -depth / 2);
  }
  const radius = pockets.params.diameter / 2, offset = pockets.params.offset;
  const circle = (cx, cy) => [
    { type: "Arc", start: [cx + radius, cy], end: [cx, cy + radius], center: [cx, cy], ccw: true },
    { type: "Arc", start: [cx, cy + radius], end: [cx - radius, cy], center: [cx, cy], ccw: true },
    { type: "Arc", start: [cx - radius, cy], end: [cx, cy - radius], center: [cx, cy], ccw: true },
    { type: "Arc", start: [cx, cy - radius], end: [cx + radius, cy], center: [cx, cy], ccw: true }
  ];
  const profile = {
    origin: [0, 0, -depth / 2], x_dir: [1, 0, 0], y_dir: [0, 1, 0],
    segments: [
      { type: "Line", start: [-width / 2, -height / 2], end: [width / 2, -height / 2] },
      { type: "Line", start: [width / 2, -height / 2], end: [width / 2, height / 2] },
      { type: "Line", start: [width / 2, height / 2], end: [-width / 2, height / 2] },
      { type: "Line", start: [-width / 2, height / 2], end: [-width / 2, -height / 2] }
    ],
    holes: [-width / 2 + offset, width / 2 - offset].flatMap((x) =>
      [-height / 2 + offset, height / 2 - offset].map((y) => circle(x, y)))
  };
  return Solid.extrude(JSON.stringify(profile), new Float64Array([0, 0, depth]));
}

function buildPrimitive(Solid, feature) {
  const x = feature.params.x || 0, y = feature.params.y || 0, z = feature.params.z || 0;
  const rx = feature.params.rotation_x || 0, ry = feature.params.rotation_y || 0, rz = feature.params.rotation_z || 0;
  const place = (solid) => translated(rotated(solid, rx, ry, rz), x, y, z);
  if (feature.kind === "box") {
    let solid = Solid.cube(feature.params.width, feature.params.height, feature.params.depth);
    solid = translated(solid, -feature.params.width / 2, -feature.params.height / 2, -feature.params.depth / 2);
    return place(solid);
  }
  if (feature.kind === "cylinder") {
    let solid = Solid.cylinder(feature.params.radius, feature.params.height, 48);
    solid = translated(solid, 0, 0, -feature.params.height / 2);
    return place(solid);
  }
  if (feature.kind === "cone") {
    let solid = Solid.cone(feature.params.radius_bottom, feature.params.radius_top, feature.params.height, 48);
    solid = translated(solid, 0, 0, -feature.params.height / 2);
    return place(solid);
  }
  if (feature.kind === "sphere") {
    let solid = Solid.sphere(feature.params.radius, 48);
    return place(solid);
  }
  if (feature.kind === "torus") {
    let solid = Solid.torus(feature.params.major_radius, feature.params.tube_radius, 48);
    return place(solid);
  }
  throw new Error(`unsupported_kernel_feature: '${feature.id}' has kind '${feature.kind}'`);
}

function sketchProfile(feature, operation) {
  const sketch = feature.sketch, entities = (sketch?.entities || []).filter((entity) => !entity.construction);
  if (!sketch || !entities.length) throw new Error(`invalid_profile: '${feature.id}' has no profile geometry`);
  const loops = new Map();
  for (const entity of entities) { const loopId = entity.loop_id || "outer"; if (!loops.has(loopId)) loops.set(loopId, []); loops.get(loopId).push(entity); }
  if (!loops.has("outer")) throw new Error(`invalid_profile: '${feature.id}' has no outer loop`);
  const segmentLoop = (loopEntities) => {
  let segments;
  if (loopEntities.length === 1 && loopEntities[0].kind === "circle") {
    const { cx, cy, radius } = loopEntities[0].params;
    segments = [
      { type: "Arc", start: [cx + radius, cy], end: [cx, cy + radius], center: [cx, cy], ccw: true },
      { type: "Arc", start: [cx, cy + radius], end: [cx - radius, cy], center: [cx, cy], ccw: true },
      { type: "Arc", start: [cx - radius, cy], end: [cx, cy - radius], center: [cx, cy], ccw: true },
      { type: "Arc", start: [cx, cy - radius], end: [cx + radius, cy], center: [cx, cy], ccw: true }
    ];
  } else {
    segments = loopEntities.map((entity) => {
      if (entity.kind === "line") return { type: "Line", start: [entity.params.x1, entity.params.y1], end: [entity.params.x2, entity.params.y2] };
      if (entity.kind === "arc") {
        const p = entity.params;
        return { type: "Arc", start: [p.cx + Math.cos(p.start_angle) * p.radius, p.cy + Math.sin(p.start_angle) * p.radius], end: [p.cx + Math.cos(p.end_angle) * p.radius, p.cy + Math.sin(p.end_angle) * p.radius], center: [p.cx, p.cy], ccw: p.ccw !== 0 };
      }
      throw new Error(`unsupported_sketch_entity: '${entity.kind}'`);
    });
  }
  return segments;
  };
  const length = operation.params.length ?? 1;
  const axes = {
    XY: { x: [1, 0, 0], y: [0, 1, 0], normal: [0, 0, 1], direction: [0, 0, length] },
    XZ: { x: [1, 0, 0], y: [0, 0, 1], normal: [0, -1, 0], direction: [0, -length, 0] },
    YZ: { x: [0, 1, 0], y: [0, 0, 1], normal: [1, 0, 0], direction: [length, 0, 0] }
  }[sketch.plane];
  if (!axes) throw new Error(`unsupported_plane: '${sketch.plane}'`);
  const symmetric = operation.params.symmetric !== undefined && operation.params.symmetric !== 0;
  const offset = feature.params?.offset ?? 0;
  const origin = axes.normal.map((value, index) => value * offset + (symmetric ? -axes.direction[index] / 2 : 0));
  const orderedLoops = [...loops.entries()].sort(([a], [b]) => a === "outer" ? -1 : b === "outer" ? 1 : a.localeCompare(b));
  const onlyOuter = orderedLoops.length === 1 ? orderedLoops[0][1] : null;
  const circle = onlyOuter?.length === 1 && onlyOuter[0].kind === "circle" ? { ...onlyOuter[0].params, plane: sketch.plane, origin } : null;
  return { profiles: orderedLoops.map(([loopId, loopEntities]) => ({ loopId, profile: { origin, x_dir: axes.x, y_dir: axes.y, segments: segmentLoop(loopEntities) } })), direction: new Float64Array(axes.direction), circle };
}

function profileBoolean(Solid, converted, makeSolid) {
  let solid = makeSolid(converted.profiles[0].profile);
  for (const hole of converted.profiles.slice(1)) {
    const cutter = makeSolid(hole.profile);
    try { solid = replaceSolid(solid, solid.difference(cutter)); }
    finally { cutter.free(); }
  }
  return solid;
}

function extrudedProfileSolid(Solid, converted) {
  if (!converted.circle) return profileBoolean(Solid, converted, (profile) => Solid.extrude(JSON.stringify(profile), converted.direction));
  const { cx, cy, radius, plane, origin } = converted.circle;
  const length = Math.hypot(...converted.direction);
  let solid = Solid.cylinder(radius, length, 48);
  if (plane === "XY") return translated(solid, cx, cy, origin[2]);
  if (plane === "XZ") return translated(rotated(solid, 90, 0, 0), cx, origin[1], cy);
  if (plane === "YZ") return translated(rotated(solid, 0, 90, 0), origin[0], cx, cy);
  solid.free(); throw new Error(`unsupported_plane: '${plane}'`);
}

function buildSolid(Solid, document, featureId = "pad-base", allowHidden = false, stack = new Set()) {
  if (stack.has(featureId)) throw new Error(`cyclic_dependency: '${featureId}' appears twice in the kernel feature graph`);
  if (["sketch-base", "pad-base", "pocket-holes", "fillet-edges", "base-bracket"].includes(featureId)) {
    return { solid: buildBasePlate(Solid, document, allowHidden), featureId: "base-bracket", sourceFeatures: ["sketch-base", "pad-base", "pocket-holes"] };
  }
  const feature = featureById(document, featureId);
  if (!allowHidden && feature.visible === false) throw new Error(`kernel_empty: feature '${featureId}' is hidden`);
  if (feature.kind === "imported_step") {
    if (!feature.asset_path || typeof feature.asset_path !== "string") throw new Error(`invalid_asset: '${featureId}' has no STEP asset path`);
    const bodyNumber = Math.round(feature.params.body_number ?? 1);
    if (bodyNumber < 1) throw new Error(`invalid_asset: '${featureId}' body_number must be at least 1`);
    const solid = Solid.fromStepBuffer(readFileSync(feature.asset_path), bodyNumber - 1);
    return { solid, featureId, sourceFeatures: [] };
  }
  if (feature.kind === "extrude_feature") {
    if (!Array.isArray(feature.input_feature_ids) || feature.input_feature_ids.length !== 1) throw new Error(`invalid_dependency: '${featureId}' requires one sketch input`);
    const sketch = featureById(document, feature.input_feature_ids[0]);
    if (sketch.kind !== "profile_sketch") throw new Error(`invalid_dependency: '${featureId}' input is not a profile sketch`);
    const converted = sketchProfile(sketch, feature);
    return { solid: extrudedProfileSolid(Solid, converted), featureId, sourceFeatures: [sketch.id] };
  }
  if (feature.kind === "pocket_feature") {
    if (!Array.isArray(feature.input_feature_ids) || feature.input_feature_ids.length !== 2) throw new Error(`invalid_dependency: '${featureId}' requires target and sketch inputs`);
    const nextStack = new Set(stack); nextStack.add(featureId);
    const target = buildSolid(Solid, document, feature.input_feature_ids[0], true, nextStack);
    const sketch = featureById(document, feature.input_feature_ids[1]);
    if (sketch.kind !== "profile_sketch") { target.solid.free(); throw new Error(`invalid_dependency: '${featureId}' second input is not a profile sketch`); }
    const converted = sketchProfile(sketch, feature);
    const tool = extrudedProfileSolid(Solid, converted);
    try {
      return { solid: target.solid.difference(tool), featureId, sourceFeatures: [...new Set([...target.sourceFeatures, sketch.id])] };
    } finally { target.solid.free(); tool.free(); }
  }
  if (feature.kind === "revolve_feature") {
    if (!Array.isArray(feature.input_feature_ids) || feature.input_feature_ids.length !== 1) throw new Error(`invalid_dependency: '${featureId}' requires one sketch input`);
    const sketch = featureById(document, feature.input_feature_ids[0]);
    if (sketch.kind !== "profile_sketch") throw new Error(`invalid_dependency: '${featureId}' input is not a profile sketch`);
    const converted = sketchProfile(sketch, feature), p = feature.params;
    const axisOrigin = new Float64Array([p.origin_x, p.origin_y, p.origin_z]);
    const axisDirection = new Float64Array([p.axis_x, p.axis_y, p.axis_z]);
    return { solid: profileBoolean(Solid, converted, (profile) => Solid.revolve(JSON.stringify(profile), axisOrigin, axisDirection, p.angle)), featureId, sourceFeatures: [sketch.id] };
  }
  if (feature.kind === "sweep_feature") {
    if (!Array.isArray(feature.input_feature_ids) || feature.input_feature_ids.length < 1) throw new Error(`invalid_dependency: '${featureId}' requires at least one sketch input`);
    const sketch = featureById(document, feature.input_feature_ids[0]);
    if (sketch.kind !== "profile_sketch") throw new Error(`invalid_dependency: '${featureId}' input is not a profile sketch`);
    const converted = sketchProfile(sketch, feature), p = feature.params;
    const stationCount = Math.round(p.scale_station_count ?? 0);
    const scaleStations = JSON.stringify(Array.from({ length: stationCount }, (_, index) => ({ position: p[`scale_station_${index}_position`], scale: p[`scale_station_${index}_factor`] })));
    const profileStationCount = Math.round(p.profile_station_count ?? 0);
    if (feature.input_feature_ids.length !== profileStationCount + 1) throw new Error(`invalid_dependency: '${featureId}' profile station count does not match its sketch inputs`);
    const profileStations = feature.input_feature_ids.slice(1).map((inputId, index) => {
      const section = featureById(document, inputId);
      if (section.kind !== "profile_sketch") throw new Error(`invalid_dependency: '${inputId}' is not a profile sketch`);
      const sectionProfile = sketchProfile(section, feature);
      if (sectionProfile.profiles.length !== 1) throw new Error(`unsupported_kernel_profile: morph section '${inputId}' must contain one outer loop without holes`);
      return { position: p[`profile_station_${index}_position`], profile: sectionProfile.profiles[0].profile };
    });
    const profileStationsJSON = JSON.stringify(profileStations);
    const frameMode = Math.round(p.frame_mode ?? 0);
    const upDirection = new Float64Array([p.up_x ?? 0, p.up_y ?? 0, p.up_z ?? 1]);
    const guidePointCount = Math.round(p.guide_point_count ?? 0);
    const guidePoints = new Float64Array(Array.from({ length: guidePointCount }, (_, index) => [p[`guide_${index}_x`], p[`guide_${index}_y`], p[`guide_${index}_z`]]).flat());
    const runSweep = (profile) => {
      if (p.path_segment_count !== undefined) {
        const count = Math.round(p.path_segment_count);
        const point = (index, role) => [p[`path_${index}_${role}_x`], p[`path_${index}_${role}_y`], p[`path_${index}_${role}_z`]];
        const segments = Array.from({ length: count }, (_, index) => p[`path_${index}_kind`] === 0
          ? { type: "Line", start: point(index, "start"), end: point(index, "end") }
          : { type: "Arc", start: point(index, "start"), mid: point(index, "mid"), end: point(index, "end") });
        return Solid.sweepComposite(JSON.stringify(profile), JSON.stringify(segments), p.twist_angle, p.scale_start, p.scale_end, Math.max(16, count * 16), 12, 0, scaleStations, profileStationsJSON, frameMode, upDirection, guidePoints, Math.round(p.continuity_mode ?? 0), p.tangent_tolerance ?? 1);
      }
      if (p.path_point_count !== undefined) {
        const count = Math.round(p.path_point_count);
        const points = new Float64Array(Array.from({ length: count }, (_, index) => [p[`path_${index}_x`], p[`path_${index}_y`], p[`path_${index}_z`]]).flat());
        const tangentMode = Math.round(p.tangent_mode ?? 0);
        const tangent = (prefix, bit) => new Float64Array((tangentMode & bit) === 0 ? [] : [p[`${prefix}_tangent_x`], p[`${prefix}_tangent_y`], p[`${prefix}_tangent_z`]]);
        return Solid.sweepSpline(JSON.stringify(profile), points, p.twist_angle, p.scale_start, p.scale_end, Math.max(16, (count - 1) * 16), 12, 0, scaleStations, profileStationsJSON, frameMode, upDirection, guidePoints, tangent("start", 1), tangent("end", 2));
      }
      if (p.helix_radius !== undefined) {
        return Solid.sweepHelix(JSON.stringify(profile), p.helix_radius, p.helix_pitch, p.helix_pitch * p.helix_turns, p.helix_turns, p.twist_angle, p.scale_start, p.scale_end, 0, 12, 0, scaleStations, profileStationsJSON, frameMode, upDirection, guidePoints);
      }
      const start = new Float64Array([p.start_x, p.start_y, p.start_z]), end = new Float64Array([p.end_x, p.end_y, p.end_z]);
      return Solid.sweepLine(JSON.stringify(profile), start, end, p.twist_angle, p.scale_start, p.scale_end, 0, scaleStations, profileStationsJSON, frameMode, upDirection, guidePoints);
    };
    const solid = profileStationCount > 0
      ? (() => {
          if (converted.profiles.length !== 1) throw new Error(`unsupported_kernel_profile: morph sweep '${featureId}' must start from one outer loop without holes`);
          return runSweep(converted.profiles[0].profile);
        })()
      : profileBoolean(Solid, converted, runSweep);
    return { solid, featureId, sourceFeatures: [...feature.input_feature_ids] };
  }
  if (feature.kind === "loft_feature") {
    if (!Array.isArray(feature.input_feature_ids) || feature.input_feature_ids.length < 2) throw new Error(`invalid_dependency: '${featureId}' requires at least two sketch inputs`);
    const profiles = feature.input_feature_ids.map((inputId) => {
      const sketch = featureById(document, inputId);
      if (sketch.kind !== "profile_sketch") throw new Error(`invalid_dependency: '${inputId}' is not a profile sketch`);
      const converted = sketchProfile(sketch, feature);
      if (converted.profiles.length !== 1) throw new Error(`unsupported_kernel_profile: loft sketch '${inputId}' has inner loops`);
      return converted.profiles[0].profile;
    });
    return { solid: Solid.loft(JSON.stringify(profiles), feature.params.closed !== 0), featureId, sourceFeatures: [...feature.input_feature_ids] };
  }
  if (["boolean_union", "boolean_difference", "boolean_intersection"].includes(feature.kind)) {
    if (!Array.isArray(feature.input_feature_ids) || feature.input_feature_ids.length !== 2) throw new Error(`invalid_dependency: '${featureId}' requires two input_feature_ids`);
    const nextStack = new Set(stack); nextStack.add(featureId);
    const left = buildSolid(Solid, document, feature.input_feature_ids[0], true, nextStack);
    const right = buildSolid(Solid, document, feature.input_feature_ids[1], true, nextStack);
    try {
      const solid = feature.kind === "boolean_union" ? left.solid.union(right.solid)
        : feature.kind === "boolean_difference" ? left.solid.difference(right.solid)
        : left.solid.intersection(right.solid);
      return { solid, featureId, sourceFeatures: [...new Set([...left.sourceFeatures, ...right.sourceFeatures])] };
    } finally { left.solid.free(); right.solid.free(); }
  }
  if (feature.kind === "body_transform" || feature.kind === "assembly_instance") {
    if (!Array.isArray(feature.input_feature_ids) || feature.input_feature_ids.length !== 1) throw new Error(`invalid_dependency: '${featureId}' requires one input_feature_id`);
    const nextStack = new Set(stack); nextStack.add(featureId);
    const input = buildSolid(Solid, document, feature.input_feature_ids[0], true, nextStack);
    return { solid: placedAroundCenter(input.solid, feature.params), featureId, sourceFeatures: input.sourceFeatures };
  }
  if (["edge_fillet", "edge_chamfer", "shell_feature", "linear_pattern", "circular_pattern"].includes(feature.kind)) {
    if (!Array.isArray(feature.input_feature_ids) || feature.input_feature_ids.length !== 1) throw new Error(`invalid_dependency: '${featureId}' requires one input_feature_id`);
    const nextStack = new Set(stack); nextStack.add(featureId);
    const input = buildSolid(Solid, document, feature.input_feature_ids[0], true, nextStack);
    try {
      let solid;
      if (["edge_fillet", "edge_chamfer"].includes(feature.kind)) solid = selectedEdgeBlend(input.solid, feature);
      else if (feature.kind === "shell_feature") solid = input.solid.shell(feature.params.thickness);
      else if (feature.kind === "linear_pattern") solid = input.solid.linearPattern(feature.params.direction_x, feature.params.direction_y, feature.params.direction_z, Math.round(feature.params.count), feature.params.spacing);
      else solid = input.solid.circularPattern(feature.params.origin_x, feature.params.origin_y, feature.params.origin_z, feature.params.axis_x, feature.params.axis_y, feature.params.axis_z, Math.round(feature.params.count), feature.params.angle);
      return { solid, featureId, sourceFeatures: input.sourceFeatures };
    } finally { input.solid.free(); }
  }
  return { solid: buildPrimitive(Solid, feature), featureId, sourceFeatures: [featureId] };
}

function analyticVolume(document, featureId) {
  if (["sketch-base", "pad-base", "pocket-holes", "fillet-edges", "base-bracket"].includes(featureId)) {
    const sketch = featureById(document, "sketch-base"), pad = featureById(document, "pad-base"), pockets = featureById(document, "pocket-holes");
    const gross = sketch.params.width * sketch.params.height * pad.params.length;
    return pockets.visible === false ? gross : gross - 4 * Math.PI * (pockets.params.diameter / 2) ** 2 * pad.params.length;
  }
  const feature = featureById(document, featureId), p = feature.params;
  if (feature.kind === "box") return p.width * p.height * p.depth;
  if (feature.kind === "cylinder") return Math.PI * p.radius ** 2 * p.height;
  if (feature.kind === "cone") return Math.PI * p.height * (p.radius_bottom ** 2 + p.radius_bottom * p.radius_top + p.radius_top ** 2) / 3;
  if (feature.kind === "sphere") return 4 * Math.PI * p.radius ** 3 / 3;
  if (feature.kind === "torus") return 2 * Math.PI ** 2 * p.major_radius * p.tube_radius ** 2;
  return null;
}

function metrics(solid, expectedVolume = null) {
  const bounds = Array.from(solid.boundingBox());
  const center = Array.from(solid.centerOfMass());
  const mesh = solid.getMesh(48);
  const boundaryValues = solid.boundaryEdges(48);
  const boundaryEdgeSegments = boundaryValues.length / 6;
  const volume = solid.volume();
  const volumeDeviation = expectedVolume == null ? null : volume - expectedVolume;
  const volumeRelativeError = expectedVolume == null || expectedVolume === 0 ? null : Math.abs(volumeDeviation) / Math.abs(expectedVolume);
  const warnings = [];
  if (boundaryEdgeSegments > 0) warnings.push(`Tessellated mesh reports ${boundaryEdgeSegments} boundary edge segment(s); STEP-capable BRep exists, but closed-manifold mesh validation did not pass.`);
  if (!solid.canExportStep()) warnings.push("The kernel did not retain STEP-exportable BRep data for this result.");
  if (volumeRelativeError != null && volumeRelativeError > 0.01) warnings.push(`Kernel volume differs from the analytic primitive reference by ${(volumeRelativeError * 100).toFixed(3)}%.`);
  return {
    bounds: { minimum: { x: bounds[0], y: bounds[1], z: bounds[2] }, maximum: { x: bounds[3], y: bounds[4], z: bounds[5] } },
    volume,
    analytic_reference_volume: expectedVolume,
    volume_deviation: volumeDeviation,
    volume_relative_error: volumeRelativeError,
    volume_within_one_percent: volumeRelativeError == null ? null : volumeRelativeError <= 0.01,
    surface_area: solid.surfaceArea(),
    center_of_mass: { x: center[0], y: center[1], z: center[2] },
    triangle_count: mesh.indices.length / 3,
    boundary_edge_segments: boundaryEdgeSegments,
    closed_manifold_mesh: boundaryEdgeSegments === 0,
    can_export_step: solid.canExportStep(),
    warnings
  };
}

function importedMeshMetrics(mesh) {
  const positions = Array.from(mesh.positions || []), indices = Array.from(mesh.indices || []);
  if (positions.length < 9 || indices.length < 3) throw new Error("STEP reader returned an empty tessellation");
  const minimum = [Infinity, Infinity, Infinity], maximum = [-Infinity, -Infinity, -Infinity];
  for (let index = 0; index < positions.length; index += 3) {
    for (let axis = 0; axis < 3; axis += 1) {
      minimum[axis] = Math.min(minimum[axis], positions[index + axis]);
      maximum[axis] = Math.max(maximum[axis], positions[index + axis]);
    }
  }
  let signedVolume = 0;
  for (let index = 0; index < indices.length; index += 3) {
    const a = indices[index] * 3, b = indices[index + 1] * 3, c = indices[index + 2] * 3;
    signedVolume += positions[a] * (positions[b + 1] * positions[c + 2] - positions[b + 2] * positions[c + 1])
      + positions[a + 1] * (positions[b + 2] * positions[c] - positions[b] * positions[c + 2])
      + positions[a + 2] * (positions[b] * positions[c + 1] - positions[b + 1] * positions[c]);
  }
  return {
    bounds: { minimum: { x: minimum[0], y: minimum[1], z: minimum[2] }, maximum: { x: maximum[0], y: maximum[1], z: maximum[2] } },
    volume: Math.abs(signedVolume) / 6,
    triangle_count: indices.length / 3
  };
}

function validateStepRoundTrip(module, solid, properties, stepBytes = null) {
  if (!properties.can_export_step) return { attempted: false, passed: false, reader: "vcad-step-import", body_count: 0, triangle_count: 0, volume: null, volume_relative_error: null, bounds_max_deviation: null };
  try {
    const bytes = stepBytes || solid.toStepBuffer();
    let imported, reopened, retainedBRep = true;
    if (typeof module.inspectStepBuffer === "function") {
      imported = JSON.parse(module.inspectStepBuffer(bytes));
      if (!Array.isArray(imported) || imported.length !== 1) throw new Error(`STEP reader returned ${imported?.length ?? 0} bodies; expected one`);
      const body = imported[0], bounds = body.bounds;
      if (!Array.isArray(bounds) || bounds.length !== 6) throw new Error("STEP reader returned invalid bounds");
      reopened = { bounds: { minimum: { x: bounds[0], y: bounds[1], z: bounds[2] }, maximum: { x: bounds[3], y: bounds[4], z: bounds[5] } }, volume: body.volume, triangle_count: body.triangle_count };
      retainedBRep = body.can_export_step === true;
    } else {
      imported = module.importStepBuffer(bytes);
      if (!Array.isArray(imported) || imported.length !== 1) throw new Error(`STEP reader returned ${imported?.length ?? 0} bodies; expected one`);
      reopened = importedMeshMetrics(imported[0]);
    }
    const originalBounds = [...Object.values(properties.bounds.minimum), ...Object.values(properties.bounds.maximum)];
    const reopenedBounds = [...Object.values(reopened.bounds.minimum), ...Object.values(reopened.bounds.maximum)];
    const boundsMaxDeviation = Math.max(...originalBounds.map((value, index) => Math.abs(value - reopenedBounds[index])));
    const volumeRelativeError = properties.volume === 0 ? null : Math.abs(reopened.volume - properties.volume) / Math.abs(properties.volume);
    return {
      attempted: true,
      // `passed` is the fast retained-BRep reopen gate.  Curved-face volume
      // integration is tessellation-dependent, so its numeric agreement is
      // reported separately instead of rejecting a structurally valid STEP.
      passed: retainedBRep && boundsMaxDeviation <= 0.1,
      reader: "vcad-step-import",
      body_count: imported.length,
      triangle_count: reopened.triangle_count,
      volume: reopened.volume,
      volume_relative_error: volumeRelativeError,
      bounds_max_deviation: boundsMaxDeviation
    };
  } catch (error) {
    return { attempted: true, passed: false, reader: "vcad-step-import", body_count: 0, triangle_count: 0, volume: null, volume_relative_error: null, bounds_max_deviation: null, error: error instanceof Error ? error.message : String(error) };
  }
}

function withStepRoundTrip(module, solid, properties, stepBytes = null) {
  const stepRoundtrip = validateStepRoundTrip(module, solid, properties, stepBytes);
  if (stepRoundtrip.attempted && !stepRoundtrip.passed) properties.warnings.push(`STEP round-trip validation failed${stepRoundtrip.error ? `: ${stepRoundtrip.error}` : "."}`);
  if (stepRoundtrip.volume_relative_error != null && stepRoundtrip.volume_relative_error > 0.01) properties.warnings.push(`STEP re-import volume metric differs by ${(stepRoundtrip.volume_relative_error * 100).toFixed(3)}%; retained BRep and bounds were verified.`);
  return { ...properties, step_roundtrip: stepRoundtrip };
}

export async function getKernelStatus() {
  try {
    const packageJSON = JSON.parse(await readFile(packagePath, "utf8"));
    await loadKernel();
    return { available: true, adapter: "vcad-wasm", version: packageJSON.version, license: packageJSON.license, kernel_directory: kernelDirectory, execution: "out-of-process/lazy", bundled_with_app: process.env.AXIS_CAD_BUNDLED_KERNEL === "1" };
  } catch (error) {
    return { available: false, adapter: "vcad-wasm", kernel_directory: kernelDirectory, error: error instanceof Error ? error.message : String(error) };
  }
}

export async function validateWithKernel(document, featureId = "pad-base") {
  const module = await loadKernel();
  return quietly(async () => {
    const built = buildSolid(module.Solid, document, featureId);
    try {
      const properties = withStepRoundTrip(module, built.solid, metrics(built.solid, analyticVolume(document, featureId)));
      return {
        ok: properties.can_export_step && properties.closed_manifold_mesh && properties.step_roundtrip.passed,
        revision: document.revision,
        feature_id: built.featureId,
        source_features: built.sourceFeatures,
        adapter: "vcad-wasm",
        kernel_mass_properties: true,
        ...properties
      };
    } finally { built.solid.free(); }
  });
}

export async function inspectStepFile(inputPath) {
  const module = await loadKernel();
  return quietly(async () => {
    const bytes = await readFile(inputPath);
    if (bytes.length < 32) throw new Error("step_invalid: file is empty or truncated");
    const inspected = JSON.parse(module.inspectStepBuffer(bytes));
    if (!Array.isArray(inspected) || inspected.length === 0) throw new Error("step_invalid: reader found no solid bodies");
    const preview = module.importStepBuffer(bytes);
    if (!Array.isArray(preview) || preview.length !== inspected.length) throw new Error("step_invalid: exact reader and preview tessellator disagree on body count");
    const bodies = inspected.map((body, index) => {
      if (!Array.isArray(body.bounds) || body.bounds.length !== 6 || body.can_export_step !== true) throw new Error(`step_invalid: body ${index + 1} did not retain exportable BRep data`);
      return { body_number: index + 1, bounds: { minimum: { x: body.bounds[0], y: body.bounds[1], z: body.bounds[2] }, maximum: { x: body.bounds[3], y: body.bounds[4], z: body.bounds[5] } }, volume: body.volume, surface_area: body.surface_area, triangle_count: body.triangle_count, can_export_step: true };
    });
    return { ok: true, adapter: "vcad-wasm", source_path: inputPath, byte_count: bytes.length, body_count: bodies.length, bodies };
  });
}

export async function exportStep(document, featureId, outputPath) {
  const module = await loadKernel();
  return quietly(async () => {
    const built = buildSolid(module.Solid, document, featureId);
    try {
      const baseProperties = metrics(built.solid, analyticVolume(document, featureId));
      if (!baseProperties.can_export_step) throw new Error(`step_unavailable: '${built.featureId}' has no exportable BRep`);
      const rawStepBytes = built.solid.toStepBuffer();
      const properties = withStepRoundTrip(module, built.solid, baseProperties, rawStepBytes);
      const bytes = Buffer.from(rawStepBytes);
      await mkdir(path.dirname(outputPath), { recursive: true });
      const temporaryPath = `${outputPath}.${process.pid}.tmp`;
      await writeFile(temporaryPath, bytes);
      await rename(temporaryPath, outputPath);
      return { ok: true, revision: document.revision, feature_id: built.featureId, path: outputPath, byte_count: bytes.length, adapter: "vcad-wasm", validation: properties };
    } finally { built.solid.free(); }
  });
}

function stepName(value) {
  return String(value || "AxisCAD part").replaceAll("'", "''");
}

function combineStepBodies(entries) {
  let offset = 0;
  const entities = [];
  for (const entry of entries) {
    const text = Buffer.from(entry.bytes).toString("utf8");
    const section = text.match(/DATA;\s*([\s\S]*?)\s*ENDSEC;/i)?.[1];
    if (!section) throw new Error(`step_invalid: '${entry.name}' has no DATA section`);
    const ids = [...section.matchAll(/#(\d+)/g)].map((match) => Number(match[1]));
    if (!ids.length) throw new Error(`step_invalid: '${entry.name}' has no entities`);
    const renamed = section
      .replace(/MANIFOLD_SOLID_BREP\('Solid'/g, `MANIFOLD_SOLID_BREP('${stepName(entry.name)}'`)
      .replace(/#(\d+)/g, (_, id) => `#${Number(id) + offset}`);
    entities.push(renamed.trim());
    offset += Math.max(...ids);
  }
  const timestamp = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
  return Buffer.from(`ISO-10303-21;\nHEADER;\nFILE_DESCRIPTION(('AxisCAD solved multi-body assembly'),'2;1');\nFILE_NAME('axis-cad-assembly.step','${timestamp}',('AxisCAD'),('AxisCAD'),'AxisCAD vcad bridge','AxisCAD','');\nFILE_SCHEMA(('AUTOMOTIVE_DESIGN'));\nENDSEC;\nDATA;\n${entities.join("\n")}\nENDSEC;\nEND-ISO-10303-21;\n`, "utf8");
}

function aggregateBodies(bodies) {
  const minimum = { x: Infinity, y: Infinity, z: Infinity }, maximum = { x: -Infinity, y: -Infinity, z: -Infinity };
  let volume = 0, triangleCount = 0;
  for (const body of bodies) {
    const bounds = Array.isArray(body.bounds) ? { minimum: { x: body.bounds[0], y: body.bounds[1], z: body.bounds[2] }, maximum: { x: body.bounds[3], y: body.bounds[4], z: body.bounds[5] } } : body.bounds;
    for (const axis of ["x", "y", "z"]) { minimum[axis] = Math.min(minimum[axis], bounds.minimum[axis]); maximum[axis] = Math.max(maximum[axis], bounds.maximum[axis]); }
    volume += body.volume; triangleCount += body.triangle_count;
  }
  return { bounds: { minimum, maximum }, volume, triangle_count: triangleCount };
}

export async function exportAssemblyStep(document, outputPath) {
  const module = await loadKernel();
  return quietly(async () => {
    const instances = document.features.filter((feature) => feature.kind === "assembly_instance" && feature.visible);
    if (!instances.length) throw new Error("empty_assembly: no visible assembly instances to export");
    const built = [];
    try {
      for (const instance of instances) {
        const result = buildSolid(module.Solid, document, instance.id);
        if (!result.solid.canExportStep()) { result.solid.free(); throw new Error(`step_unavailable: '${instance.id}' has no exportable BRep`); }
        const properties = metrics(result.solid, null);
        built.push({ id: instance.id, name: instance.name, solid: result.solid, properties, bytes: result.solid.toStepBuffer() });
      }
      const bytes = combineStepBodies(built);
      const inspected = typeof module.inspectStepBuffer === "function" ? JSON.parse(module.inspectStepBuffer(bytes)) : module.importStepBuffer(bytes).map(importedMeshMetrics);
      const expected = aggregateBodies(built.map((entry) => ({ bounds: entry.properties.bounds, volume: entry.properties.volume, triangle_count: entry.properties.triangle_count })));
      const reopened = aggregateBodies(inspected);
      const expectedBounds = [...Object.values(expected.bounds.minimum), ...Object.values(expected.bounds.maximum)];
      const reopenedBounds = [...Object.values(reopened.bounds.minimum), ...Object.values(reopened.bounds.maximum)];
      const boundsMaxDeviation = Math.max(...expectedBounds.map((value, index) => Math.abs(value - reopenedBounds[index])));
      const volumeRelativeError = expected.volume === 0 ? null : Math.abs(reopened.volume - expected.volume) / Math.abs(expected.volume);
      const retainedBRep = inspected.every((body) => body.can_export_step !== false);
      const passed = inspected.length === built.length && retainedBRep && boundsMaxDeviation <= 0.05 && volumeRelativeError != null && volumeRelativeError <= 0.01;
      if (!passed) throw new Error(`assembly_step_roundtrip_failed: expected ${built.length} bodies, reopened ${inspected.length}, bounds deviation ${boundsMaxDeviation}, volume error ${volumeRelativeError}`);
      await mkdir(path.dirname(outputPath), { recursive: true });
      const temporaryPath = `${outputPath}.${process.pid}.tmp`;
      await writeFile(temporaryPath, bytes); await rename(temporaryPath, outputPath);
      return { ok: true, revision: document.revision, path: outputPath, byte_count: bytes.length, adapter: "vcad-wasm", instance_count: built.length, body_count: inspected.length, instance_ids: built.map((entry) => entry.id), bounds: expected.bounds, volume: expected.volume, step_roundtrip: { attempted: true, passed, reader: "vcad-step-import", body_count: inspected.length, triangle_count: reopened.triangle_count, volume: reopened.volume, volume_relative_error: volumeRelativeError, bounds_max_deviation: boundsMaxDeviation } };
    } finally { for (const entry of built) entry.solid.free(); }
  });
}

export async function getRenderMesh(document, featureId) {
  const module = await loadKernel();
  return quietly(async () => {
    const built = buildSolid(module.Solid, document, featureId);
    try {
      const mesh = built.solid.getMesh(48);
      return {
        ok: true,
        revision: document.revision,
        feature_id: built.featureId,
        source_features: built.sourceFeatures,
        positions: Array.from(mesh.positions),
        normals: Array.from(mesh.normals || []),
        indices: Array.from(mesh.indices),
        face_ids: Array.from(mesh.faceIds || []),
        topology_edges: Array.from(mesh.topologyEdges || []).map((edge) => ({
          id: edge.id, face_ids: Array.from(edge.faceIds || []), positions: Array.from(edge.positions || []), anchor: Array.from(edge.anchor || []),
          length: edge.length, length_exact: edge.lengthExact, curve_kind: edge.curveKind, radius: edge.radius ?? null
        })),
        topology_faces: Array.from(mesh.topologyFaces || []).map((face) => ({
          id: face.id, area: face.area, area_exact: face.areaExact, surface_kind: face.surfaceKind, radius: face.radius ?? null
        })),
        boundary_edge_segments: built.solid.boundaryEdges(48).length / 6
      };
    } finally { built.solid.free(); }
  });
}

export async function checkClearance(document, featureId, secondFeatureId) {
  if (featureId === secondFeatureId) throw new Error("invalid_clearance: choose two distinct solid features");
  const module = await loadKernel();
  return quietly(async () => {
    const first = buildSolid(module.Solid, document, featureId);
    let second;
    try {
      second = buildSolid(module.Solid, document, secondFeatureId);
      const meshA = first.solid.getMesh(32), meshB = second.solid.getMesh(32);
      const clearance = module.mesh_clearance(meshA.positions, meshA.indices, meshB.positions, meshB.indices);
      const distance = Number(clearance.distance);
      const classification = clearance.intersecting ? "interference" : Math.abs(distance) <= 1e-6 ? "touching" : "clear";
      return {
        ok: true, revision: document.revision, feature_id: first.featureId, second_feature_id: second.featureId,
        distance, intersecting: Boolean(clearance.intersecting), classification,
        point_a: { x: clearance.pointA[0], y: clearance.pointA[1], z: clearance.pointA[2] },
        point_b: { x: clearance.pointB[0], y: clearance.pointB[1], z: clearance.pointB[2] },
        adapter: "vcad-wasm", tessellation_segments: 32
      };
    } finally {
      first.solid.free();
      second?.solid.free();
    }
  });
}

async function runCLI() {
  const request = JSON.parse(await new Promise((resolve, reject) => {
    let body = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => { body += chunk; });
    process.stdin.on("end", () => resolve(body));
    process.stdin.on("error", reject);
  }));
  if (request.action === "status") return getKernelStatus();
  if (request.action === "inspect_step") return inspectStepFile(request.input_path);
  const document = request.document || JSON.parse(await readFile(request.document_path, "utf8"));
  if (request.action === "validate") return validateWithKernel(document, request.feature_id);
  if (request.action === "mesh") return getRenderMesh(document, request.feature_id);
  if (request.action === "clearance") return checkClearance(document, request.feature_id, request.second_feature_id);
  if (request.action === "export_step") return exportStep(document, request.feature_id, request.output_path);
  if (request.action === "export_assembly_step") return exportAssemblyStep(document, request.output_path);
  throw new Error(`unsupported_action: '${request.action}'`);
}

if (process.env.AXIS_CAD_COMPILED_WORKER === "1" || (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url))) {
  runCLI().then((payload) => process.stdout.write(`${JSON.stringify(payload)}\n`)).catch((error) => {
    process.stdout.write(`${JSON.stringify({ ok: false, error: error instanceof Error ? error.message : String(error) })}\n`);
    process.exitCode = 1;
  });
}
