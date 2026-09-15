#!/usr/bin/env node

import { mkdir, readFile, readdir, rename, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import * as z from "zod/v4";
import { invokeKernel } from "../kernel/vcad-kernel-client.mjs";

const defaultDataRoot = process.platform === "darwin"
  ? path.join(os.homedir(), "Library", "Application Support", "AxisCAD")
  : path.join(os.homedir(), ".axis-cad");
const dataRoot = path.resolve(process.env.AXIS_CAD_DATA_DIR || defaultDataRoot);
const documentPath = path.join(dataRoot, "active-document.json");
const selectionPath = path.join(dataRoot, "active-selection.json");
const viewPath = path.join(dataRoot, "active-view.json");
const sourcingPath = path.join(dataRoot, "sourcing-candidates.json");
const checkpointsPath = path.join(dataRoot, "checkpoints");
const validateWithKernel = (document, featureId, signal) => invokeKernel({ action: "validate", document, feature_id: featureId }, { signal });
const getRenderMesh = (document, featureId, signal) => invokeKernel({ action: "mesh", document, feature_id: featureId }, { signal });
const checkClearance = (document, featureId, secondFeatureId, signal) => invokeKernel({ action: "clearance", document, feature_id: featureId, second_feature_id: secondFeatureId }, { signal });
const inspectStepFile = (inputPath, signal) => invokeKernel({ action: "inspect_step", input_path: inputPath }, { signal });
const exportStep = (document, featureId, outputPath, signal) => invokeKernel({ action: "export_step", document, feature_id: featureId, output_path: outputPath }, { signal });
const exportAssemblyStep = (document, outputPath, signal) => invokeKernel({ action: "export_assembly_step", document, output_path: outputPath }, { signal });
const getKernelStatus = (signal) => invokeKernel({ action: "status" }, { signal });
const materialPresets = {
  unassigned: { id: 0, density: 0, color: null }, aluminum_6061: { id: 1, density: 0.00270, color: [0.72, 0.76, 0.80] }, mild_steel: { id: 2, density: 0.00785, color: [0.34, 0.39, 0.43] }, stainless_steel: { id: 3, density: 0.00800, color: [0.58, 0.64, 0.68] }, titanium: { id: 4, density: 0.00443, color: [0.48, 0.52, 0.58] }, abs_plastic: { id: 5, density: 0.00104, color: [0.15, 0.18, 0.22] }
};
function materialName(id) { return Object.entries(materialPresets).find(([, preset]) => preset.id === id)?.[0] ?? "unassigned"; }

const seedDocument = {
  id: "wall-bracket",
  name: "Wall bracket",
  units: "mm",
  revision: 18,
  backend: "native-metal",
  features: [
    { id: "sketch-base", name: "Base profile", kind: "sketch", visible: true, params: { width: 86, height: 54 }, sketch: {
      plane: "XY", profile: "centered-rectangle-four-holes", constraints: [
        { id: "origin", kind: "coincident", entities: ["profile-center", "origin"] },
        { id: "top-horizontal", kind: "horizontal", entities: ["edge-top"] },
        { id: "bottom-horizontal", kind: "horizontal", entities: ["edge-bottom"] },
        { id: "left-vertical", kind: "vertical", entities: ["edge-left"] },
        { id: "right-vertical", kind: "vertical", entities: ["edge-right"] },
        { id: "profile-width", kind: "distance", entities: ["edge-left", "edge-right"], parameter: "width" },
        { id: "profile-height", kind: "distance", entities: ["edge-bottom", "edge-top"], parameter: "height" },
        { id: "equal-holes", kind: "equal", entities: ["hole-nw", "hole-ne", "hole-sw", "hole-se"], parameter: "diameter" },
        { id: "symmetric-holes-x", kind: "symmetric", entities: ["holes", "axis-y"] },
        { id: "symmetric-holes-y", kind: "symmetric", entities: ["holes", "axis-x"] },
        { id: "hole-edge-offset", kind: "distance", entities: ["profile", "holes"], parameter: "offset" }
      ]
    } },
    { id: "pad-base", name: "Base extrusion", kind: "pad", visible: true, params: { length: 6 } },
    { id: "pocket-holes", name: "Mounting holes", kind: "pocket", visible: true, params: { diameter: 5, offset: 12 } },
    { id: "fillet-edges", name: "Edge rounds", kind: "fillet", visible: true, params: { radius: 3 } }
  ],
  operations: []
};

const sketchEntitySchema = z.object({ id: z.string(), kind: z.string(), params: z.record(z.string(), z.number()), construction: z.boolean().optional(), loop_id: z.string().optional() });
const sketchConstraintSchema = z.object({ id: z.string(), kind: z.string(), entities: z.array(z.string()), parameter: z.string().optional(), value: z.number().optional() });
const selectionVectorSchema = z.object({ x: z.number(), y: z.number(), z: z.number() });
const compositePathSegmentSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("line"), start: selectionVectorSchema, end: selectionVectorSchema }),
  z.object({ type: z.literal("arc"), start: selectionVectorSchema, mid: selectionVectorSchema, end: selectionVectorSchema })
]);
const sweepScaleStationSchema = z.object({
  position: z.number().gt(0).lt(1).describe("Normalized distance along the path, strictly between 0 and 1"),
  scale: z.number().positive().describe("Uniform profile scale at this station")
});
const sweepProfileSectionSchema = z.object({
  sketch_id: z.string().min(1),
  position: z.number().finite().gt(0).lte(1)
});
const sweepFrameModeSchema = z.enum(["minimum_twist", "curvature", "fixed_up"]);
const sweepContinuitySchema = z.enum(["position", "tangent", "curvature"]);
const sweepGuidePointsSchema = z.array(selectionVectorSchema).max(12)
  .refine((points) => points.length === 0 || points.length >= 2, "Guide rail needs at least two points");
const selectionSurfaceSchema = z.object({
  feature_id: z.string(), triangle_index: z.number().int().nonnegative(),
  topology_face_id: z.number().int().nonnegative().optional(),
  topology_edge_id: z.number().int().nonnegative().optional(),
  topology_edge_face_ids: z.array(z.number().int().nonnegative()).length(2).optional(),
  position: selectionVectorSchema, normal: selectionVectorSchema
});
const sectionPlaneSchema = z.object({ axis: z.enum(["x", "y", "z"]), offset: z.number(), flipped: z.boolean() });
const motionStudySchema = z.object({ mate_id: z.string(), parameter: z.string(), minimum: z.number(), maximum: z.number(), progress: z.number(), playing: z.boolean(), value: z.number() });
const measurementProbeSchema = z.object({
  revision: z.number().int().nonnegative(), start: selectionVectorSchema, end: selectionVectorSchema.nullable(),
  distance: z.number().nonnegative().nullable(), delta: selectionVectorSchema.nullable()
});
const kernelDerivedKinds = new Set(["extrude_feature", "pocket_feature", "revolve_feature", "sweep_feature", "loft_feature", "boolean_union", "boolean_difference", "boolean_intersection", "edge_fillet", "edge_chamfer", "shell_feature", "linear_pattern", "circular_pattern", "body_transform", "assembly_instance", "imported_step"]);
const bodyTransformSourceKinds = new Set(["box", "cylinder", "cone", "sphere", "torus", ...kernelDerivedKinds]);
const featureSchema = z.object({
  id: z.string(), name: z.string(), kind: z.string(), visible: z.boolean(),
  params: z.record(z.string(), z.number()), sketch: z.object({
    plane: z.string(), profile: z.string(), constraints: z.array(sketchConstraintSchema), entities: z.array(sketchEntitySchema).optional()
  }).optional(), input_feature_ids: z.array(z.string()).optional(), asset_path: z.string().optional()
});

function solveSketch(document) {
  const profile = featureById(document, "sketch-base");
  const pockets = featureById(document, "pocket-holes");
  const width = profile.params.width, height = profile.params.height;
  const diameter = pockets.params.diameter, offset = pockets.params.offset;
  const errors = [];
  if (![width, height, diameter, offset].every(Number.isFinite)) errors.push("Sketch dimensions must be finite numbers.");
  if (width <= 0 || height <= 0) errors.push("Profile width and height must be greater than zero.");
  if (diameter <= 0) errors.push("Hole diameter must be greater than zero.");
  if (offset <= diameter / 2) errors.push("Hole offset must exceed the hole radius.");
  if (offset + diameter / 2 >= Math.min(width, height) / 2) errors.push("Holes overlap the profile center or cross the outer edge.");
  const constraints = profile.sketch?.constraints || seedDocument.features[0].sketch.constraints;
  const centers = [
    { id: "hole-nw", x: -width / 2 + offset, y: height / 2 - offset },
    { id: "hole-ne", x: width / 2 - offset, y: height / 2 - offset },
    { id: "hole-sw", x: -width / 2 + offset, y: -height / 2 + offset },
    { id: "hole-se", x: width / 2 - offset, y: -height / 2 + offset }
  ];
  return { feature_id: profile.id, plane: profile.sketch?.plane || "XY", profile: profile.sketch?.profile || "centered-rectangle-four-holes", width, height, hole_diameter: diameter, hole_offset: offset, hole_centers: centers, constraint_count: constraints.length, degrees_of_freedom: errors.length ? 1 : 0, fully_constrained: errors.length === 0, errors };
}

function validateProfileSketch(feature) {
  const allEntities = feature.sketch?.entities || [], entities = allEntities.filter((entity) => !entity.construction), errors = [], ids = new Set();
  const endpoint = (entity, start) => {
    const p = entity.params;
    if (entity.kind === "line") return { x: p[start ? "x1" : "x2"], y: p[start ? "y1" : "y2"] };
    if (entity.kind === "arc") { const angle = p[start ? "start_angle" : "end_angle"]; return { x: p.cx + Math.cos(angle) * p.radius, y: p.cy + Math.sin(angle) * p.radius }; }
    return null;
  };
  for (const entity of entities) {
    if (ids.has(entity.id)) errors.push(`duplicate sketch entity id: ${entity.id}`); ids.add(entity.id);
    if (!Object.values(entity.params).every(Number.isFinite)) errors.push(`${entity.id} contains a non-finite coordinate`);
    if (entity.kind === "circle" && !(entity.params.radius > 0)) errors.push(`${entity.id} radius must be positive`);
    if (entity.kind === "line" && Math.hypot(entity.params.x2 - entity.params.x1, entity.params.y2 - entity.params.y1) < 1e-9) errors.push(`${entity.id} is a zero-length line`);
    if (entity.kind === "arc" && (!(entity.params.radius > 0) || entity.params.start_angle === entity.params.end_angle)) errors.push(`${entity.id} is an invalid arc`);
    if (!["line", "circle", "arc"].includes(entity.kind)) errors.push(`${entity.id} has unsupported kind '${entity.kind}'`);
  }
  const loops = new Map(); for (const entity of entities) { const loopId = entity.loop_id || "outer"; if (!loops.has(loopId)) loops.set(loopId, []); loops.get(loopId).push(entity); }
  let closed = entities.length > 0 && !errors.length;
  if (!entities.length) { errors.push("sketch has no profile geometry"); closed = false; }
  if (entities.length && !loops.has("outer")) { errors.push("sketch requires an outer profile loop"); closed = false; }
  for (const [loopId, loop] of [...loops.entries()].sort(([a], [b]) => a.localeCompare(b))) {
    const circles = loop.filter((entity) => entity.kind === "circle");
    let loopClosed = loop.length === 1 && circles.length === 1;
    if (!circles.length && loop.length >= 3) loopClosed = loop.every((entity, index) => { const a = endpoint(entity, false), b = endpoint(loop[(index + 1) % loop.length], true); return a && b && Math.hypot(a.x - b.x, a.y - b.y) <= 0.001; });
    if (!loopClosed) { errors.push(`loop '${loopId}' must be one circle or a connected closed line/arc loop`); closed = false; }
  }
  const loopPolygon = (loop) => {
    if (loop.length === 1 && loop[0].kind === "circle") return Array.from({ length: 64 }, (_, index) => { const angle = index * 2 * Math.PI / 64, p = loop[0].params; return { x: p.cx + Math.cos(angle) * p.radius, y: p.cy + Math.sin(angle) * p.radius }; });
    return loop.flatMap((entity) => {
      if (entity.kind === "line") return [endpoint(entity, true)];
      if (entity.kind !== "arc") return [];
      const p = entity.params, ccw = p.ccw !== 0; let sweep = p.end_angle - p.start_angle;
      if (ccw && sweep < 0) sweep += 2 * Math.PI; if (!ccw && sweep > 0) sweep -= 2 * Math.PI;
      const steps = Math.max(4, Math.ceil(Math.abs(sweep) / (Math.PI / 16)));
      return Array.from({ length: steps }, (_, index) => { const angle = p.start_angle + sweep * index / steps; return { x: p.cx + Math.cos(angle) * p.radius, y: p.cy + Math.sin(angle) * p.radius }; });
    });
  };
  const pointInside = (point, polygon) => {
    if (polygon.length < 3) return false; let inside = false;
    for (let current = 0, previous = polygon.length - 1; current < polygon.length; previous = current++) { const a = polygon[current], b = polygon[previous]; if ((a.y > point.y) !== (b.y > point.y) && point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x) inside = !inside; }
    return inside;
  };
  const cross = (a, b, c) => (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
  const onSegment = (point, a, b, tolerance = 1e-6) => Math.abs(cross(a, b, point)) <= tolerance
    && point.x >= Math.min(a.x, b.x) - tolerance && point.x <= Math.max(a.x, b.x) + tolerance
    && point.y >= Math.min(a.y, b.y) - tolerance && point.y <= Math.max(a.y, b.y) + tolerance;
  const segmentsIntersect = (a, b, c, d) => {
    const abC = cross(a, b, c), abD = cross(a, b, d), cdA = cross(c, d, a), cdB = cross(c, d, b);
    if (((abC > 0 && abD < 0) || (abC < 0 && abD > 0)) && ((cdA > 0 && cdB < 0) || (cdA < 0 && cdB > 0))) return true;
    return (Math.abs(abC) <= 1e-6 && onSegment(c, a, b)) || (Math.abs(abD) <= 1e-6 && onSegment(d, a, b))
      || (Math.abs(cdA) <= 1e-6 && onSegment(a, c, d)) || (Math.abs(cdB) <= 1e-6 && onSegment(b, c, d));
  };
  const polygonsIntersect = (first, second) => first.length >= 2 && second.length >= 2 && first.some((a, firstIndex) => {
    const b = first[(firstIndex + 1) % first.length];
    return second.some((c, secondIndex) => segmentsIntersect(a, b, c, second[(secondIndex + 1) % second.length]));
  });
  const selfIntersects = (polygon) => polygon.length >= 4 && polygon.some((a, first) => {
    const nextFirst = (first + 1) % polygon.length;
    return polygon.some((c, second) => {
      if (second <= first) return false;
      const nextSecond = (second + 1) % polygon.length;
      if (second === nextFirst || nextSecond === first) return false;
      return segmentsIntersect(a, polygon[nextFirst], c, polygon[nextSecond]);
    });
  });
  if (closed) {
    const polygons = new Map([...loops].map(([loopId, loop]) => [loopId, loopPolygon(loop)]));
    for (const loopId of [...loops.keys()].sort()) if (selfIntersects(polygons.get(loopId) || [])) { errors.push(`loop '${loopId}' self-intersects or touches itself away from connected endpoints`); closed = false; }
    const outerPolygon = polygons.get("outer") || [], holeIds = [...loops.keys()].filter((loopId) => loopId !== "outer").sort();
    for (const loopId of holeIds) {
      const holePolygon = polygons.get(loopId) || [];
      if (polygonsIntersect(holePolygon, outerPolygon)) { errors.push(`hole loop '${loopId}' intersects or touches the outer loop`); closed = false; }
      else if (!holePolygon.length || holePolygon.some((point) => !pointInside(point, outerPolygon))) { errors.push(`hole loop '${loopId}' must remain completely inside the outer loop`); closed = false; }
    }
    for (let first = 0; first < holeIds.length; first += 1) for (let second = first + 1; second < holeIds.length; second += 1) {
      const firstPolygon = polygons.get(holeIds[first]) || [], secondPolygon = polygons.get(holeIds[second]) || [];
      if (polygonsIntersect(firstPolygon, secondPolygon) || (firstPolygon[0] && pointInside(firstPolygon[0], secondPolygon)) || (secondPolygon[0] && pointInside(secondPolygon[0], firstPolygon))) {
        errors.push(`hole loops '${holeIds[first]}' and '${holeIds[second]}' intersect, touch, or overlap`); closed = false;
      }
    }
  }
  const constraints = feature.sketch?.constraints || [], constraintIds = new Set(); let removedDegrees = 0;
  for (const constraint of constraints) {
    if (constraintIds.has(constraint.id)) errors.push(`duplicate sketch constraint id: ${constraint.id}`); constraintIds.add(constraint.id);
    const error = profileConstraintError(constraint, allEntities); if (error) errors.push(`${constraint.id}: ${error}`);
    else removedDegrees += ({ coincident: 2, horizontal: 1, vertical: 1, length: 1, radius: 1, parallel: 1, perpendicular: 1, equal: 1, tangent: 1, angle: 1 })[constraint.kind] || 0;
  }
  const unconstrained = allEntities.reduce((total, entity) => total + (({ line: 4, circle: 3, arc: 5 })[entity.kind] || 0), 0);
  return { closed, entity_count: entities.length, constraint_count: constraints.length, degrees_of_freedom: Math.max(0, unconstrained - removedDegrees), errors };
}

function profileEndpoint(reference, entities) {
  const [id, point] = reference.split(":"); const entity = entities.find((candidate) => candidate.id === id); if (!entity) return null;
  const p = entity.params;
  if (point === "center" && ["circle", "arc"].includes(entity.kind)) return { x: p.cx, y: p.cy };
  if (!["start", "end"].includes(point)) return null;
  const start = point === "start";
  if (entity.kind === "line") return { x: p[start ? "x1" : "x2"], y: p[start ? "y1" : "y2"] };
  if (entity.kind === "arc") { const angle = p[start ? "start_angle" : "end_angle"]; return { x: p.cx + Math.cos(angle) * p.radius, y: p.cy + Math.sin(angle) * p.radius }; }
  return null;
}

function profileConstraintError(constraint, entities) {
  const entity = entities.find((candidate) => candidate.id === constraint.entities?.[0]);
  if (["horizontal", "vertical"].includes(constraint.kind)) {
    if (!entity || entity.kind !== "line" || constraint.entities.length !== 1) return "requires one line";
    const delta = constraint.kind === "horizontal" ? Math.abs(entity.params.y2 - entity.params.y1) : Math.abs(entity.params.x2 - entity.params.x1);
    return delta <= 0.001 ? null : `geometry does not satisfy ${constraint.kind}`;
  }
  if (constraint.kind === "length") {
    if (!entity || entity.kind !== "line" || !(constraint.value > 0)) return "requires one line and a positive value";
    return Math.abs(Math.hypot(entity.params.x2 - entity.params.x1, entity.params.y2 - entity.params.y1) - constraint.value) <= 0.001 ? null : "line length does not match the constraint";
  }
  if (constraint.kind === "radius") {
    if (!entity || !["circle", "arc"].includes(entity.kind) || !(constraint.value > 0)) return "requires one circle/arc and a positive value";
    return Math.abs(entity.params.radius - constraint.value) <= 0.001 ? null : "radius does not match the constraint";
  }
  if (constraint.kind === "coincident") {
    if (constraint.entities.length !== 2) return "requires two endpoint references";
    const first = profileEndpoint(constraint.entities[0], entities), second = profileEndpoint(constraint.entities[1], entities);
    return first && second && Math.hypot(first.x - second.x, first.y - second.y) <= 0.001 ? null : "referenced endpoints are not coincident";
  }
  if (["parallel", "perpendicular"].includes(constraint.kind)) {
    if (constraint.entities.length !== 2) return "requires two lines";
    const first = entities.find((candidate) => candidate.id === constraint.entities[0]), second = entities.find((candidate) => candidate.id === constraint.entities[1]);
    if (!first || !second || first.kind !== "line" || second.kind !== "line") return "requires two lines";
    const ax = first.params.x2 - first.params.x1, ay = first.params.y2 - first.params.y1, bx = second.params.x2 - second.params.x1, by = second.params.y2 - second.params.y1;
    const al = Math.hypot(ax, ay), bl = Math.hypot(bx, by); if (al < 1e-6 || bl < 1e-6) return "lines must have nonzero length";
    const error = constraint.kind === "parallel" ? Math.abs(ax / al * by / bl - ay / al * bx / bl) : Math.abs(ax / al * bx / bl + ay / al * by / bl);
    return error <= 0.001 ? null : `lines do not satisfy ${constraint.kind}`;
  }
  if (constraint.kind === "angle") {
    if (constraint.entities.length !== 2 || !(constraint.value > 0 && constraint.value < 180)) return "requires two lines and an angle from 0 to 180 degrees";
    const first = entities.find((candidate) => candidate.id === constraint.entities[0]), second = entities.find((candidate) => candidate.id === constraint.entities[1]);
    if (!first || !second || first.kind !== "line" || second.kind !== "line") return "requires two lines";
    const ax = first.params.x2 - first.params.x1, ay = first.params.y2 - first.params.y1, bx = second.params.x2 - second.params.x1, by = second.params.y2 - second.params.y1;
    const al = Math.hypot(ax, ay), bl = Math.hypot(bx, by); if (al < 1e-6 || bl < 1e-6) return "lines must have nonzero length";
    const measured = Math.acos(Math.max(-1, Math.min(1, (ax * bx + ay * by) / (al * bl)))) * 180 / Math.PI;
    return Math.abs(measured - constraint.value) <= 0.05 ? null : `line angle does not match ${constraint.value} degrees`;
  }
  if (constraint.kind === "equal") {
    if (constraint.entities.length !== 2) return "requires two entities";
    const first = entities.find((candidate) => candidate.id === constraint.entities[0]), second = entities.find((candidate) => candidate.id === constraint.entities[1]);
    if (!first || !second) return "requires two entities";
    if (first.kind === "line" && second.kind === "line") return Math.abs(Math.hypot(first.params.x2 - first.params.x1, first.params.y2 - first.params.y1) - Math.hypot(second.params.x2 - second.params.x1, second.params.y2 - second.params.y1)) <= 0.001 ? null : "line lengths are not equal";
    if (["circle", "arc"].includes(first.kind) && ["circle", "arc"].includes(second.kind)) return Math.abs(first.params.radius - second.params.radius) <= 0.001 ? null : "radii are not equal";
    return "requires two lines or two circles/arcs";
  }
  if (constraint.kind === "tangent") {
    if (constraint.entities.length !== 2) return "requires two entities";
    const first = entities.find((candidate) => candidate.id === constraint.entities[0]), second = entities.find((candidate) => candidate.id === constraint.entities[1]);
    if (!first || !second) return "requires two entities";
    if (first.kind === "line" || second.kind === "line") {
      const line = first.kind === "line" ? first : second, curve = first.kind === "line" ? second : first;
      if (!["circle", "arc"].includes(curve.kind)) return "requires one line and one circle/arc";
      const dx = line.params.x2 - line.params.x1, dy = line.params.y2 - line.params.y1, length = Math.hypot(dx, dy);
      if (length < 1e-6) return "line must have nonzero length";
      const distance = Math.abs(dx * (line.params.y1 - curve.params.cy) - (line.params.x1 - curve.params.cx) * dy) / length;
      return Math.abs(distance - curve.params.radius) <= 0.001 ? null : "line and curve are not tangent";
    }
    if (["circle", "arc"].includes(first.kind) && ["circle", "arc"].includes(second.kind)) return Math.abs(Math.hypot(first.params.cx - second.params.cx, first.params.cy - second.params.cy) - first.params.radius - second.params.radius) <= 0.001 ? null : "curves are not externally tangent";
    return "requires a line and circle/arc, or two circles/arcs";
  }
  return `unsupported constraint kind '${constraint.kind}'`;
}

function enforceProfileConstraint(constraint, entities) {
  const result = structuredClone(entities), entity = result.find((candidate) => candidate.id === constraint.entities?.[0]);
  if (["horizontal", "vertical"].includes(constraint.kind)) {
    if (!entity || entity.kind !== "line" || constraint.entities.length !== 1) throw new Error("invalid_constraint: horizontal/vertical requires one line");
    if (constraint.kind === "horizontal") entity.params.y2 = entity.params.y1; else entity.params.x2 = entity.params.x1;
  } else if (constraint.kind === "length") {
    if (!entity || entity.kind !== "line" || !(constraint.value > 0)) throw new Error("invalid_constraint: length requires one line and a positive value");
    const dx = entity.params.x2 - entity.params.x1, dy = entity.params.y2 - entity.params.y1, current = Math.hypot(dx, dy); if (current < 1e-6) throw new Error("invalid_constraint: line has zero length");
    entity.params.x2 = entity.params.x1 + dx / current * constraint.value; entity.params.y2 = entity.params.y1 + dy / current * constraint.value;
  } else if (constraint.kind === "radius") {
    if (!entity || !["circle", "arc"].includes(entity.kind) || !(constraint.value > 0)) throw new Error("invalid_constraint: radius requires one circle/arc and a positive value");
    entity.params.radius = constraint.value;
  } else if (constraint.kind === "coincident") {
    if (constraint.entities.length !== 2) throw new Error("invalid_constraint: coincident requires two endpoint references");
    const target = profileEndpoint(constraint.entities[0], result), [id, point] = constraint.entities[1].split(":"), moving = result.find((candidate) => candidate.id === id);
    if (!target || !moving || moving.kind !== "line" || !["start", "end"].includes(point)) throw new Error("invalid_constraint: the second coincident reference must be a line endpoint");
    const suffix = point === "start" ? "1" : "2"; moving.params[`x${suffix}`] = target.x; moving.params[`y${suffix}`] = target.y;
  } else if (["parallel", "perpendicular"].includes(constraint.kind)) {
    if (constraint.entities.length !== 2) throw new Error(`invalid_constraint: ${constraint.kind} requires two lines`);
    const reference = result.find((candidate) => candidate.id === constraint.entities[0]), moving = result.find((candidate) => candidate.id === constraint.entities[1]);
    if (!reference || !moving || reference.kind !== "line" || moving.kind !== "line") throw new Error(`invalid_constraint: ${constraint.kind} requires two lines`);
    let dx = reference.params.x2 - reference.params.x1, dy = reference.params.y2 - reference.params.y1; const referenceLength = Math.hypot(dx, dy), movingLength = Math.hypot(moving.params.x2 - moving.params.x1, moving.params.y2 - moving.params.y1);
    if (referenceLength < 1e-6 || movingLength < 1e-6) throw new Error("invalid_constraint: lines must have nonzero length");
    dx /= referenceLength; dy /= referenceLength; if (constraint.kind === "perpendicular") [dx, dy] = [-dy, dx];
    moving.params.x2 = moving.params.x1 + dx * movingLength; moving.params.y2 = moving.params.y1 + dy * movingLength;
  } else if (constraint.kind === "angle") {
    if (constraint.entities.length !== 2 || !(constraint.value > 0 && constraint.value < 180)) throw new Error("invalid_constraint: angle requires two lines and degrees from 0 to 180");
    const reference = result.find((candidate) => candidate.id === constraint.entities[0]), moving = result.find((candidate) => candidate.id === constraint.entities[1]);
    if (!reference || !moving || reference.kind !== "line" || moving.kind !== "line") throw new Error("invalid_constraint: angle requires two lines");
    let dx = reference.params.x2 - reference.params.x1, dy = reference.params.y2 - reference.params.y1;
    const referenceLength = Math.hypot(dx, dy), movingDx = moving.params.x2 - moving.params.x1, movingDy = moving.params.y2 - moving.params.y1, movingLength = Math.hypot(movingDx, movingDy);
    if (referenceLength < 1e-6 || movingLength < 1e-6) throw new Error("invalid_constraint: lines must have nonzero length");
    const sign = dx * movingDy - dy * movingDx < 0 ? -1 : 1, radians = sign * constraint.value * Math.PI / 180;
    dx /= referenceLength; dy /= referenceLength;
    const rotatedX = Math.cos(radians) * dx - Math.sin(radians) * dy, rotatedY = Math.sin(radians) * dx + Math.cos(radians) * dy;
    moving.params.x2 = moving.params.x1 + rotatedX * movingLength; moving.params.y2 = moving.params.y1 + rotatedY * movingLength;
  } else if (constraint.kind === "equal") {
    if (constraint.entities.length !== 2) throw new Error("invalid_constraint: equal requires two entities");
    const reference = result.find((candidate) => candidate.id === constraint.entities[0]), moving = result.find((candidate) => candidate.id === constraint.entities[1]);
    if (!reference || !moving) throw new Error("invalid_constraint: equal references missing entities");
    if (reference.kind === "line" && moving.kind === "line") {
      const targetLength = Math.hypot(reference.params.x2 - reference.params.x1, reference.params.y2 - reference.params.y1), dx = moving.params.x2 - moving.params.x1, dy = moving.params.y2 - moving.params.y1, length = Math.hypot(dx, dy);
      if (targetLength < 1e-6 || length < 1e-6) throw new Error("invalid_constraint: lines must have nonzero length");
      moving.params.x2 = moving.params.x1 + dx / length * targetLength; moving.params.y2 = moving.params.y1 + dy / length * targetLength;
    } else if (["circle", "arc"].includes(reference.kind) && ["circle", "arc"].includes(moving.kind)) moving.params.radius = reference.params.radius;
    else throw new Error("invalid_constraint: equal requires two lines or two circles/arcs");
  } else if (constraint.kind === "tangent") {
    if (constraint.entities.length !== 2) throw new Error("invalid_constraint: tangent requires two entities");
    const firstIndex = result.findIndex((candidate) => candidate.id === constraint.entities[0]), secondIndex = result.findIndex((candidate) => candidate.id === constraint.entities[1]);
    if (firstIndex < 0 || secondIndex < 0) throw new Error("invalid_constraint: tangent references missing entities");
    const first = result[firstIndex], second = result[secondIndex];
    if (first.kind === "line" || second.kind === "line") {
      const line = first.kind === "line" ? first : second, curve = first.kind === "line" ? second : first;
      if (!["circle", "arc"].includes(curve.kind)) throw new Error("invalid_constraint: tangent requires one line and one circle/arc");
      const dx = line.params.x2 - line.params.x1, dy = line.params.y2 - line.params.y1, length = Math.hypot(dx, dy);
      if (length < 1e-6 || !(curve.params.radius > 0)) throw new Error("invalid_constraint: tangent entities must be nondegenerate");
      const ux = dx / length, uy = dy / length, nx = -uy, ny = ux, rx = curve.params.cx - line.params.x1, ry = curve.params.cy - line.params.y1;
      const projection = rx * ux + ry * uy, side = rx * nx + ry * ny < 0 ? -1 : 1;
      curve.params.cx = line.params.x1 + ux * projection + nx * curve.params.radius * side;
      curve.params.cy = line.params.y1 + uy * projection + ny * curve.params.radius * side;
    } else if (["circle", "arc"].includes(first.kind) && ["circle", "arc"].includes(second.kind)) {
      const dx = second.params.cx - first.params.cx, dy = second.params.cy - first.params.cy, distance = Math.hypot(dx, dy), target = first.params.radius + second.params.radius;
      if (distance < 1e-6 || !(target > 0)) throw new Error("invalid_constraint: tangent curves must be nondegenerate");
      second.params.cx = first.params.cx + dx / distance * target; second.params.cy = first.params.cy + dy / distance * target;
    } else throw new Error("invalid_constraint: tangent requires a line and circle/arc, or two circles/arcs");
  } else throw new Error(`invalid_constraint: unsupported kind '${constraint.kind}'`);
  const error = profileConstraintError(constraint, result); if (error) throw new Error(`constraint_unsatisfied: ${error}`);
  return result;
}

function solveProfileConstraints(constraints, entities) {
  if (!constraints.length) return structuredClone(entities);
  let result = structuredClone(entities);
  const maximumPasses = Math.min(128, Math.max(16, constraints.length * 2));
  for (let iteration = 0; iteration < maximumPasses; iteration += 1) {
    for (const constraint of [...constraints, ...constraints.slice().reverse()]) {
      try { result = enforceProfileConstraint(constraint, result); }
      catch { throw new Error(`constraint_conflict: '${constraint.id}' is invalid or degenerate; no geometry was changed`); }
    }
    if (constraints.every((constraint) => profileConstraintError(constraint, result) === null)) return result;
  }
  const unsatisfied = constraints.flatMap((constraint) => {
    const error = profileConstraintError(constraint, result);
    return error ? [`'${constraint.id}' (${error})`] : [];
  });
  throw new Error(`constraint_conflict: ${unsatisfied.slice(0, 3).join(", ")}; no geometry was changed`);
}

function trimOrExtendProfileLine(entities, lineId, referenceLineId, endpointName, mode) {
  const result = structuredClone(entities), line = result.find((entity) => entity.id === lineId), reference = result.find((entity) => entity.id === referenceLineId);
  if (!line || !reference || line.id === reference.id || line.kind !== "line" || reference.kind !== "line") throw new Error("invalid_reference: trim/extend requires two different sketch lines");
  const dx = line.params.x2 - line.params.x1, dy = line.params.y2 - line.params.y1, rx = reference.params.x2 - reference.params.x1, ry = reference.params.y2 - reference.params.y1;
  const denominator = dx * ry - dy * rx; if (Math.abs(denominator) < 1e-6) throw new Error("invalid_geometry: trim/extend lines are parallel");
  const qx = reference.params.x1 - line.params.x1, qy = reference.params.y1 - line.params.y1;
  const t = (qx * ry - qy * rx) / denominator, u = (qx * dy - qy * dx) / denominator;
  if (u < -1e-6 || u > 1.000001) throw new Error("invalid_geometry: intersection is outside the reference segment");
  if (mode === "trim" && !(t > 1e-6 && t < 0.999999)) throw new Error("invalid_geometry: trim requires the reference to cross the selected line");
  if (mode === "extend" && ((endpointName === "start" && !(t < -1e-6)) || (endpointName === "end" && !(t > 1.000001)))) throw new Error("invalid_geometry: choose the endpoint facing the extension intersection");
  const suffix = endpointName === "start" ? "1" : "2";
  line.params[`x${suffix}`] = line.params.x1 + dx * t; line.params[`y${suffix}`] = line.params.y1 + dy * t;
  if (Math.hypot(line.params.x2 - line.params.x1, line.params.y2 - line.params.y1) < 1e-6) throw new Error("invalid_geometry: operation creates a zero-length line");
  return result;
}

function rotatedHalfExtents(half, params) {
  const rx = (params.rotation_x || 0) * Math.PI / 180, ry = (params.rotation_y || 0) * Math.PI / 180, rz = (params.rotation_z || 0) * Math.PI / 180;
  let maximum = { x: 0, y: 0, z: 0 };
  for (const sx of [-1, 1]) for (const sy of [-1, 1]) for (const sz of [-1, 1]) {
    let x = half.x * sx, y = half.y * sy, z = half.z * sz;
    [y, z] = [y * Math.cos(rx) - z * Math.sin(rx), y * Math.sin(rx) + z * Math.cos(rx)];
    [x, z] = [x * Math.cos(ry) + z * Math.sin(ry), -x * Math.sin(ry) + z * Math.cos(ry)];
    [x, y] = [x * Math.cos(rz) - y * Math.sin(rz), x * Math.sin(rz) + y * Math.cos(rz)];
    maximum = { x: Math.max(maximum.x, Math.abs(x)), y: Math.max(maximum.y, Math.abs(y)), z: Math.max(maximum.z, Math.abs(z)) };
  }
  return maximum;
}

function measureDocument(document) {
  const profile = featureById(document, "sketch-base");
  const pad = featureById(document, "pad-base");
  const pockets = featureById(document, "pocket-holes");
  const width = profile.params.width, height = profile.params.height, depth = pad.params.length;
  const radius = pockets.params.diameter / 2;
  const baseVisible = profile.visible !== false && pad.visible !== false;
  let minimum = baseVisible ? { x: -width / 2, y: -height / 2, z: -depth / 2 } : { x: Infinity, y: Infinity, z: Infinity };
  let maximum = baseVisible ? { x: width / 2, y: height / 2, z: depth / 2 } : { x: -Infinity, y: -Infinity, z: -Infinity };
  let estimatedVolume = baseVisible ? width * height * depth - (pockets.visible === false ? 0 : 4 * Math.PI * radius * radius * depth) : 0;
  let estimatedSurfaceArea = baseVisible ? (pockets.visible === false
    ? 2 * width * height + 2 * (width + height) * depth
    : 2 * (width * height - 4 * Math.PI * radius * radius) + 2 * (width + height) * depth + 8 * Math.PI * radius * depth) : 0;
  for (const feature of document.features.filter((candidate) => candidate.visible)) {
    const x = feature.params.x || 0, y = feature.params.y || 0, z = feature.params.z || 0;
    const expand = (half) => {
      const extent = rotatedHalfExtents(half, feature.params);
      minimum = { x: Math.min(minimum.x, x - extent.x), y: Math.min(minimum.y, y - extent.y), z: Math.min(minimum.z, z - extent.z) };
      maximum = { x: Math.max(maximum.x, x + extent.x), y: Math.max(maximum.y, y + extent.y), z: Math.max(maximum.z, z + extent.z) };
    };
    if (feature.kind === "box") {
      const w = feature.params.width, h = feature.params.height, d = feature.params.depth;
      expand({ x: w / 2, y: h / 2, z: d / 2 });
      estimatedVolume += w * h * d; estimatedSurfaceArea += 2 * (w * h + w * d + h * d);
    } else if (feature.kind === "cylinder") {
      const r = feature.params.radius, h = feature.params.height;
      expand({ x: r, y: r, z: h / 2 });
      estimatedVolume += Math.PI * r * r * h; estimatedSurfaceArea += 2 * Math.PI * r * (r + h);
    } else if (feature.kind === "cone") {
      const r1 = feature.params.radius_bottom, r2 = feature.params.radius_top, h = feature.params.height, r = Math.max(r1, r2);
      expand({ x: r, y: r, z: h / 2 });
      estimatedVolume += Math.PI * h * (r1 * r1 + r1 * r2 + r2 * r2) / 3;
      estimatedSurfaceArea += Math.PI * (r1 + r2) * Math.hypot(r1 - r2, h) + Math.PI * (r1 * r1 + r2 * r2);
    } else if (feature.kind === "sphere") {
      const r = feature.params.radius;
      expand({ x: r, y: r, z: r });
      estimatedVolume += 4 * Math.PI * r * r * r / 3; estimatedSurfaceArea += 4 * Math.PI * r * r;
    } else if (feature.kind === "torus") {
      const major = feature.params.major_radius, tube = feature.params.tube_radius, outer = major + tube;
      expand({ x: outer, y: outer, z: tube });
      estimatedVolume += 2 * Math.PI * Math.PI * major * tube * tube; estimatedSurfaceArea += 4 * Math.PI * Math.PI * major * tube;
    }
  }
  if (!Number.isFinite(minimum.x)) minimum = maximum = { x: 0, y: 0, z: 0 };
  return {
    revision: document.revision, units: document.units, backend: document.backend,
    bounds: { minimum, maximum, size: { x: maximum.x - minimum.x, y: maximum.y - minimum.y, z: maximum.z - minimum.z } },
    estimated_volume: estimatedVolume, estimated_surface_area: estimatedSurfaceArea,
    exact_mass_properties: false,
    warning: "Mesh/primitive estimate; overlapping bodies are counted separately and exact BRep mass properties require a full kernel adapter."
  };
}

async function measureDocumentWithKernel(document, signal) {
  const measurement = measureDocument(document);
  let hasBounds = measurement.estimated_volume > 0 || measurement.estimated_surface_area > 0;
  const derived = document.features.filter((feature) => feature.visible && kernelDerivedKinds.has(feature.kind));
  const kernelWarnings = [];
  for (const feature of derived) {
    const validation = await validateWithKernel(document, feature.id, signal);
    const min = validation.bounds.minimum, max = validation.bounds.maximum;
    if (!hasBounds) { measurement.bounds.minimum = { ...min }; measurement.bounds.maximum = { ...max }; hasBounds = true; }
    else {
      measurement.bounds.minimum = { x: Math.min(measurement.bounds.minimum.x, min.x), y: Math.min(measurement.bounds.minimum.y, min.y), z: Math.min(measurement.bounds.minimum.z, min.z) };
      measurement.bounds.maximum = { x: Math.max(measurement.bounds.maximum.x, max.x), y: Math.max(measurement.bounds.maximum.y, max.y), z: Math.max(measurement.bounds.maximum.z, max.z) };
    }
    measurement.estimated_volume += validation.volume; measurement.estimated_surface_area += validation.surface_area;
    kernelWarnings.push(...validation.warnings.map((warning) => `${feature.id}: ${warning}`));
  }
  const min = measurement.bounds.minimum, max = measurement.bounds.maximum;
  measurement.bounds.size = { x: max.x - min.x, y: max.y - min.y, z: max.z - min.z };
  if (derived.length) measurement.warning = `Includes kernel-derived properties for ${derived.length} derived feature(s). Separate visible bodies may overlap. ${kernelWarnings.join(" ")}`.trim();
  return measurement;
}

function drawingSheet(document) {
  const profile = featureById(document, "sketch-base"), pad = featureById(document, "pad-base"), pockets = featureById(document, "pocket-holes");
  const width = profile.params.width, height = profile.params.height, depth = pad.params.length;
  const radius = pockets.params.diameter / 2, offset = pockets.params.offset;
  const front = [{ type: "rectangle", x: -width / 2, y: -height / 2, width, height }];
  if (pockets.visible !== false) for (const x of [-width / 2 + offset, width / 2 - offset]) for (const y of [-height / 2 + offset, height / 2 - offset]) front.push({ type: "circle", x, y, radius });
  const top = [{ type: "rectangle", x: -width / 2, y: -depth / 2, width, height: depth }];
  const right = [{ type: "rectangle", x: -height / 2, y: -depth / 2, width: height, height: depth }];
  for (const feature of document.features.filter((candidate) => candidate.visible)) {
    const x = feature.params.x || 0, y = feature.params.y || 0, z = feature.params.z || 0;
    if (feature.kind === "box") {
      const w = feature.params.width, h = feature.params.height, d = feature.params.depth;
      front.push({ type: "rectangle", x: x - w / 2, y: y - h / 2, width: w, height: h });
      top.push({ type: "rectangle", x: x - w / 2, y: z - d / 2, width: w, height: d });
      right.push({ type: "rectangle", x: y - h / 2, y: z - d / 2, width: h, height: d });
    } else if (feature.kind === "cylinder") {
      const r = feature.params.radius, h = feature.params.height;
      front.push({ type: "circle", x, y, radius: r });
      top.push({ type: "rectangle", x: x - r, y: z - h / 2, width: r * 2, height: h });
      right.push({ type: "rectangle", x: y - r, y: z - h / 2, width: r * 2, height: h });
    } else if (feature.kind === "cone") {
      const r = Math.max(feature.params.radius_bottom, feature.params.radius_top), h = feature.params.height;
      front.push({ type: "circle", x, y, radius: r });
      top.push({ type: "rectangle", x: x - r, y: z - h / 2, width: r * 2, height: h });
      right.push({ type: "rectangle", x: y - r, y: z - h / 2, width: r * 2, height: h });
    } else if (feature.kind === "sphere") {
      const r = feature.params.radius;
      front.push({ type: "circle", x, y, radius: r }); top.push({ type: "circle", x, y: z, radius: r }); right.push({ type: "circle", x: y, y: z, radius: r });
    } else if (feature.kind === "torus") {
      const outer = feature.params.major_radius + feature.params.tube_radius, tube = feature.params.tube_radius;
      front.push({ type: "circle", x, y, radius: outer });
      top.push({ type: "rectangle", x: x - outer, y: z - tube, width: outer * 2, height: tube * 2 });
      right.push({ type: "rectangle", x: y - outer, y: z - tube, width: outer * 2, height: tube * 2 });
    }
  }
  return { document_name: document.name, document_id: document.id, revision: document.revision, units: document.units, sheet: "A4 landscape", projections: [
    { id: "front", title: "FRONT", width, height, outlines: front },
    { id: "top", title: "TOP", width, height: Math.max(depth, 24), outlines: top },
    { id: "right", title: "RIGHT", width: height, height: Math.max(depth, 24), outlines: right }
  ] };
}

function drawingPdfBytes(sheet) {
  const commands = ["1 1 1 rg 0 0 842 595 re f", "0.05 0.16 0.22 RG 0.8 w"];
  const text = (value, x, y, size = 8) => commands.push(`BT /F1 ${size} Tf ${x} ${y} Td (${String(value).replace(/[\\()]/g, "\\$&")}) Tj ET`);
  const viewRects = [[38, 235, 490, 315], [38, 70, 490, 130], [560, 235, 240, 315]];
  for (let viewIndex = 0; viewIndex < sheet.projections.length; viewIndex += 1) {
    const projection = sheet.projections[viewIndex], [rx, ry, rw, rh] = viewRects[viewIndex];
    commands.push(`0.78 G ${rx} ${ry} ${rw} ${rh} re S`, "0.05 0.28 0.43 RG 1.1 w"); text(projection.title, rx + 6, ry + rh - 16, 8);
    const scale = Math.min((rw - 44) / Math.max(projection.width, 1), (rh - 54) / Math.max(projection.height, 1));
    const cx = rx + rw / 2, cy = ry + rh / 2 - 4;
    for (const outline of projection.outlines) {
      if (outline.type === "rectangle") commands.push(`${cx + outline.x * scale} ${cy + outline.y * scale} ${outline.width * scale} ${outline.height * scale} re S`);
      else {
        const k = 0.5522847498, r = outline.radius * scale, x = cx + outline.x * scale, y = cy + outline.y * scale;
        commands.push(`${x + r} ${y} m ${x + r} ${y + k * r} ${x + k * r} ${y + r} ${x} ${y + r} c ${x - k * r} ${y + r} ${x - r} ${y + k * r} ${x - r} ${y} c ${x - r} ${y - k * r} ${x - k * r} ${y - r} ${x} ${y - r} c ${x + k * r} ${y - r} ${x + r} ${y - k * r} ${x + r} ${y} c S`);
      }
    }
    text(`${projection.width} ${sheet.units}`, cx - 16, ry + 20, 7);
  }
  commands.push("0.18 G 540 35 262 145 re S");
  text("AXIS CAD STUDIO", 550, 156, 9); text(sheet.document_name, 550, 90, 15); text(`REV ${sheet.revision}  UNITS ${sheet.units.toUpperCase()}  SHEET 1 / 1`, 550, 48, 7);
  const stream = `${commands.join("\n")}\n`;
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 842 595] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
    `<< /Length ${Buffer.byteLength(stream)} >>\nstream\n${stream}endstream`,
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
  ];
  let pdf = "%PDF-1.4\n", offsets = [0];
  objects.forEach((object, index) => { offsets.push(Buffer.byteLength(pdf)); pdf += `${index + 1} 0 obj\n${object}\nendobj\n`; });
  const xref = Buffer.byteLength(pdf); pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (let index = 1; index <= objects.length; index += 1) pdf += `${String(offsets[index]).padStart(10, "0")} 00000 n \n`;
  pdf += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(pdf, "utf8");
}

function drawingDxfBytes(sheet) {
  const lines = ["0", "SECTION", "2", "HEADER", "9", "$INSUNITS", "70", "4", "0", "ENDSEC", "0", "SECTION", "2", "ENTITIES"];
  const offsets = [[0, 0], [0, -100], [140, 0]];
  const line = (x1, y1, x2, y2, layer) => lines.push("0", "LINE", "8", layer, "10", x1.toFixed(6), "20", y1.toFixed(6), "30", "0", "11", x2.toFixed(6), "21", y2.toFixed(6), "31", "0");
  sheet.projections.forEach((projection, index) => {
    const [ox, oy] = offsets[index];
    projection.outlines.forEach((outline) => {
      if (outline.type === "rectangle") {
        const x = outline.x + ox, y = outline.y + oy, x2 = x + outline.width, y2 = y + outline.height;
        line(x, y, x2, y, projection.title); line(x2, y, x2, y2, projection.title); line(x2, y2, x, y2, projection.title); line(x, y2, x, y, projection.title);
      } else lines.push("0", "CIRCLE", "8", projection.title, "10", (outline.x + ox).toFixed(6), "20", (outline.y + oy).toFixed(6), "30", "0", "40", outline.radius.toFixed(6));
    });
  });
  lines.push("0", "ENDSEC", "0", "EOF");
  return Buffer.from(`${lines.join("\n")}\n`, "utf8");
}

async function ensureDocument() {
  await mkdir(dataRoot, { recursive: true });
  try {
    await readFile(documentPath, "utf8");
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    await writeFile(documentPath, `${JSON.stringify(seedDocument, null, 2)}\n`, "utf8");
  }
}

async function loadDocument() {
  await ensureDocument();
  const document = JSON.parse(await readFile(documentPath, "utf8"));
  for (const feature of document.features) if (["body_transform", "assembly_instance"].includes(feature.kind)) {
    feature.params.scale_x ??= 1; feature.params.scale_y ??= 1; feature.params.scale_z ??= 1;
  }
  solveAssemblyMates(document);
  return document;
}

async function saveDocument(document) {
  solveAssemblyMates(document);
  const temporaryPath = `${documentPath}.${process.pid}.tmp`;
  await writeFile(temporaryPath, `${JSON.stringify(document, null, 2)}\n`, "utf8");
  await rename(temporaryPath, documentPath);
}

async function loadSourcingCandidates() {
  await mkdir(dataRoot, { recursive: true });
  try {
    const parsed = JSON.parse(await readFile(sourcingPath, "utf8"));
    return Array.isArray(parsed.candidates) ? parsed.candidates : [];
  } catch (error) {
    if (error?.code === "ENOENT") return [];
    throw error;
  }
}

async function saveSourcingCandidates(candidates) {
  await mkdir(dataRoot, { recursive: true });
  const temporaryPath = `${sourcingPath}.${process.pid}.tmp`;
  await writeFile(temporaryPath, `${JSON.stringify({ schema: "axis-cad.sourcing.v1", candidates }, null, 2)}\n`, "utf8");
  await rename(temporaryPath, sourcingPath);
}

function assemblyRotatedOffset(instance, prefix, params) {
  let x = (params[`${prefix}_x`] ?? 0) * (instance.params.scale_x ?? 1);
  let y = (params[`${prefix}_y`] ?? 0) * (instance.params.scale_y ?? 1);
  let z = (params[`${prefix}_z`] ?? 0) * (instance.params.scale_z ?? 1);
  const rx = (instance.params.rotation_x ?? 0) * Math.PI / 180, ry = (instance.params.rotation_y ?? 0) * Math.PI / 180, rz = (instance.params.rotation_z ?? 0) * Math.PI / 180;
  [y, z] = [y * Math.cos(rx) - z * Math.sin(rx), y * Math.sin(rx) + z * Math.cos(rx)];
  [x, z] = [x * Math.cos(ry) + z * Math.sin(ry), -x * Math.sin(ry) + z * Math.cos(ry)];
  [x, y] = [x * Math.cos(rz) - y * Math.sin(rz), x * Math.sin(rz) + y * Math.cos(rz)];
  return { x, y, z };
}

function quaternionMultiply(a, b) {
  return { w: a.w*b.w-a.x*b.x-a.y*b.y-a.z*b.z, x: a.w*b.x+a.x*b.w+a.y*b.z-a.z*b.y, y: a.w*b.y-a.x*b.z+a.y*b.w+a.z*b.x, z: a.w*b.z+a.x*b.y-a.y*b.x+a.z*b.w };
}

function assemblyQuaternion(instance) {
  const rx=(instance.params.rotation_x??0)*Math.PI/360, ry=(instance.params.rotation_y??0)*Math.PI/360, rz=(instance.params.rotation_z??0)*Math.PI/360;
  return quaternionMultiply(quaternionMultiply({w:Math.cos(rz),x:0,y:0,z:Math.sin(rz)},{w:Math.cos(ry),x:0,y:Math.sin(ry),z:0}),{w:Math.cos(rx),x:Math.sin(rx),y:0,z:0});
}

function quaternionRotate(q, v) {
  const p=quaternionMultiply(quaternionMultiply(q,{w:0,...v}),{w:q.w,x:-q.x,y:-q.y,z:-q.z}); return {x:p.x,y:p.y,z:p.z};
}

function quaternionFromTo(from, to) {
  const fl=Math.hypot(from.x,from.y,from.z), tl=Math.hypot(to.x,to.y,to.z), a={x:from.x/fl,y:from.y/fl,z:from.z/fl}, b={x:to.x/tl,y:to.y/tl,z:to.z/tl};
  const dot=Math.max(-1,Math.min(1,a.x*b.x+a.y*b.y+a.z*b.z));
  if (dot>0.999999) return {w:1,x:0,y:0,z:0};
  if (dot < -0.999999) { const basis=Math.abs(a.x)<0.8?{x:1,y:0,z:0}:{x:0,y:1,z:0}, cross={x:a.y*basis.z-a.z*basis.y,y:a.z*basis.x-a.x*basis.z,z:a.x*basis.y-a.y*basis.x}, l=Math.hypot(cross.x,cross.y,cross.z); return {w:0,x:cross.x/l,y:cross.y/l,z:cross.z/l}; }
  const cross={x:a.y*b.z-a.z*b.y,y:a.z*b.x-a.x*b.z,z:a.x*b.y-a.y*b.x}, s=Math.sqrt((1+dot)*2); return {w:s/2,x:cross.x/s,y:cross.y/s,z:cross.z/s};
}

function quaternionAxisAngle(axis, degrees) { const half=degrees*Math.PI/360, length=Math.hypot(axis.x,axis.y,axis.z); return {w:Math.cos(half),x:axis.x/length*Math.sin(half),y:axis.y/length*Math.sin(half),z:axis.z/length*Math.sin(half)}; }

function setAssemblyEuler(instance, q) {
  const sinp=2*(q.w*q.y-q.z*q.x), ry=Math.asin(Math.max(-1,Math.min(1,sinp)));
  const rx=Math.atan2(2*(q.w*q.x+q.y*q.z),1-2*(q.x*q.x+q.y*q.y));
  const rz=Math.atan2(2*(q.w*q.z+q.x*q.y),1-2*(q.y*q.y+q.z*q.z));
  instance.params.rotation_x=rx*180/Math.PI; instance.params.rotation_y=ry*180/Math.PI; instance.params.rotation_z=rz*180/Math.PI;
}

function solveAssemblyMates(document) {
  const instances = document.features.filter((feature) => feature.kind === "assembly_instance");
  for (const instance of instances) instance.params.fixed = 0;
  const mates = document.features.filter((feature) => feature.kind === "assembly_mate");
  for (const mate of mates) if (mate.params.mate_type === 0) {
    const instance = document.features.find((feature) => feature.id === mate.input_feature_ids?.[0] && feature.kind === "assembly_instance");
    if (instance) instance.params.fixed = 1;
  }
  for (let pass = 0; pass < Math.max(1, mates.length); pass += 1) {
    for (const mate of mates) {
      if (![1, 2, 3, 4, 5].includes(mate.params.mate_type) || mate.input_feature_ids?.length !== 2) continue;
      const reference = document.features.find((feature) => feature.id === mate.input_feature_ids[0] && feature.kind === "assembly_instance");
      const moving = document.features.find((feature) => feature.id === mate.input_feature_ids[1] && feature.kind === "assembly_instance");
      if (!reference || !moving) continue;
      if (mate.params.mate_type === 5) {
        const referenceQ=assemblyQuaternion(reference), referenceDirection=quaternionRotate(referenceQ,{x:mate.params.reference_normal_x,y:mate.params.reference_normal_y,z:mate.params.reference_normal_z}), hinge=quaternionRotate(referenceQ,{x:mate.params.hinge_axis_x,y:mate.params.hinge_axis_y,z:mate.params.hinge_axis_z});
        const rl=Math.hypot(referenceDirection.x,referenceDirection.y,referenceDirection.z), hl=Math.hypot(hinge.x,hinge.y,hinge.z); if(rl<1e-6||hl<1e-6) continue;
        const referenceUnit={x:referenceDirection.x/rl,y:referenceDirection.y/rl,z:referenceDirection.z/rl}, hingeUnit={x:hinge.x/hl,y:hinge.y/hl,z:hinge.z/hl};
        const target=quaternionRotate(quaternionAxisAngle(hingeUnit,mate.params.angle),referenceUnit), local={x:mate.params.moving_normal_x,y:mate.params.moving_normal_y,z:mate.params.moving_normal_z};
        if(Math.hypot(local.x,local.y,local.z)<1e-6) continue;
        setAssemblyEuler(moving,quaternionMultiply(quaternionAxisAngle(target,mate.params.spin),quaternionFromTo(local,target))); continue;
      }
      const referenceOffset = assemblyRotatedOffset(reference, "reference_anchor", mate.params);
      let planeNormal = null;
      if ([3, 4].includes(mate.params.mate_type)) {
        const referenceQ=assemblyQuaternion(reference);
        const prefix=mate.params.mate_type===4?"axis":"normal";
        planeNormal=quaternionRotate(referenceQ,{x:mate.params[`reference_${prefix}_x`],y:mate.params[`reference_${prefix}_y`],z:mate.params[`reference_${prefix}_z`]});
        const nl=Math.hypot(planeNormal.x,planeNormal.y,planeNormal.z), localLength=Math.hypot(mate.params[`moving_${prefix}_x`],mate.params[`moving_${prefix}_y`],mate.params[`moving_${prefix}_z`]); if (nl<1e-6||localLength<1e-6) continue;
        const sign=mate.params.opposed===1?-1:1; planeNormal={x:sign*planeNormal.x/nl,y:sign*planeNormal.y/nl,z:sign*planeNormal.z/nl};
        const local={x:mate.params[`moving_${prefix}_x`],y:mate.params[`moving_${prefix}_y`],z:mate.params[`moving_${prefix}_z`]};
        setAssemblyEuler(moving,quaternionMultiply(quaternionAxisAngle(planeNormal,mate.params.spin),quaternionFromTo(local,planeNormal)));
      }
      const movingOffset = assemblyRotatedOffset(moving, "moving_anchor", mate.params);
      const displacement = mate.params.mate_type === 4 ? {x:planeNormal.x*mate.params.axial_offset,y:planeNormal.y*mate.params.axial_offset,z:planeNormal.z*mate.params.axial_offset} : mate.params.mate_type === 3 ? {x:planeNormal.x*mate.params.distance,y:planeNormal.y*mate.params.distance,z:planeNormal.z*mate.params.distance} : mate.params.mate_type === 2
        ? (() => { const length = Math.hypot(mate.params.axis_x, mate.params.axis_y, mate.params.axis_z); return length < 1e-6 ? { x: 0, y: 0, z: 0 } : { x: mate.params.axis_x * mate.params.distance / length, y: mate.params.axis_y * mate.params.distance / length, z: mate.params.axis_z * mate.params.distance / length }; })()
        : { x: mate.params.offset_x ?? 0, y: mate.params.offset_y ?? 0, z: mate.params.offset_z ?? 0 };
      moving.params.x = (reference.params.x ?? 0) + referenceOffset.x + displacement.x - movingOffset.x;
      moving.params.y = (reference.params.y ?? 0) + referenceOffset.y + displacement.y - movingOffset.y;
      moving.params.z = (reference.params.z ?? 0) + referenceOffset.z + displacement.z - movingOffset.z;
    }
  }
}

function assemblyPositionMateDriving(document, instanceId) { return document.features.find((feature) => feature.kind === "assembly_mate" && [1, 2, 3, 4].includes(feature.params.mate_type) && feature.input_feature_ids?.[1] === instanceId); }
function assemblyOrientationMateDriving(document, instanceId) { return document.features.find((feature) => feature.kind === "assembly_mate" && [3, 4, 5].includes(feature.params.mate_type) && feature.input_feature_ids?.[1] === instanceId); }
function assemblyMatesDriving(document, instanceId) { return document.features.filter((feature) => feature.kind === "assembly_mate" && [1, 2, 3, 4, 5].includes(feature.params.mate_type) && feature.input_feature_ids?.[1] === instanceId); }

function assertAssemblyInstanceEditable(document, feature, parameter = null) {
  if (feature.kind !== "assembly_instance") return;
  if (parameter === "fixed") throw new Error("invalid_parameter: instance grounding is controlled by a fixed mate");
  const poseParameters = new Set(["x", "y", "z", "rotation_x", "rotation_y", "rotation_z", "scale_x", "scale_y", "scale_z"]);
  if (parameter && !poseParameters.has(parameter)) return;
  if (feature.params.fixed === 1) throw new Error(`mate_conflict: '${feature.id}' is fixed`);
  const positionMate = assemblyPositionMateDriving(document, feature.id), orientationMate = assemblyOrientationMateDriving(document, feature.id);
  if (positionMate && (!parameter || ["x", "y", "z"].includes(parameter))) throw new Error(`mate_conflict: '${feature.id}' position is driven by '${positionMate.id}'; edit the mate parameters instead`);
  if (orientationMate && (!parameter || parameter.startsWith("rotation_"))) throw new Error(`mate_conflict: '${feature.id}' orientation is driven by '${orientationMate.id}'; edit the mate parameters instead`);
}

async function loadView() {
  try { return JSON.parse(await readFile(viewPath, "utf8")); }
  catch (error) { if (error?.code === "ENOENT") return { section: null, measurement: null, isolated_feature_id: null, exploded_distance: 0 }; throw error; }
}

async function saveView(view) {
  const temporaryPath = `${viewPath}.${process.pid}.tmp`;
  await mkdir(dataRoot, { recursive: true });
  await writeFile(temporaryPath, `${JSON.stringify(view, null, 2)}\n`, "utf8");
  await rename(temporaryPath, viewPath);
}

function resolvedMeasurement(measurement, revision) {
  if (!measurement || measurement.revision !== revision) return null;
  const end = measurement.end || null;
  if (!end) return { ...measurement, end: null, distance: null, delta: null };
  const delta = { x: end.x - measurement.start.x, y: end.y - measurement.start.y, z: end.z - measurement.start.z };
  return { ...measurement, end, distance: Math.hypot(delta.x, delta.y, delta.z), delta };
}

function resolvedMotionStudy(study, document) {
  if (!study || !Number.isFinite(study.minimum) || !Number.isFinite(study.maximum) || !(study.minimum < study.maximum) || !Number.isFinite(study.progress)) return null;
  const mate = document.features.find((feature) => feature.id === study.mate_id && feature.kind === "assembly_mate" && feature.params.mate_type !== 0);
  if (!mate || !(study.parameter in mate.params) || !["angle", "distance", "axial_offset", "spin", "offset_x", "offset_y", "offset_z"].includes(study.parameter)) return null;
  if (study.parameter === "angle" && (study.minimum < 0 || study.maximum > 180)) return null;
  if (study.parameter === "distance" && mate.params.mate_type === 2 && study.minimum <= 0) return null;
  if (study.parameter === "distance" && mate.params.mate_type === 3 && study.minimum < 0) return null;
  const progress = Math.min(1, Math.max(0, study.progress));
  return { ...study, progress, playing: study.playing === true, value: study.minimum + (study.maximum - study.minimum) * progress };
}

function result(structuredContent, message) {
  return { content: [{ type: "text", text: message || JSON.stringify(structuredContent, null, 2) }], structuredContent };
}

function toolError(error, nextStep = "Call axis_cad_get_document and retry with the current revision.") {
  const message = error instanceof Error ? error.message : String(error);
  return { isError: true, content: [{ type: "text", text: `${message}. ${nextStep}` }] };
}

function assertRevision(document, expectedRevision) {
  if (document.revision !== expectedRevision) {
    throw new Error(`revision_conflict: expected ${expectedRevision}, active document is ${document.revision}`);
  }
}

function featureById(document, featureId) {
  const feature = document.features.find((candidate) => candidate.id === featureId);
  if (!feature) throw new Error(`invalid_reference: feature '${featureId}' does not exist`);
  return feature;
}

function assertValidParameter(value, field) {
  const signedParameters = new Set(["x", "y", "z", "rotation_x", "rotation_y", "rotation_z", "angle", "spin", "axial_offset", "origin_x", "origin_y", "origin_z", "direction_x", "direction_y", "direction_z", "axis_x", "axis_y", "axis_z", "start_x", "start_y", "start_z", "end_x", "end_y", "end_z", "twist_angle", "offset", "distance", "symmetric", "closed", "selector_mode", "selector_x", "selector_y", "selector_z", "selector_face_id", "selector_edge_id", "selector_edge_face_a", "selector_edge_face_b", "mate_type", "fixed", "opposed", "offset_x", "offset_y", "offset_z"]);
  const signed = signedParameters.has(field) || field.includes("_anchor_") || field.includes("_normal_") || field.includes("_axis_") || (field.startsWith("path_") && field !== "path_point_count");
  if (!Number.isFinite(value) || (!signed && value <= 0)) {
    throw new Error(`invalid_value: '${field}' must be finite${signed ? "" : " and greater than zero"}`);
  }
}

function compositePathFromParams(params) {
  const count = params.path_segment_count;
  if (!Number.isInteger(count) || count < 1 || count > 12) throw new Error("invalid_parameters: composite sweep requires 1 to 12 guide segments");
  const readPoint = (index, role) => [params[`path_${index}_${role}_x`], params[`path_${index}_${role}_y`], params[`path_${index}_${role}_z`]];
  const distance = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
  const segments = [];
  for (let index = 0; index < count; index += 1) {
    const kind = params[`path_${index}_kind`], start = readPoint(index, "start"), end = readPoint(index, "end");
    if (![0, 1].includes(kind)) throw new Error(`invalid_parameters: composite guide segment ${index} kind must be line or arc`);
    if (![...start, ...end].every(Number.isFinite)) throw new Error(`invalid_parameters: composite guide segment ${index} coordinates are incomplete`);
    if (index > 0 && distance(segments[index - 1].end, start) > 1e-6) throw new Error(`invalid_parameters: composite guide segment ${index} is disconnected`);
    if (kind === 0) {
      if (distance(start, end) < 1e-6) throw new Error(`invalid_parameters: composite guide line ${index} has zero length`);
      segments.push({ type: "line", start, end });
      continue;
    }
    const mid = readPoint(index, "mid");
    if (!mid.every(Number.isFinite)) throw new Error(`invalid_parameters: composite guide arc ${index} midpoint is incomplete`);
    const u = mid.map((value, axis) => value - start[axis]), v = end.map((value, axis) => value - start[axis]);
    const cross = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]];
    if (distance(start, mid) < 1e-6 || distance(mid, end) < 1e-6 || Math.hypot(...cross) < 1e-8) throw new Error(`invalid_parameters: composite guide arc ${index} needs three distinct non-collinear points`);
    segments.push({ type: "arc", start, mid, end });
  }
  return segments;
}

function validateCompositeContinuity(segments, params) {
  const mode = params.continuity_mode ?? 0;
  if (mode === 0 || segments.length < 2) return;
  const sub = (a, b) => a.map((value, index) => value - b[index]);
  const add = (a, b) => a.map((value, index) => value + b[index]);
  const scale = (a, factor) => a.map((value) => value * factor);
  const dot = (a, b) => a.reduce((sum, value, index) => sum + value * b[index], 0);
  const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
  const norm = (a) => Math.hypot(...a);
  const normalize = (a) => scale(a, 1 / norm(a));
  const arcCenter = (segment) => {
    const u = sub(segment.mid, segment.start), v = sub(segment.end, segment.start), normal = cross(u, v);
    return add(segment.start, scale(add(scale(cross(v, normal), dot(u, u)), scale(cross(normal, u), dot(v, v))), 1 / (2 * dot(normal, normal))));
  };
  const tangent = (segment, atEnd) => {
    if (segment.type === "line") return normalize(sub(segment.end, segment.start));
    const center = arcCenter(segment), normal = normalize(cross(sub(segment.mid, segment.start), sub(segment.end, segment.start)));
    return normalize(cross(normal, sub(atEnd ? segment.end : segment.start, center)));
  };
  const curvature = (segment, atEnd) => {
    if (segment.type === "line") return [0, 0, 0];
    const center = arcCenter(segment), point = atEnd ? segment.end : segment.start, radius = norm(sub(point, center));
    return scale(sub(center, point), 1 / (radius * radius));
  };
  const tolerance = params.tangent_tolerance ?? 1;
  for (let index = 1; index < segments.length; index += 1) {
    const angle = Math.acos(Math.max(-1, Math.min(1, dot(tangent(segments[index - 1], true), tangent(segments[index], false))))) * 180 / Math.PI;
    if (angle > tolerance + 1e-9) throw new Error(`invalid_parameters: segment ${index + 1} join is not G1; tangent mismatch is ${angle.toFixed(3)} degrees`);
    if (mode === 2) {
      const left = curvature(segments[index - 1], true), right = curvature(segments[index], false), delta = norm(sub(left, right));
      if (delta > Math.max(norm(left), norm(right), 1) * 1e-5) throw new Error(`invalid_parameters: segment ${index + 1} join is not G2; curvature vectors do not match`);
    }
  }
}

function setFeatureParameter(feature, parameter, value) {
  feature.params[parameter] = value;
  if (feature.kind !== "sweep_feature" || feature.params.path_segment_count === undefined) return;
  const match = /^path_(\d+)_(start|end)_([xyz])$/.exec(parameter);
  if (!match) return;
  const index = Number(match[1]), role = match[2], axis = match[3], count = feature.params.path_segment_count;
  if (role === "start" && index > 0) feature.params[`path_${index - 1}_end_${axis}`] = value;
  if (role === "end" && index + 1 < count) feature.params[`path_${index + 1}_start_${axis}`] = value;
}

function sweepScaleStationsFromParams(params) {
  if (params.scale_station_count === undefined) return [];
  const count = params.scale_station_count;
  if (!Number.isInteger(count) || count < 0 || count > 8) throw new Error("invalid_parameters: sweep requires 0 to 8 scale stations");
  const stations = Array.from({ length: count }, (_, index) => ({ position: params[`scale_station_${index}_position`], scale: params[`scale_station_${index}_factor`] }));
  let previous = 0;
  for (const [index, station] of stations.entries()) {
    if (!Number.isFinite(station.position) || !Number.isFinite(station.scale) || station.position <= previous || station.position >= 1 || station.scale <= 0) throw new Error(`invalid_parameters: scale station ${index + 1} must have an increasing position inside (0, 1) and a positive scale`);
    previous = station.position;
  }
  return stations;
}

function sweepProfileStationsFromParams(params) {
  if (params.profile_station_count === undefined) return [];
  const count = params.profile_station_count;
  if (!Number.isInteger(count) || count < 1 || count > 8) throw new Error("invalid_parameters: morph sweep requires 1 to 8 profile stations");
  const positions = Array.from({ length: count }, (_, index) => params[`profile_station_${index}_position`]);
  let previous = 0;
  positions.forEach((position, index) => {
    if (!(Number.isFinite(position) && position > previous && position <= 1)) throw new Error(`invalid_parameters: profile station ${index + 1} needs an increasing position inside (0, 1]`);
    previous = position;
  });
  if (Math.abs(previous - 1) > 1e-6) throw new Error("invalid_parameters: the final morph profile station must be at path position 1");
  return positions;
}

function storeSweepScaleStations(params, stations) {
  if (stations.length === 0) return;
  params.scale_station_count = stations.length;
  stations.forEach((station, index) => {
    params[`scale_station_${index}_position`] = station.position;
    params[`scale_station_${index}_factor`] = station.scale;
  });
}

function storeSweepOrientation(params, frameMode, upDirection, guidePoints) {
  const mode = { minimum_twist: 0, curvature: 1, fixed_up: 2 }[frameMode];
  const upLength = Math.hypot(upDirection.x, upDirection.y, upDirection.z);
  if (mode === undefined || (mode === 2 && upLength < 1e-6)) throw new Error("invalid_parameters: fixed-up sweep orientation requires a nonzero up direction");
  params.frame_mode = mode;
  params.up_x = upDirection.x; params.up_y = upDirection.y; params.up_z = upDirection.z;
  params.guide_point_count = guidePoints.length;
  guidePoints.forEach((point, index) => {
    params[`guide_${index}_x`] = point.x; params[`guide_${index}_y`] = point.y; params[`guide_${index}_z`] = point.z;
  });
}

function sweepOrientationFromParams(params) {
  const mode = params.frame_mode ?? 0, count = params.guide_point_count ?? 0;
  if (!Number.isInteger(mode) || mode < 0 || mode > 2) throw new Error("invalid_parameters: sweep frame mode must be 0, 1, or 2");
  if (!Number.isInteger(count) || (count !== 0 && (count < 2 || count > 12))) throw new Error("invalid_parameters: sweep guide rail needs 2 to 12 points");
  const up = [params.up_x ?? 0, params.up_y ?? 0, params.up_z ?? 1];
  if (!up.every(Number.isFinite) || (mode === 2 && Math.hypot(...up) < 1e-6)) throw new Error("invalid_parameters: fixed-up sweep orientation requires a nonzero up direction");
  for (let index = 0; index < count; index += 1) {
    if (![params[`guide_${index}_x`], params[`guide_${index}_y`], params[`guide_${index}_z`]].every(Number.isFinite)) throw new Error(`invalid_parameters: sweep guide point ${index + 1} is incomplete`);
  }
}

function storeSweepTangents(params, startTangent, endTangent) {
  params.tangent_mode = (startTangent ? 1 : 0) | (endTangent ? 2 : 0);
  for (const [prefix, tangent] of [["start", startTangent], ["end", endTangent]]) {
    if (!tangent) continue;
    if (Math.hypot(tangent.x, tangent.y, tangent.z) < 1e-6) throw new Error(`invalid_parameters: ${prefix} tangent must be nonzero`);
    params[`${prefix}_tangent_x`] = tangent.x; params[`${prefix}_tangent_y`] = tangent.y; params[`${prefix}_tangent_z`] = tangent.z;
  }
}

function sweepPathControlsFromParams(params) {
  if (params.path_point_count !== undefined) {
    const mode = params.tangent_mode ?? 0;
    if (!Number.isInteger(mode) || mode < 0 || mode > 3) throw new Error("invalid_parameters: spline tangent mode must be 0 to 3");
    for (const [prefix, bit] of [["start", 1], ["end", 2]]) {
      if ((mode & bit) === 0) continue;
      const tangent = [params[`${prefix}_tangent_x`], params[`${prefix}_tangent_y`], params[`${prefix}_tangent_z`]];
      if (!tangent.every(Number.isFinite) || Math.hypot(...tangent) < 1e-6) throw new Error(`invalid_parameters: ${prefix} tangent must be finite and nonzero`);
    }
  }
  if (params.path_segment_count !== undefined) {
    const mode = params.continuity_mode ?? 0, tolerance = params.tangent_tolerance ?? 1;
    if (!Number.isInteger(mode) || mode < 0 || mode > 2 || !Number.isFinite(tolerance) || tolerance < 0 || tolerance > 90) throw new Error("invalid_parameters: composite continuity mode must be 0 to 2 and tolerance 0 to 90 degrees");
  }
}

function storeSweepProfileSections(document, baseSketchId, sections, params) {
  if (!sections.length) return [baseSketchId];
  const ids = sections.map((section) => section.sketch_id);
  if (new Set(ids).size !== ids.length || ids.includes(baseSketchId)) throw new Error("invalid_dependency: morph sweep profiles must be distinct");
  const base = featureById(document, baseSketchId);
  const baseLoops = new Set((base.sketch?.entities || []).filter((entity) => !entity.construction).map((entity) => entity.loop_id || "outer"));
  if (baseLoops.size !== 1 || !baseLoops.has("outer")) throw new Error(`constraint_unsatisfied: morph start '${baseSketchId}' must be one closed outer loop without holes`);
  let previous = 0;
  for (const [index, section] of sections.entries()) {
    if (!(section.position > previous && section.position <= 1)) throw new Error(`invalid_parameters: profile section ${index + 1} needs a strictly increasing position inside (0, 1]`);
    const sketch = featureById(document, section.sketch_id), profile = validateProfileSketch(sketch);
    const profileLoops = new Set((sketch.sketch?.entities || []).filter((entity) => !entity.construction).map((entity) => entity.loop_id || "outer"));
    if (sketch.kind !== "profile_sketch" || !profile.closed || profile.errors.length || profileLoops.size !== 1 || !profileLoops.has("outer")) {
      throw new Error(`constraint_unsatisfied: morph section '${section.sketch_id}' must be one closed outer loop without holes`);
    }
    previous = section.position;
  }
  if (Math.abs(previous - 1) > 1e-6) throw new Error("invalid_parameters: the final morph profile section must be at path position 1");
  params.profile_station_count = sections.length;
  sections.forEach((section, index) => { params[`profile_station_${index}_position`] = section.position; });
  return [baseSketchId, ...ids];
}

function assertFeatureParameters(kind, params) {
  if (["edge_fillet", "edge_chamfer", "shell_feature", "linear_pattern", "circular_pattern"].includes(kind)) {
    assertModifierParameters(kind, params); return;
  }
  const sweepRequired = params.path_segment_count !== undefined ? ["path_segment_count", "twist_angle", "scale_start", "scale_end"] : params.path_point_count !== undefined ? ["path_point_count", "twist_angle", "scale_start", "scale_end"] : params.helix_radius === undefined ? ["start_x", "start_y", "start_z", "end_x", "end_y", "end_z", "twist_angle", "scale_start", "scale_end"] : ["helix_radius", "helix_pitch", "helix_turns", "twist_angle", "scale_start", "scale_end"];
  const required = {
    box: ["width", "height", "depth", "x", "y", "z"], cylinder: ["radius", "height", "x", "y", "z"],
    cone: ["radius_bottom", "radius_top", "height", "x", "y", "z"], sphere: ["radius", "x", "y", "z"],
    torus: ["major_radius", "tube_radius", "x", "y", "z"], extrude_feature: ["length", "symmetric"], pocket_feature: ["length", "symmetric"],
    revolve_feature: ["angle", "axis_x", "axis_y", "axis_z", "origin_x", "origin_y", "origin_z"],
    sweep_feature: sweepRequired, loft_feature: ["closed"], body_transform: ["x", "y", "z", "rotation_x", "rotation_y", "rotation_z", "scale_x", "scale_y", "scale_z"],
    assembly_instance: ["x", "y", "z", "rotation_x", "rotation_y", "rotation_z", "scale_x", "scale_y", "scale_z", "fixed"], assembly_mate: ["mate_type"], imported_step: ["body_number"]
  }[kind];
  if (!required) return;
  const missing = required.filter((key) => !(key in params));
  if (missing.length) throw new Error(`invalid_parameters: '${kind}' requires ${missing.join(", ")}`);
  if (kind === "torus" && params.major_radius <= params.tube_radius) throw new Error("invalid_parameters: torus major_radius must exceed tube_radius");
  if (["extrude_feature", "pocket_feature"].includes(kind) && ![0, 1].includes(params.symmetric)) throw new Error("invalid_parameters: symmetric must be 0 or 1");
  if (kind === "revolve_feature") {
    if (!(params.angle > 0 && params.angle <= 360)) throw new Error("invalid_parameters: revolve angle must be greater than 0 and no more than 360 degrees");
    if (Math.hypot(params.axis_x, params.axis_y, params.axis_z) < 1e-6) throw new Error("invalid_parameters: revolve axis cannot be zero");
  }
  if (kind === "sweep_feature" && params.path_segment_count !== undefined) {
    const segments = compositePathFromParams(params);
    validateCompositeContinuity(segments, params);
  } else if (kind === "sweep_feature" && params.path_point_count !== undefined) {
    const count = params.path_point_count;
    if (!Number.isInteger(count) || count < 2 || count > 12) throw new Error("invalid_parameters: spline sweep requires 2 to 12 guide points");
    const points = Array.from({ length: count }, (_, index) => [params[`path_${index}_x`], params[`path_${index}_y`], params[`path_${index}_z`]]);
    if (!points.flat().every(Number.isFinite)) throw new Error("invalid_parameters: spline guide coordinates are incomplete");
    if (!points.slice(1).some((point, index) => Math.hypot(point[0] - points[index][0], point[1] - points[index][1], point[2] - points[index][2]) > 1e-6)) throw new Error("invalid_parameters: spline path cannot have zero length");
  } else if (kind === "sweep_feature" && params.helix_radius === undefined && Math.hypot(params.end_x - params.start_x, params.end_y - params.start_y, params.end_z - params.start_z) < 1e-6) {
    throw new Error("invalid_parameters: sweep path cannot have zero length");
  }
  if (kind === "sweep_feature") { sweepScaleStationsFromParams(params); sweepProfileStationsFromParams(params); sweepOrientationFromParams(params); sweepPathControlsFromParams(params); }
  if (kind === "loft_feature" && ![0, 1].includes(params.closed)) throw new Error("invalid_parameters: loft closed must be 0 or 1");
  if (kind === "assembly_instance" && ![0, 1].includes(params.fixed)) throw new Error("invalid_parameters: assembly instance fixed must be 0 or 1");
  if (kind === "imported_step" && (!Number.isInteger(params.body_number) || params.body_number < 1)) throw new Error("invalid_parameters: imported STEP body_number must be a positive integer");
  if (kind === "assembly_mate") {
    if (![0, 1, 2, 3, 4, 5].includes(params.mate_type)) throw new Error("invalid_parameters: mate_type must be fixed, coincident, distance, plane, concentric, or angle");
    if ([1, 2, 3, 4].includes(params.mate_type) && !["reference_anchor_x", "reference_anchor_y", "reference_anchor_z", "moving_anchor_x", "moving_anchor_y", "moving_anchor_z"].every((key) => Number.isFinite(params[key]))) throw new Error("invalid_parameters: positional mate requires finite local anchors");
    if (params.mate_type === 1 && !["offset_x", "offset_y", "offset_z"].every((key) => Number.isFinite(params[key]))) throw new Error("invalid_parameters: coincident mate requires a finite offset");
    if (params.mate_type === 2 && (!(params.distance > 0) || !["axis_x", "axis_y", "axis_z"].every((key) => Number.isFinite(params[key])) || Math.hypot(params.axis_x, params.axis_y, params.axis_z) < 1e-6)) throw new Error("invalid_parameters: distance mate requires a positive distance and nonzero finite axis");
    if (params.mate_type === 3 && (!(params.distance >= 0) || !Number.isFinite(params.spin) || ![0, 1].includes(params.opposed) || !["reference_normal_x", "reference_normal_y", "reference_normal_z", "moving_normal_x", "moving_normal_y", "moving_normal_z"].every((key) => Number.isFinite(params[key])) || Math.hypot(params.reference_normal_x, params.reference_normal_y, params.reference_normal_z) < 1e-6 || Math.hypot(params.moving_normal_x, params.moving_normal_y, params.moving_normal_z) < 1e-6)) throw new Error("invalid_parameters: plane mate requires nonzero finite local normals, nonnegative offset, finite spin, and opposed 0 or 1");
    if (params.mate_type === 4 && (!Number.isFinite(params.axial_offset) || !Number.isFinite(params.spin) || ![0, 1].includes(params.opposed) || !["reference_axis_x", "reference_axis_y", "reference_axis_z", "moving_axis_x", "moving_axis_y", "moving_axis_z"].every((key) => Number.isFinite(params[key])) || Math.hypot(params.reference_axis_x, params.reference_axis_y, params.reference_axis_z) < 1e-6 || Math.hypot(params.moving_axis_x, params.moving_axis_y, params.moving_axis_z) < 1e-6)) throw new Error("invalid_parameters: concentric mate requires nonzero finite local axes, finite axial offset/spin, and opposed 0 or 1");
    if (params.mate_type === 5 && (!(params.angle >= 0 && params.angle <= 180) || !Number.isFinite(params.spin) || !["reference_normal_x", "reference_normal_y", "reference_normal_z", "moving_normal_x", "moving_normal_y", "moving_normal_z", "hinge_axis_x", "hinge_axis_y", "hinge_axis_z"].every((key) => Number.isFinite(params[key])) || Math.hypot(params.reference_normal_x, params.reference_normal_y, params.reference_normal_z) < 1e-6 || Math.hypot(params.moving_normal_x, params.moving_normal_y, params.moving_normal_z) < 1e-6 || Math.hypot(params.hinge_axis_x, params.hinge_axis_y, params.hinge_axis_z) < 1e-6 || Math.hypot(params.reference_normal_y*params.hinge_axis_z-params.reference_normal_z*params.hinge_axis_y, params.reference_normal_z*params.hinge_axis_x-params.reference_normal_x*params.hinge_axis_z, params.reference_normal_x*params.hinge_axis_y-params.reference_normal_y*params.hinge_axis_x) < 1e-6)) throw new Error("invalid_parameters: angle mate requires 0...180 degrees, finite spin, nonzero normals, and a nonparallel hinge axis");
  }
}

function modifierDefaults(kind) {
  if (kind === "edge_fillet") return { radius: 2 };
  if (kind === "edge_chamfer") return { distance: 2 };
  if (kind === "shell_feature") return { thickness: 1.5 };
  if (kind === "linear_pattern") return { direction_x: 1, direction_y: 0, direction_z: 0, count: 3, spacing: 24 };
  if (kind === "circular_pattern") return { origin_x: 0, origin_y: 0, origin_z: 0, axis_x: 0, axis_y: 0, axis_z: 1, count: 4, angle: 360 };
  throw new Error(`unsupported_modifier: '${kind}'`);
}

function assertModifierParameters(kind, params) {
  const defaults = modifierDefaults(kind), missing = Object.keys(defaults).filter((key) => !(key in params));
  if (missing.length) throw new Error(`invalid_parameters: '${kind}' requires ${missing.join(", ")}`);
  if (["linear_pattern", "circular_pattern"].includes(kind) && (!Number.isInteger(params.count) || params.count < 2)) throw new Error("invalid_parameters: pattern count must be an integer of at least 2");
  if (kind === "linear_pattern" && Math.hypot(params.direction_x, params.direction_y, params.direction_z) < 1e-9) throw new Error("invalid_parameters: linear pattern direction cannot be zero");
  if (kind === "circular_pattern" && Math.hypot(params.axis_x, params.axis_y, params.axis_z) < 1e-9) throw new Error("invalid_parameters: circular pattern axis cannot be zero");
  if (["edge_fillet", "edge_chamfer"].includes(kind) && params.selector_mode !== undefined) {
    if (![0, 1, 2, 3].includes(params.selector_mode)) throw new Error("invalid_parameters: edge selector mode must be all, near, direction, or stable topology");
    if (params.selector_mode > 0 && !["selector_x", "selector_y", "selector_z"].every((key) => Number.isFinite(params[key]))) throw new Error("invalid_parameters: selected edge requires three finite selector coordinates");
    if (params.selector_mode === 2 && Math.hypot(params.selector_x, params.selector_y, params.selector_z) < 1e-9) throw new Error("invalid_parameters: edge direction cannot be zero");
    if (params.selector_face_id !== undefined && (!Number.isInteger(params.selector_face_id) || params.selector_face_id < 0)) throw new Error("invalid_parameters: selector_face_id must be a nonnegative BRep face ordinal");
    if (params.selector_mode === 3 && (!["selector_edge_id", "selector_edge_face_a", "selector_edge_face_b"].every((key) => Number.isInteger(params[key]) && params[key] >= 0))) throw new Error("invalid_parameters: stable edge selector requires a nonnegative edge ID and two adjacent face IDs");
  }
}

function recordOperation(document, operation) {
  document.revision += 1;
  const operationId = `op-${document.revision}`;
  document.operations.unshift({ operation_id: operationId, author: "codex", ...operation, revision: document.revision, timestamp: new Date().toISOString() });
  return operationId;
}

function applyEdit(document, edit) {
  const feature = featureById(document, edit.feature_id);
  switch (edit.action) {
    case "set_parameter": {
      if (!edit.parameter || edit.value === undefined) throw new Error("invalid_edit: set_parameter requires parameter and value");
      if (!(edit.parameter in feature.params)) throw new Error(`invalid_parameter: '${edit.parameter}' is not defined on '${feature.id}'`);
      if (feature.kind === "sweep_feature" && ((feature.params.path_point_count !== undefined && edit.parameter === "path_point_count") || (feature.params.path_segment_count !== undefined && (edit.parameter === "path_segment_count" || /^path_\d+_kind$/.test(edit.parameter))))) throw new Error("invalid_parameter: guide topology is fixed; recreate the sweep to change segment count or type");
      if (feature.kind === "sweep_feature" && edit.parameter === "scale_station_count") throw new Error("invalid_parameter: scale station count is fixed; recreate the sweep to change its profile topology");
      if (feature.kind === "sweep_feature" && edit.parameter === "profile_station_count") throw new Error("invalid_parameter: morph section count is fixed; recreate the sweep to change section topology");
      assertAssemblyInstanceEditable(document, feature, edit.parameter);
      assertValidParameter(edit.value, edit.parameter);
      const previous = feature.params[edit.parameter];
      setFeatureParameter(feature, edit.parameter, edit.value);
      assertFeatureParameters(feature.kind, feature.params);
      return { action: edit.action, feature_id: feature.id, parameter: edit.parameter, previous_value: previous, value: edit.value };
    }
    case "rename_feature": {
      if (!edit.name?.trim()) throw new Error("invalid_edit: rename_feature requires a non-empty name");
      const previous = feature.name;
      feature.name = edit.name.trim();
      return { action: edit.action, feature_id: feature.id, previous_name: previous, name: feature.name };
    }
    case "set_visibility": {
      if (typeof edit.visible !== "boolean") throw new Error("invalid_edit: set_visibility requires visible=true or false");
      const previous = feature.visible;
      feature.visible = edit.visible;
      return { action: edit.action, feature_id: feature.id, previous_visible: previous, visible: feature.visible };
    }
    default: throw new Error(`unsupported_edit: '${edit.action}'`);
  }
}

const server = new McpServer(
  { name: "axis-cad-mcp-server", version: "0.2.0" },
  {
    instructions: "Axis CAD tools operate on the same local revisioned document as the native macOS app. Inspect before editing and pass expected_revision for every mutation. Prefer named parameters and atomic axis_cad_apply_edits batches. Create a checkpoint before destructive changes. After edits, call axis_cad_validate_document, then axis_cad_validate_with_kernel when STEP/topology confidence matters. The native Metal renderer updates from this file; the optional vcad WASM adapter runs out of process and reports tessellation manifold warnings explicitly."
  }
);

server.registerTool("axis_cad_get_document", {
  title: "Inspect Axis CAD Document",
  description: "Read the active native Axis CAD document, its revision, feature tree, visibility, and editable parameters. Does not modify anything.",
  inputSchema: {},
  outputSchema: { id: z.string(), name: z.string(), units: z.string(), revision: z.number(), backend: z.string(), features: z.array(featureSchema) },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async (_, { signal }) => {
  try {
    const document = await loadDocument();
    return result({ id: document.id, name: document.name, units: document.units, revision: document.revision, backend: document.backend, features: document.features });
  } catch (error) { return toolError(error, "Verify that ~/Library/Application Support/AxisCAD is writable."); }
});

server.registerTool("axis_cad_get_selection", {
  title: "Inspect Axis CAD Selection",
  description: "Read the feature and exact surface or edge last selected in the native Metal viewport. Kernel selections include deterministic topology_face_id and, near an edge, topology_edge_id plus its adjacent faces; position, normal, and triangle remain as fallback context. Selection is ephemeral and does not change geometry revision.",
  inputSchema: {},
  outputSchema: { revision: z.number(), feature_ids: z.array(z.string()), features: z.array(featureSchema), surface: selectionSurfaceSchema.nullable() },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async () => {
  try {
    const document = await loadDocument();
    let featureIds = [], surface = null, selectionRevision = null;
    try { const selection = JSON.parse(await readFile(selectionPath, "utf8")); featureIds = selection.feature_ids || []; surface = selection.surface || null; selectionRevision = selection.revision ?? null; } catch (error) { if (error?.code !== "ENOENT") throw error; }
    const features = featureIds.map((id) => document.features.find((feature) => feature.id === id)).filter(Boolean);
    if (selectionRevision !== document.revision) surface = null;
    if (!features.some((feature) => feature.id === surface?.feature_id)) surface = null;
    return result({ revision: document.revision, feature_ids: features.map((feature) => feature.id), features, surface });
  } catch (error) { return toolError(error, "Select a feature in Axis CAD and retry."); }
});

server.registerTool("axis_cad_get_view", {
  title: "Inspect Axis CAD View",
  description: "Read the native viewport's ephemeral section plane, point measurement, isolated body, and exploded-assembly distance. View state does not modify geometry or advance document revision.",
  inputSchema: {},
  outputSchema: { revision: z.number(), section: sectionPlaneSchema.nullable(), measurement: measurementProbeSchema.nullable(), isolated_feature_id: z.string().nullable(), exploded_distance: z.number(), motion_study: motionStudySchema.nullable() },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async () => {
  try {
    const document = await loadDocument(), view = await loadView();
    const storedIsolate = view.isolated_feature_id ?? view.isolatedFeatureId;
    const isolatedFeatureId = document.features.some((feature) => feature.id === storedIsolate) ? storedIsolate : null;
    return result({ revision: document.revision, section: view.section || null, measurement: resolvedMeasurement(view.measurement, document.revision), isolated_feature_id: isolatedFeatureId, exploded_distance: Math.min(200, Math.max(0, view.exploded_distance ?? view.explodedDistance ?? 0)), motion_study: resolvedMotionStudy(view.motion_study, document) });
  } catch (error) { return toolError(error); }
});

server.registerTool("axis_cad_set_isolate", {
  title: "Isolate Axis CAD Body",
  description: "Isolate one feature in the native Metal viewport or restore all visible bodies without changing model visibility, geometry, or revision.",
  inputSchema: { expected_revision: z.number().int().nonnegative(), enabled: z.boolean().default(true), feature_id: z.string().min(1).optional() },
  outputSchema: { ok: z.boolean(), revision: z.number(), isolated_feature_id: z.string().nullable() },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async ({ expected_revision, enabled, feature_id }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    if (enabled && !feature_id) throw new Error("invalid_isolate: feature_id is required when enabled=true");
    if (enabled) featureById(document, feature_id);
    const view = await loadView(), isolatedFeatureId = enabled ? feature_id : null;
    await saveView({ ...view, isolated_feature_id: isolatedFeatureId });
    return result({ ok: true, revision: document.revision, isolated_feature_id: isolatedFeatureId }, isolatedFeatureId ? `Isolated '${isolatedFeatureId}' in the native viewport.` : "Showing all visible bodies.");
  } catch (error) { return toolError(error, "Retry with the current revision and an existing feature ID, or enabled=false to show all."); }
});

server.registerTool("axis_cad_set_exploded_view", {
  title: "Set Axis CAD Exploded Assembly View",
  description: "Spread assembly instances outward in the native Metal viewport for inspection without changing solved poses, geometry, BOM, exports, or document revision.",
  inputSchema: { expected_revision: z.number().int().nonnegative(), distance: z.number().finite().min(0).max(200) },
  outputSchema: { ok: z.boolean(), revision: z.number(), exploded_distance: z.number() },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async ({ expected_revision, distance }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    const view = await loadView(); await saveView({ ...view, exploded_distance: distance, measurement: null });
    return result({ ok: true, revision: document.revision, exploded_distance: distance }, distance > 0 ? `Exploded assembly view to ${distance} ${document.units}; solved model and exports are unchanged.` : "Assembly view collapsed to solved positions.");
  } catch (error) { return toolError(error, "Retry with the current revision and a distance from 0 to 200 mm."); }
});

server.registerTool("axis_cad_set_motion_study", {
  title: "Set Axis CAD Assembly Motion Study",
  description: "Configure, play, scrub, or clear a GPU-only preview that drives one editable assembly-mate parameter without changing the solved document, revision, BOM, or exports.",
  inputSchema: { expected_revision: z.number().int().nonnegative(), enabled: z.boolean().default(true), mate_id: z.string().min(1).optional(), parameter: z.enum(["angle", "distance", "axial_offset", "spin", "offset_x", "offset_y", "offset_z"]).optional(), minimum: z.number().finite().optional(), maximum: z.number().finite().optional(), progress: z.number().finite().min(0).max(1).default(0), playing: z.boolean().default(false) },
  outputSchema: { ok: z.boolean(), revision: z.number(), motion_study: motionStudySchema.nullable() },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async ({ expected_revision, enabled, mate_id, parameter, minimum, maximum, progress, playing }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision); const view = await loadView();
    if (!enabled) { await saveView({ ...view, motion_study: null }); return result({ ok: true, revision: document.revision, motion_study: null }, "Assembly motion preview closed."); }
    if (!mate_id || !parameter || minimum === undefined || maximum === undefined) throw new Error("invalid_motion_study: mate_id, parameter, minimum, and maximum are required when enabled=true");
    const stored = { mate_id, parameter, minimum, maximum, progress, playing }, motionStudy = resolvedMotionStudy(stored, document);
    if (!motionStudy) throw new Error("invalid_motion_study: choose an editable parameter on a non-fixed mate and a valid increasing range");
    await saveView({ ...view, motion_study: stored, measurement: null });
    return result({ ok: true, revision: document.revision, motion_study: motionStudy }, `${playing ? "Playing" : "Scrubbed"} ${mate_id}.${parameter} at ${motionStudy.value.toFixed(3)}; model revision and exports are unchanged.`);
  } catch (error) { return toolError(error, "Retry with the current revision, a non-fixed mate parameter, valid range, and progress from 0 to 1; use enabled=false to close."); }
});

server.registerTool("axis_cad_set_section", {
  title: "Set Axis CAD Section View",
  description: "Enable, move, flip, or clear a GPU clipping plane in the native viewport without changing model geometry or revision.",
  inputSchema: { expected_revision: z.number().int().nonnegative(), enabled: z.boolean().default(true), axis: z.enum(["x", "y", "z"]).default("z"), offset: z.number().finite().default(0), flipped: z.boolean().default(false) },
  outputSchema: { ok: z.boolean(), revision: z.number(), section: sectionPlaneSchema.nullable() },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async ({ expected_revision, enabled, axis, offset, flipped }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    const section = enabled ? { axis, offset, flipped } : null, view = await loadView();
    await saveView({ ...view, section });
    return result({ ok: true, revision: document.revision, section }, section ? `Section ${axis.toUpperCase()} at ${offset} ${document.units}${flipped ? " (flipped)" : ""}.` : "Section view cleared.");
  } catch (error) { return toolError(error, "Retry with the current document revision and a finite section offset."); }
});

server.registerTool("axis_cad_set_measurement", {
  title: "Set Axis CAD Point Measurement",
  description: "Show or clear a revision-scoped two-point distance probe in the native Metal viewport. Reports true 3D distance and signed axis deltas without changing model geometry.",
  inputSchema: { expected_revision: z.number().int().nonnegative(), enabled: z.boolean().default(true), start: selectionVectorSchema.optional(), end: selectionVectorSchema.optional() },
  outputSchema: { ok: z.boolean(), revision: z.number(), measurement: measurementProbeSchema.nullable() },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async ({ expected_revision, enabled, start, end }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    if (enabled && (!start || !end)) throw new Error("invalid_measurement: start and end are required when enabled=true");
    const view = await loadView(), stored = enabled ? { revision: document.revision, start, end } : null;
    await saveView({ ...view, measurement: stored });
    const measurement = resolvedMeasurement(stored, document.revision);
    return result({ ok: true, revision: document.revision, measurement }, measurement
      ? `Distance ${measurement.distance.toFixed(3)} ${document.units}; ΔX ${measurement.delta.x.toFixed(3)}, ΔY ${measurement.delta.y.toFixed(3)}, ΔZ ${measurement.delta.z.toFixed(3)}.`
      : "Point measurement cleared.");
  } catch (error) { return toolError(error, "Retry with the current revision and finite 3D start/end coordinates, or enabled=false."); }
});

server.registerTool("axis_cad_new_document", {
  title: "Create New Axis CAD Part",
  description: "Checkpoint the active document, then replace it with a fresh editable mounting-plate part. This is destructive to the active workspace and requires confirm=true.",
  inputSchema: { expected_revision: z.number().int().nonnegative(), name: z.string().min(1).max(120), confirm: z.literal(true) },
  outputSchema: { ok: z.boolean(), revision: z.number(), document_id: z.string(), name: z.string(), operation_id: z.string(), checkpoint_id: z.string() },
  annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, name }) => {
  try {
    const active = await loadDocument();
    assertRevision(active, expected_revision);
    await mkdir(checkpointsPath, { recursive: true });
    const checkpointId = `r${active.revision}-before-new-document`;
    await writeFile(path.join(checkpointsPath, `${checkpointId}.json`), `${JSON.stringify(active, null, 2)}\n`, { encoding: "utf8", flag: "wx" })
      .catch((error) => { if (error?.code !== "EEXIST") throw error; });
    const document = structuredClone(seedDocument);
    document.revision = active.revision + 1;
    document.id = `part-r${document.revision}`;
    document.name = name.trim();
    const operationId = `op-${document.revision}`;
    document.operations = [{ operation_id: operationId, author: "codex", kind: "new_document", revision: document.revision, timestamp: new Date().toISOString() }];
    await saveDocument(document);
    return result({ ok: true, revision: document.revision, document_id: document.id, name: document.name, operation_id: operationId, checkpoint_id: checkpointId }, `Created '${document.name}' at revision ${document.revision}; the previous document is checkpointed as '${checkpointId}'.`);
  } catch (error) { return toolError(error); }
});

server.registerTool("axis_cad_create_profile_sketch", {
  title: "Create Axis CAD Profile Sketch",
  description: "Create an empty editable profile sketch on the XY, XZ, or YZ plane. Add ordered line/arc entities or one circle before creating an extrusion.",
  inputSchema: { expected_revision: z.number().int().nonnegative(), feature_id: z.string().regex(/^[a-z][a-z0-9-]{1,63}$/), name: z.string().min(1).max(120), plane: z.enum(["XY", "XZ", "YZ"]), offset: z.number().finite().default(0) },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), feature: featureSchema },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id, name, plane, offset }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    if (document.features.some((feature) => feature.id === feature_id)) throw new Error(`duplicate_feature: '${feature_id}' already exists`);
    const feature = { id: feature_id, name: name.trim(), kind: "profile_sketch", visible: true, params: { offset }, sketch: { plane, profile: "custom-profile", constraints: [], entities: [] } };
    document.features.push(feature); const operationId = recordOperation(document, { kind: "create_profile_sketch", feature_id, plane, offset }); await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, feature }, `Created '${feature.name}' on ${plane} at ${offset} ${document.units} offset, revision ${document.revision}. Add a closed outer loop and optional closed hole loops.`);
  } catch (error) { return toolError(error); }
});

server.registerTool("axis_cad_add_sketch_entity", {
  title: "Add Axis CAD Sketch Entity",
  description: "Append one ordered line, circle, or arc to a custom profile loop. Use loop_id='outer' for material boundary and a stable alternate loop ID for each hole. Lines use x1/y1/x2/y2; circles use cx/cy/radius; arcs use cx/cy/radius/start_angle/end_angle/ccw (angles in radians).",
  inputSchema: {
    expected_revision: z.number().int().nonnegative(), sketch_id: z.string().min(1), entity_id: z.string().regex(/^[a-z][a-z0-9-]{1,63}$/),
    kind: z.enum(["line", "circle", "arc"]), params: z.record(z.string(), z.number().finite()), construction: z.boolean().default(false), loop_id: z.string().regex(/^[a-z][a-z0-9-]{1,63}$/).default("outer")
  },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), entity: sketchEntitySchema, profile: z.object({ closed: z.boolean(), entity_count: z.number(), constraint_count: z.number(), degrees_of_freedom: z.number(), errors: z.array(z.string()) }) },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, sketch_id, entity_id, kind, params, construction, loop_id }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    const sketch = featureById(document, sketch_id);
    if (sketch.kind !== "profile_sketch" || !sketch.sketch) throw new Error(`invalid_reference: '${sketch_id}' is not a custom profile sketch`);
    if ((sketch.sketch.entities || []).some((entity) => entity.id === entity_id)) throw new Error(`duplicate_entity: '${entity_id}' already exists`);
    const required = { line: ["x1", "y1", "x2", "y2"], circle: ["cx", "cy", "radius"], arc: ["cx", "cy", "radius", "start_angle", "end_angle"] }[kind];
    const missing = required.filter((key) => !(key in params)); if (missing.length) throw new Error(`invalid_parameters: '${kind}' requires ${missing.join(", ")}`);
    if (["circle", "arc"].includes(kind) && !(params.radius > 0)) throw new Error("invalid_parameters: radius must be greater than zero");
    const entity = { id: entity_id, kind, params: kind === "arc" ? { ccw: 1, ...params } : params, construction, loop_id };
    sketch.sketch.entities ||= []; sketch.sketch.entities.push(entity);
    const profile = validateProfileSketch(sketch), operationId = recordOperation(document, { kind: "add_sketch_entity", feature_id: sketch_id, entity_id, entity_kind: kind, loop_id }); await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, entity, profile }, profile.closed ? `Closed profile completed at revision ${document.revision}.` : `Added ${kind} at revision ${document.revision}; continue until the profile is closed.`);
  } catch (error) { return toolError(error, "Inspect the sketch and append valid ordered profile geometry."); }
});

server.registerTool("axis_cad_delete_sketch_entity", {
  title: "Delete Axis CAD Sketch Entity",
  description: "Delete one entity from a custom profile sketch and remove constraints that reference it. Derived features rebuild through the shared dependency graph.",
  inputSchema: { expected_revision: z.number().int().nonnegative(), sketch_id: z.string().min(1), entity_id: z.string().min(1) },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), deleted_entity_id: z.string(), removed_constraint_ids: z.array(z.string()), profile: z.object({ closed: z.boolean(), entity_count: z.number(), constraint_count: z.number(), degrees_of_freedom: z.number(), errors: z.array(z.string()) }) },
  annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, sketch_id, entity_id }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision); const sketch = featureById(document, sketch_id);
    if (sketch.kind !== "profile_sketch" || !sketch.sketch) throw new Error(`invalid_reference: '${sketch_id}' is not a custom profile sketch`);
    const index = (sketch.sketch.entities || []).findIndex((entity) => entity.id === entity_id); if (index < 0) throw new Error(`invalid_reference: sketch entity '${entity_id}' does not exist`);
    sketch.sketch.entities.splice(index, 1);
    const removed = sketch.sketch.constraints.filter((constraint) => constraint.entities.some((reference) => reference.split(":")[0] === entity_id)).map((constraint) => constraint.id);
    sketch.sketch.constraints = sketch.sketch.constraints.filter((constraint) => !removed.includes(constraint.id));
    const profile = validateProfileSketch(sketch), operationId = recordOperation(document, { kind: "delete_sketch_entity", feature_id: sketch_id, entity_id, removed_constraint_ids: removed }); await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, deleted_entity_id: entity_id, removed_constraint_ids: removed, profile }, `Deleted '${entity_id}' and ${removed.length} referencing constraint(s) at revision ${document.revision}.`);
  } catch (error) { return toolError(error); }
});

server.registerTool("axis_cad_set_sketch_entity_construction", {
  title: "Set Axis CAD Construction Geometry",
  description: "Mark one custom sketch entity as construction or profile geometry without deleting it.",
  inputSchema: { expected_revision: z.number().int().nonnegative(), sketch_id: z.string().min(1), entity_id: z.string().min(1), construction: z.boolean() },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), entity: sketchEntitySchema, profile: z.object({ closed: z.boolean(), entity_count: z.number(), constraint_count: z.number(), degrees_of_freedom: z.number(), errors: z.array(z.string()) }) },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async ({ expected_revision, sketch_id, entity_id, construction }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision); const sketch = featureById(document, sketch_id);
    const entity = sketch.sketch?.entities?.find((candidate) => candidate.id === entity_id); if (!entity) throw new Error(`invalid_reference: sketch entity '${entity_id}' does not exist`);
    entity.construction = construction; const profile = validateProfileSketch(sketch);
    const operationId = recordOperation(document, { kind: "set_sketch_entity_construction", feature_id: sketch_id, entity_id, construction }); await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, entity, profile }, `Set '${entity_id}' construction=${construction} at revision ${document.revision}.`);
  } catch (error) { return toolError(error); }
});

server.registerTool("axis_cad_add_sketch_constraint", {
  title: "Add Axis CAD Sketch Constraint",
  description: "Add and immediately solve a persistent horizontal, vertical, coincident, length, radius, parallel, perpendicular, equal, tangent, or angle constraint in a custom profile sketch. Angle uses degrees. Coincident references use entity:start or entity:end.",
  inputSchema: {
    expected_revision: z.number().int().nonnegative(), sketch_id: z.string().min(1), constraint_id: z.string().regex(/^[a-z][a-z0-9-]{1,63}$/),
    kind: z.enum(["horizontal", "vertical", "coincident", "length", "radius", "parallel", "perpendicular", "equal", "tangent", "angle"]), entities: z.array(z.string().min(1)).min(1).max(2), value: z.number().positive().optional()
  },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), constraint: sketchConstraintSchema, profile: z.object({ closed: z.boolean(), entity_count: z.number(), constraint_count: z.number(), degrees_of_freedom: z.number(), errors: z.array(z.string()) }) },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, sketch_id, constraint_id, kind, entities, value }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision); const sketch = featureById(document, sketch_id);
    if (sketch.kind !== "profile_sketch" || !sketch.sketch) throw new Error(`invalid_reference: '${sketch_id}' is not a custom profile sketch`);
    if (sketch.sketch.constraints.some((constraint) => constraint.id === constraint_id)) throw new Error(`duplicate_constraint: '${constraint_id}' already exists`);
    const constraint = { id: constraint_id, kind, entities, ...(value === undefined ? {} : { value }) };
    sketch.sketch.constraints.push(constraint); sketch.sketch.entities = solveProfileConstraints(sketch.sketch.constraints, sketch.sketch.entities || []);
    const profile = validateProfileSketch(sketch), operationId = recordOperation(document, { kind: "add_sketch_constraint", feature_id: sketch_id, constraint_id, constraint_kind: kind, entities, value }); await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, constraint, profile }, `Added ${kind} constraint '${constraint_id}' at revision ${document.revision}; ${profile.degrees_of_freedom} DOF remain.`);
  } catch (error) { return toolError(error, "Inspect entity IDs and endpoint references, then retry with the current revision."); }
});

server.registerTool("axis_cad_delete_sketch_constraint", {
  title: "Delete Axis CAD Sketch Constraint",
  description: "Remove one persistent custom sketch constraint while leaving its currently solved geometry in place.",
  inputSchema: { expected_revision: z.number().int().nonnegative(), sketch_id: z.string().min(1), constraint_id: z.string().min(1) },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), deleted_constraint_id: z.string(), profile: z.object({ closed: z.boolean(), entity_count: z.number(), constraint_count: z.number(), degrees_of_freedom: z.number(), errors: z.array(z.string()) }) },
  annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, sketch_id, constraint_id }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision); const sketch = featureById(document, sketch_id);
    const index = sketch.sketch?.constraints?.findIndex((constraint) => constraint.id === constraint_id) ?? -1; if (index < 0) throw new Error(`invalid_reference: constraint '${constraint_id}' does not exist`);
    sketch.sketch.constraints.splice(index, 1); const profile = validateProfileSketch(sketch);
    const operationId = recordOperation(document, { kind: "delete_sketch_constraint", feature_id: sketch_id, constraint_id }); await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, deleted_constraint_id: constraint_id, profile }, `Deleted constraint '${constraint_id}' at revision ${document.revision}.`);
  } catch (error) { return toolError(error); }
});

server.registerTool("axis_cad_update_sketch_constraint", {
  title: "Update Axis CAD Sketch Dimension",
  description: "Edit the positive value of an existing length, radius, or line-angle constraint and immediately re-solve the custom profile sketch. Angles are degrees strictly between 0 and 180.",
  inputSchema: { expected_revision: z.number().int().nonnegative(), sketch_id: z.string().min(1), constraint_id: z.string().min(1), value: z.number().positive() },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), constraint: sketchConstraintSchema, profile: z.object({ closed: z.boolean(), entity_count: z.number(), constraint_count: z.number(), degrees_of_freedom: z.number(), errors: z.array(z.string()) }) },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async ({ expected_revision, sketch_id, constraint_id, value }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision); const sketch = featureById(document, sketch_id);
    const constraint = sketch.sketch?.constraints?.find((candidate) => candidate.id === constraint_id);
    if (!constraint) throw new Error(`invalid_reference: constraint '${constraint_id}' does not exist`);
    if (!["length", "radius", "angle"].includes(constraint.kind)) throw new Error("invalid_constraint: only length, radius, and angle constraints have editable values");
    if (constraint.kind === "angle" && !(value < 180)) throw new Error("invalid_constraint: angle must be strictly between 0 and 180 degrees");
    const previousValue = constraint.value; constraint.value = value;
    sketch.sketch.entities = solveProfileConstraints(sketch.sketch.constraints, sketch.sketch.entities || []);
    const profile = validateProfileSketch(sketch), operationId = recordOperation(document, { kind: "update_sketch_constraint", feature_id: sketch_id, constraint_id, previous_value: previousValue, value }); await saveDocument(document);
    const suffix = constraint.kind === "angle" ? "°" : "";
    return result({ ok: true, revision: document.revision, operation_id: operationId, constraint, profile }, `Updated constraint '${constraint_id}' to ${value}${suffix} at revision ${document.revision}.`);
  } catch (error) { return toolError(error, "Use a valid positive value on an existing length, radius, or angle constraint and retry with the current revision."); }
});

server.registerTool("axis_cad_trim_extend_sketch_line", {
  title: "Trim or Extend Axis CAD Sketch Line",
  description: "Move one selected line endpoint to its intersection with a finite reference line. Trim requires a crossing; extend requires the named endpoint to face an intersection beyond the selected segment. Existing constraints are re-solved atomically.",
  inputSchema: { expected_revision: z.number().int().nonnegative(), sketch_id: z.string().min(1), line_id: z.string().min(1), reference_line_id: z.string().min(1), endpoint: z.enum(["start", "end"]), mode: z.enum(["trim", "extend"]) },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), entity: sketchEntitySchema, profile: z.object({ closed: z.boolean(), entity_count: z.number(), constraint_count: z.number(), degrees_of_freedom: z.number(), errors: z.array(z.string()) }) },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async ({ expected_revision, sketch_id, line_id, reference_line_id, endpoint, mode }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision); const sketch = featureById(document, sketch_id);
    if (sketch.kind !== "profile_sketch" || !sketch.sketch) throw new Error(`invalid_reference: '${sketch_id}' is not a custom profile sketch`);
    sketch.sketch.entities = trimOrExtendProfileLine(sketch.sketch.entities || [], line_id, reference_line_id, endpoint, mode);
    sketch.sketch.entities = solveProfileConstraints(sketch.sketch.constraints || [], sketch.sketch.entities);
    const entity = sketch.sketch.entities.find((candidate) => candidate.id === line_id), reference = sketch.sketch.entities.find((candidate) => candidate.id === reference_line_id);
    const point = { x: entity.params[endpoint === "start" ? "x1" : "x2"], y: entity.params[endpoint === "start" ? "y1" : "y2"] }, vx = reference.params.x2 - reference.params.x1, vy = reference.params.y2 - reference.params.y1, lengthSquared = vx * vx + vy * vy;
    const projection = ((point.x - reference.params.x1) * vx + (point.y - reference.params.y1) * vy) / lengthSquared, nearest = { x: reference.params.x1 + vx * projection, y: reference.params.y1 + vy * projection };
    if (projection < -0.0001 || projection > 1.0001 || Math.hypot(point.x - nearest.x, point.y - nearest.y) > 0.001) throw new Error("constraint_conflict: constraints moved the edited endpoint away from the reference");
    const profile = validateProfileSketch(sketch), operationId = recordOperation(document, { kind: `${mode}_sketch_line`, feature_id: sketch_id, line_id, reference_line_id, endpoint }); await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, entity, profile }, `${mode === "trim" ? "Trimmed" : "Extended"} '${line_id}' ${endpoint} to '${reference_line_id}' at revision ${document.revision}.`);
  } catch (error) { return toolError(error, "Choose two nonparallel lines and the endpoint on the side to trim or extend, then retry with the current revision."); }
});

server.registerTool("axis_cad_create_extrusion", {
  title: "Create Axis CAD Extrusion",
  description: "Extrude one closed custom outer profile and its optional hole loops with the external BRep kernel. The sketch remains as a suppressed dependency and the result streams into Metal.",
  inputSchema: { expected_revision: z.number().int().nonnegative(), feature_id: z.string().regex(/^[a-z][a-z0-9-]{1,63}$/), name: z.string().min(1).max(120), sketch_id: z.string().min(1), length: z.number().positive(), symmetric: z.boolean().default(false) },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), feature: featureSchema, profile_entity_count: z.number() },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id, name, sketch_id, length, symmetric }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    if (document.features.some((feature) => feature.id === feature_id)) throw new Error(`duplicate_feature: '${feature_id}' already exists`);
    const sketch = featureById(document, sketch_id), profile = validateProfileSketch(sketch);
    if (sketch.kind !== "profile_sketch" || !profile.closed || profile.errors.length) throw new Error(`constraint_unsatisfied: ${profile.errors.join(" ")}`);
    sketch.visible = false;
    const feature = { id: feature_id, name: name.trim(), kind: "extrude_feature", visible: true, params: { length, symmetric: symmetric ? 1 : 0 }, input_feature_ids: [sketch_id] };
    document.features.push(feature); const operationId = recordOperation(document, { kind: "create_extrusion", feature_id, input_feature_ids: [sketch_id], length, symmetric }); await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, feature, profile_entity_count: profile.entity_count }, `Created '${feature.name}' from '${sketch.name}' at revision ${document.revision}; the kernel mesh will stream into Metal.`);
  } catch (error) { return toolError(error, "Close the profile and retry with the current revision."); }
});

server.registerTool("axis_cad_create_pocket", {
  title: "Create Axis CAD Profile Pocket",
  description: "Cut one closed custom profile through an existing solid with the external BRep kernel. The target and sketch remain as reversible suppressed dependencies.",
  inputSchema: {
    expected_revision: z.number().int().nonnegative(), feature_id: z.string().regex(/^[a-z][a-z0-9-]{1,63}$/), name: z.string().min(1).max(120),
    target_feature_id: z.string().min(1), sketch_id: z.string().min(1), length: z.number().positive(), symmetric: z.boolean().default(false)
  },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), feature: featureSchema, profile_entity_count: z.number(), suppressed_feature_ids: z.array(z.string()) },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id, name, target_feature_id, sketch_id, length, symmetric }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    if (document.features.some((feature) => feature.id === feature_id)) throw new Error(`duplicate_feature: '${feature_id}' already exists`);
    if (target_feature_id === sketch_id) throw new Error("invalid_dependency: pocket target and sketch must be different features");
    const target = featureById(document, target_feature_id), sketch = featureById(document, sketch_id), profile = validateProfileSketch(sketch);
    const supported = new Set(["pad", "pocket", "fillet", "box", "cylinder", "cone", "sphere", "torus", ...kernelDerivedKinds]);
    if (!supported.has(target.kind)) throw new Error(`unsupported_kernel_feature: '${target_feature_id}' is not a solid-producing feature`);
    if (sketch.kind !== "profile_sketch" || !profile.closed || profile.errors.length) throw new Error(`constraint_unsatisfied: ${profile.errors.join(" ")}`);
    const suppressed = [];
    const targetIds = ["sketch-base", "pad-base", "pocket-holes", "fillet-edges"].includes(target_feature_id)
      ? ["sketch-base", "pad-base", "pocket-holes", "fillet-edges"] : [target_feature_id];
    for (const id of [...targetIds, sketch_id]) { const input = document.features.find((feature) => feature.id === id); if (input) { input.visible = false; suppressed.push(id); } }
    const feature = { id: feature_id, name: name.trim(), kind: "pocket_feature", visible: true, params: { length, symmetric: symmetric ? 1 : 0 }, input_feature_ids: [target_feature_id, sketch_id] };
    document.features.push(feature); const operationId = recordOperation(document, { kind: "create_pocket", feature_id, input_feature_ids: feature.input_feature_ids, length, symmetric }); await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, feature, profile_entity_count: profile.entity_count, suppressed_feature_ids: suppressed }, `Cut '${feature.name}' through '${target.name}' at revision ${document.revision}; the kernel mesh will stream into Metal.`);
  } catch (error) { return toolError(error, "Use a closed profile, a solid target, and the current revision."); }
});

server.registerTool("axis_cad_create_revolve", {
  title: "Create Axis CAD Revolve",
  description: "Revolve one closed custom profile around an arbitrary world-space axis with the external BRep kernel. The sketch remains as a reversible suppressed dependency.",
  inputSchema: {
    expected_revision: z.number().int().nonnegative(), feature_id: z.string().regex(/^[a-z][a-z0-9-]{1,63}$/), name: z.string().min(1).max(120), sketch_id: z.string().min(1),
    angle: z.number().positive().max(360).default(360),
    axis: z.object({ x: z.number().finite(), y: z.number().finite(), z: z.number().finite() }),
    origin: z.object({ x: z.number().finite(), y: z.number().finite(), z: z.number().finite() }).default({ x: 0, y: 0, z: 0 })
  },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), feature: featureSchema, profile_entity_count: z.number() },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id, name, sketch_id, angle, axis, origin }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    if (document.features.some((feature) => feature.id === feature_id)) throw new Error(`duplicate_feature: '${feature_id}' already exists`);
    const sketch = featureById(document, sketch_id), profile = validateProfileSketch(sketch);
    if (sketch.kind !== "profile_sketch" || !profile.closed || profile.errors.length) throw new Error(`constraint_unsatisfied: ${profile.errors.join(" ")}`);
    const axisLength = Math.hypot(axis.x, axis.y, axis.z);
    if (axisLength < 1e-6) throw new Error("invalid_parameters: revolve axis cannot be zero");
    sketch.visible = false;
    const feature = {
      id: feature_id, name: name.trim(), kind: "revolve_feature", visible: true,
      params: { angle, axis_x: axis.x / axisLength, axis_y: axis.y / axisLength, axis_z: axis.z / axisLength, origin_x: origin.x, origin_y: origin.y, origin_z: origin.z },
      input_feature_ids: [sketch_id]
    };
    document.features.push(feature); const operationId = recordOperation(document, { kind: "create_revolve", feature_id, input_feature_ids: [sketch_id], angle, axis, origin }); await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, feature, profile_entity_count: profile.entity_count }, `Revolved '${sketch.name}' by ${angle} degrees at revision ${document.revision}; the kernel mesh will stream into Metal.`);
  } catch (error) { return toolError(error, "Use a closed profile that does not cross the revolve axis, a nonzero axis, and the current revision."); }
});

server.registerTool("axis_cad_create_sweep", {
  title: "Create Axis CAD Line Sweep",
  description: "Sweep one closed profile along a world-space line with twist, scaling, minimum-twist/curvature/fixed-up orientation, an optional second guide rail, and regenerative morph sections.",
  inputSchema: {
    expected_revision: z.number().int().nonnegative(), feature_id: z.string().regex(/^[a-z][a-z0-9-]{1,63}$/), name: z.string().min(1).max(120), sketch_id: z.string().min(1),
    start: z.object({ x: z.number().finite(), y: z.number().finite(), z: z.number().finite() }).default({ x: 0, y: 0, z: 0 }),
    end: z.object({ x: z.number().finite(), y: z.number().finite(), z: z.number().finite() }),
    twist_angle: z.number().finite().default(0), scale_start: z.number().positive().default(1), scale_end: z.number().positive().default(1), scale_stations: z.array(sweepScaleStationSchema).max(8).default([]), profile_sections: z.array(sweepProfileSectionSchema).max(8).default([]),
    frame_mode: sweepFrameModeSchema.default("minimum_twist"), up_direction: selectionVectorSchema.default({ x: 0, y: 0, z: 1 }), guide_points: sweepGuidePointsSchema.default([])
  },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), feature: featureSchema, profile_entity_count: z.number(), path_length: z.number(), scale_station_count: z.number(), profile_section_count: z.number() },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id, name, sketch_id, start, end, twist_angle, scale_start, scale_end, scale_stations, profile_sections, frame_mode, up_direction, guide_points }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    if (document.features.some((feature) => feature.id === feature_id)) throw new Error(`duplicate_feature: '${feature_id}' already exists`);
    const sketch = featureById(document, sketch_id), profile = validateProfileSketch(sketch);
    if (sketch.kind !== "profile_sketch" || !profile.closed || profile.errors.length) throw new Error(`constraint_unsatisfied: ${profile.errors.join(" ")}`);
    const pathLength = Math.hypot(end.x - start.x, end.y - start.y, end.z - start.z);
    if (pathLength < 1e-6) throw new Error("invalid_parameters: sweep path cannot have zero length");
    const params = { start_x: start.x, start_y: start.y, start_z: start.z, end_x: end.x, end_y: end.y, end_z: end.z, twist_angle, scale_start, scale_end };
    storeSweepOrientation(params, frame_mode, up_direction, guide_points);
    storeSweepScaleStations(params, scale_stations); sweepScaleStationsFromParams(params);
    const inputIds = storeSweepProfileSections(document, sketch_id, profile_sections, params);
    inputIds.forEach((id) => { featureById(document, id).visible = false; });
    const feature = {
      id: feature_id, name: name.trim(), kind: "sweep_feature", visible: true,
      params,
      input_feature_ids: inputIds
    };
    document.features.push(feature); const operationId = recordOperation(document, { kind: "create_sweep", feature_id, input_feature_ids: inputIds, start, end, twist_angle, scale_start, scale_end, scale_stations, profile_sections, frame_mode, up_direction, guide_points }); await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, feature, profile_entity_count: profile.entity_count, path_length: pathLength, scale_station_count: scale_stations.length, profile_section_count: profile_sections.length + 1 }, `Swept '${sketch.name}' over ${pathLength.toFixed(2)} ${document.units} through ${profile_sections.length + 1} profile shape(s) at revision ${document.revision}; the kernel mesh will stream into Metal.`);
  } catch (error) { return toolError(error, "Use a closed profile, distinct start/end points, positive scales, and the current revision."); }
});

server.registerTool("axis_cad_create_spline_sweep", {
  title: "Create Axis CAD Spline Sweep",
  description: "Sweep a closed profile along an editable 3D Catmull-Rom path with optional endpoint tangent handles, scale/morph stations, explicit section orientation, and a second guide rail.",
  inputSchema: {
    expected_revision: z.number().int().nonnegative(), feature_id: z.string().regex(/^[a-z][a-z0-9-]{1,63}$/), name: z.string().min(1).max(120), sketch_id: z.string().min(1),
    points: z.array(selectionVectorSchema).min(2).max(12),
    twist_angle: z.number().finite().default(0), scale_start: z.number().positive().default(1), scale_end: z.number().positive().default(1), scale_stations: z.array(sweepScaleStationSchema).max(8).default([]), profile_sections: z.array(sweepProfileSectionSchema).max(8).default([]),
    frame_mode: sweepFrameModeSchema.default("minimum_twist"), up_direction: selectionVectorSchema.default({ x: 0, y: 0, z: 1 }), guide_points: sweepGuidePointsSchema.default([]), start_tangent: selectionVectorSchema.optional(), end_tangent: selectionVectorSchema.optional()
  },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), feature: featureSchema, profile_entity_count: z.number(), point_count: z.number(), control_polygon_length: z.number(), scale_station_count: z.number(), profile_section_count: z.number() },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id, name, sketch_id, points, twist_angle, scale_start, scale_end, scale_stations, profile_sections, frame_mode, up_direction, guide_points, start_tangent, end_tangent }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    if (document.features.some((feature) => feature.id === feature_id)) throw new Error(`duplicate_feature: '${feature_id}' already exists`);
    const sketch = featureById(document, sketch_id), profile = validateProfileSketch(sketch);
    if (sketch.kind !== "profile_sketch" || !profile.closed || profile.errors.length) throw new Error(`constraint_unsatisfied: ${profile.errors.join(" ")}`);
    const segmentLengths = points.slice(1).map((point, index) => Math.hypot(point.x - points[index].x, point.y - points[index].y, point.z - points[index].z));
    const controlPolygonLength = segmentLengths.reduce((sum, length) => sum + length, 0);
    if (controlPolygonLength < 1e-6) throw new Error("invalid_parameters: spline sweep guide cannot have zero length");
    const params = { path_point_count: points.length, twist_angle, scale_start, scale_end };
    storeSweepOrientation(params, frame_mode, up_direction, guide_points);
    storeSweepTangents(params, start_tangent, end_tangent);
    storeSweepScaleStations(params, scale_stations); sweepScaleStationsFromParams(params);
    const inputIds = storeSweepProfileSections(document, sketch_id, profile_sections, params);
    points.forEach((point, index) => { params[`path_${index}_x`] = point.x; params[`path_${index}_y`] = point.y; params[`path_${index}_z`] = point.z; });
    inputIds.forEach((id) => { featureById(document, id).visible = false; });
    const feature = { id: feature_id, name: name.trim(), kind: "sweep_feature", visible: true, params, input_feature_ids: inputIds };
    document.features.push(feature);
    const operationId = recordOperation(document, { kind: "create_spline_sweep", feature_id, input_feature_ids: inputIds, points, twist_angle, scale_start, scale_end, scale_stations, profile_sections, frame_mode, up_direction, guide_points, start_tangent, end_tangent });
    await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, feature, profile_entity_count: profile.entity_count, point_count: points.length, control_polygon_length: controlPolygonLength, scale_station_count: scale_stations.length, profile_section_count: profile_sections.length + 1 }, `Swept '${sketch.name}' through ${points.length} editable spline guide points and ${profile_sections.length + 1} profile shape(s) at revision ${document.revision}; the curved BRep mesh will stream into Metal.`);
  } catch (error) { return toolError(error, "Use a closed profile, 2-12 finite guide points with a nonzero path, positive scales, and the current revision."); }
});

server.registerTool("axis_cad_create_composite_sweep", {
  title: "Create Axis CAD Composite Sweep",
  description: "Sweep a closed profile along connected editable 3D lines/arcs with G0/G1/G2 join validation, scale/morph stations, explicit section orientation, and a second guide rail.",
  inputSchema: {
    expected_revision: z.number().int().nonnegative(), feature_id: z.string().regex(/^[a-z][a-z0-9-]{1,63}$/), name: z.string().min(1).max(120), sketch_id: z.string().min(1),
    segments: z.array(compositePathSegmentSchema).min(1).max(12),
    twist_angle: z.number().finite().default(0), scale_start: z.number().positive().default(1), scale_end: z.number().positive().default(1), scale_stations: z.array(sweepScaleStationSchema).max(8).default([]), profile_sections: z.array(sweepProfileSectionSchema).max(8).default([]),
    frame_mode: sweepFrameModeSchema.default("minimum_twist"), up_direction: selectionVectorSchema.default({ x: 0, y: 0, z: 1 }), guide_points: sweepGuidePointsSchema.default([]), continuity: sweepContinuitySchema.default("position"), tangent_tolerance_degrees: z.number().min(0).max(90).default(1)
  },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), feature: featureSchema, profile_entity_count: z.number(), segment_count: z.number(), guide_length: z.number(), scale_station_count: z.number(), profile_section_count: z.number() },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id, name, sketch_id, segments, twist_angle, scale_start, scale_end, scale_stations, profile_sections, frame_mode, up_direction, guide_points, continuity, tangent_tolerance_degrees }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    if (document.features.some((feature) => feature.id === feature_id)) throw new Error(`duplicate_feature: '${feature_id}' already exists`);
    const sketch = featureById(document, sketch_id), profile = validateProfileSketch(sketch);
    if (sketch.kind !== "profile_sketch" || !profile.closed || profile.errors.length) throw new Error(`constraint_unsatisfied: ${profile.errors.join(" ")}`);
    const params = { path_segment_count: segments.length, twist_angle, scale_start, scale_end };
    storeSweepOrientation(params, frame_mode, up_direction, guide_points);
    params.continuity_mode = { position: 0, tangent: 1, curvature: 2 }[continuity]; params.tangent_tolerance = tangent_tolerance_degrees;
    storeSweepScaleStations(params, scale_stations); sweepScaleStationsFromParams(params);
    const inputIds = storeSweepProfileSections(document, sketch_id, profile_sections, params);
    segments.forEach((segment, index) => {
      params[`path_${index}_kind`] = segment.type === "line" ? 0 : 1;
      for (const role of segment.type === "line" ? ["start", "end"] : ["start", "mid", "end"]) {
        params[`path_${index}_${role}_x`] = segment[role].x;
        params[`path_${index}_${role}_y`] = segment[role].y;
        params[`path_${index}_${role}_z`] = segment[role].z;
      }
    });
    const validated = compositePathFromParams(params);
    validateCompositeContinuity(validated, params);
    const distance = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
    const guideLength = validated.reduce((sum, segment) => sum + (segment.type === "line" ? distance(segment.start, segment.end) : distance(segment.start, segment.mid) + distance(segment.mid, segment.end)), 0);
    inputIds.forEach((id) => { featureById(document, id).visible = false; });
    const feature = { id: feature_id, name: name.trim(), kind: "sweep_feature", visible: true, params, input_feature_ids: inputIds };
    document.features.push(feature);
    const operationId = recordOperation(document, { kind: "create_composite_sweep", feature_id, input_feature_ids: inputIds, segments, twist_angle, scale_start, scale_end, scale_stations, profile_sections, frame_mode, up_direction, guide_points, continuity, tangent_tolerance_degrees });
    await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, feature, profile_entity_count: profile.entity_count, segment_count: segments.length, guide_length: guideLength, scale_station_count: scale_stations.length, profile_section_count: profile_sections.length + 1 }, `Swept '${sketch.name}' along ${segments.length} connected line/arc guide segments through ${profile_sections.length + 1} profile shape(s) at revision ${document.revision}; the closed BRep mesh will stream into Metal.`);
  } catch (error) { return toolError(error, "Use a closed profile and 1-12 connected, nondegenerate line/arc segments with positive scales and the current revision."); }
});

server.registerTool("axis_cad_create_helix_sweep", {
  title: "Create Axis CAD Helix Sweep",
  description: "Sweep a closed profile along an editable helix with scale/morph stations, explicit section orientation, and an optional second guide rail.",
  inputSchema: {
    expected_revision: z.number().int().nonnegative(), feature_id: z.string().regex(/^[a-z][a-z0-9-]{1,63}$/), name: z.string().min(1).max(120), sketch_id: z.string().min(1),
    radius: z.number().positive(), pitch: z.number().positive(), turns: z.number().positive(), twist_angle: z.number().finite().default(0), scale_start: z.number().positive().default(1), scale_end: z.number().positive().default(1), scale_stations: z.array(sweepScaleStationSchema).max(8).default([]), profile_sections: z.array(sweepProfileSectionSchema).max(8).default([]),
    frame_mode: sweepFrameModeSchema.default("minimum_twist"), up_direction: selectionVectorSchema.default({ x: 0, y: 0, z: 1 }), guide_points: sweepGuidePointsSchema.default([])
  },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), feature: featureSchema, profile_entity_count: z.number(), path_length: z.number(), path_height: z.number(), scale_station_count: z.number(), profile_section_count: z.number() },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id, name, sketch_id, radius, pitch, turns, twist_angle, scale_start, scale_end, scale_stations, profile_sections, frame_mode, up_direction, guide_points }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    if (document.features.some((feature) => feature.id === feature_id)) throw new Error(`duplicate_feature: '${feature_id}' already exists`);
    const sketch = featureById(document, sketch_id), profile = validateProfileSketch(sketch);
    if (sketch.kind !== "profile_sketch" || !profile.closed || profile.errors.length) throw new Error(`constraint_unsatisfied: ${profile.errors.join(" ")}`);
    const pathHeight = pitch * turns, pathLength = Math.hypot(2 * Math.PI * radius * turns, pathHeight);
    const params = { helix_radius: radius, helix_pitch: pitch, helix_turns: turns, twist_angle, scale_start, scale_end };
    storeSweepOrientation(params, frame_mode, up_direction, guide_points);
    storeSweepScaleStations(params, scale_stations); sweepScaleStationsFromParams(params);
    const inputIds = storeSweepProfileSections(document, sketch_id, profile_sections, params);
    inputIds.forEach((id) => { featureById(document, id).visible = false; });
    const feature = { id: feature_id, name: name.trim(), kind: "sweep_feature", visible: true, params, input_feature_ids: inputIds };
    document.features.push(feature); const operationId = recordOperation(document, { kind: "create_helix_sweep", feature_id, input_feature_ids: inputIds, radius, pitch, turns, twist_angle, scale_start, scale_end, scale_stations, profile_sections, frame_mode, up_direction, guide_points }); await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, feature, profile_entity_count: profile.entity_count, path_length: pathLength, path_height: pathHeight, scale_station_count: scale_stations.length, profile_section_count: profile_sections.length + 1 }, `Swept '${sketch.name}' along a ${turns}-turn helix through ${profile_sections.length + 1} profile shape(s) at revision ${document.revision}; the curved kernel mesh will stream into Metal.`);
  } catch (error) { return toolError(error, "Use a closed profile and positive helix radius, pitch, turns, and scales with the current revision."); }
});

server.registerTool("axis_cad_create_loft", {
  title: "Create Axis CAD Loft",
  description: "Create a ruled BRep transition through two or more ordered closed profile sketches. Profile plane offsets position the sections; all source sketches remain reversible dependencies.",
  inputSchema: {
    expected_revision: z.number().int().nonnegative(), feature_id: z.string().regex(/^[a-z][a-z0-9-]{1,63}$/), name: z.string().min(1).max(120),
    sketch_ids: z.array(z.string().min(1)).min(2).max(8), closed: z.boolean().default(false)
  },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), feature: featureSchema, profile_count: z.number(), suppressed_feature_ids: z.array(z.string()) },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id, name, sketch_ids, closed }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    if (document.features.some((feature) => feature.id === feature_id)) throw new Error(`duplicate_feature: '${feature_id}' already exists`);
    const uniqueIds = [...new Set(sketch_ids)];
    if (uniqueIds.length < 2 || uniqueIds.length !== sketch_ids.length) throw new Error("invalid_dependency: loft requires at least two distinct ordered sketches");
    const sketches = uniqueIds.map((id) => featureById(document, id));
    for (const sketch of sketches) {
      const profile = validateProfileSketch(sketch);
      if (sketch.kind !== "profile_sketch" || !profile.closed || profile.errors.length) throw new Error(`constraint_unsatisfied: '${sketch.id}' must contain one closed profile`);
      sketch.visible = false;
    }
    const feature = { id: feature_id, name: name.trim(), kind: "loft_feature", visible: true, params: { closed: closed ? 1 : 0 }, input_feature_ids: uniqueIds };
    document.features.push(feature); const operationId = recordOperation(document, { kind: "create_loft", feature_id, input_feature_ids: uniqueIds, closed }); await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, feature, profile_count: uniqueIds.length, suppressed_feature_ids: uniqueIds }, `Lofted ${uniqueIds.length} profiles into '${feature.name}' at revision ${document.revision}; the kernel mesh will stream into Metal.`);
  } catch (error) { return toolError(error, "Use two or more distinct closed profile sketches with compatible ordered segments."); }
});

server.registerTool("axis_cad_set_parameter", {
  title: "Set Axis CAD Parameter",
  description: "Change one existing numeric feature parameter. Uses optimistic revision control and updates the native Metal viewport through the shared document.",
  inputSchema: {
    expected_revision: z.number().int().nonnegative().describe("Revision returned by axis_cad_get_document"),
    feature_id: z.string().min(1).describe("Stable feature ID"),
    parameter: z.string().min(1).describe("Existing parameter key"),
    value: z.number().finite().describe("New value in document units; dimensions must be positive while x/y/z transforms may be signed")
  },
  outputSchema: { ok: z.boolean(), revision: z.number(), feature_id: z.string(), parameter: z.string(), previous_value: z.number(), value: z.number(), operation_id: z.string() },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id, parameter, value }) => {
  try {
    const document = await loadDocument();
    assertRevision(document, expected_revision);
    const feature = featureById(document, feature_id);
    if (!(parameter in feature.params)) throw new Error(`invalid_parameter: '${parameter}' is not defined on '${feature_id}'`);
    if (feature.kind === "sweep_feature" && ((feature.params.path_point_count !== undefined && parameter === "path_point_count") || (feature.params.path_segment_count !== undefined && (parameter === "path_segment_count" || /^path_\d+_kind$/.test(parameter))))) throw new Error("invalid_parameter: guide topology is fixed; recreate the sweep to change segment count or type");
    if (feature.kind === "sweep_feature" && parameter === "scale_station_count") throw new Error("invalid_parameter: scale station count is fixed; recreate the sweep to change its profile topology");
    if (feature.kind === "sweep_feature" && parameter === "profile_station_count") throw new Error("invalid_parameter: morph section count is fixed; recreate the sweep to change section topology");
    assertAssemblyInstanceEditable(document, feature, parameter);
    assertValidParameter(value, parameter);
    const previousValue = feature.params[parameter];
    setFeatureParameter(feature, parameter, value);
    assertFeatureParameters(feature.kind, feature.params);
    const operationId = recordOperation(document, { kind: "set_parameter", feature_id, parameter, previous_value: previousValue, value });
    await saveDocument(document);
    const payload = { ok: true, revision: document.revision, feature_id, parameter, previous_value: previousValue, value, operation_id: operationId };
    return result(payload, `Updated ${feature.name}.${parameter}: ${previousValue} ${document.units} → ${value} ${document.units}. Native document revision is now ${document.revision}.`);
  } catch (error) { return toolError(error); }
});

server.registerTool("axis_cad_transform_feature", {
  title: "Transform Axis CAD Feature",
  description: "Atomically move one native box, cylinder, cone, sphere, or torus to an absolute x/y/z position. Matches Option-drag in the Metal viewport and creates one undoable revision.",
  inputSchema: { expected_revision: z.number().int().nonnegative(), feature_id: z.string().min(1), x: z.number().finite(), y: z.number().finite(), z: z.number().finite() },
  outputSchema: {
    ok: z.boolean(), revision: z.number(), operation_id: z.string(), feature_id: z.string(),
    previous_position: z.object({ x: z.number(), y: z.number(), z: z.number() }), position: z.object({ x: z.number(), y: z.number(), z: z.number() })
  },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id, x, y, z: positionZ }) => {
  try {
    const document = await loadDocument();
    assertRevision(document, expected_revision);
    const feature = featureById(document, feature_id);
    if (!["box", "cylinder", "cone", "sphere", "torus", "body_transform", "assembly_instance"].includes(feature.kind)) throw new Error(`unsupported_edit: '${feature_id}' requires a directly transformable primitive, body transform, or assembly instance`);
    assertAssemblyInstanceEditable(document, feature);
    for (const key of ["x", "y", "z"]) if (!(key in feature.params)) throw new Error(`invalid_parameter: '${key}' is not defined on '${feature_id}'`);
    const previousPosition = { x: feature.params.x, y: feature.params.y, z: feature.params.z };
    feature.params.x = x; feature.params.y = y; feature.params.z = positionZ;
    const operationId = recordOperation(document, { kind: "transform_feature", feature_id, previous_position: previousPosition, position: { x, y, z: positionZ } });
    await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, feature_id, previous_position: previousPosition, position: { x, y, z: positionZ } }, `Moved '${feature.name}' to (${x}, ${y}, ${positionZ}) ${document.units}. Revision is now ${document.revision}.`);
  } catch (error) { return toolError(error); }
});

server.registerTool("axis_cad_rotate_feature", {
  title: "Rotate Axis CAD Feature",
  description: "Atomically rotate one native box, cylinder, cone, sphere, or torus to absolute world-axis Euler angles in degrees. Matches the Metal rotation-ring gizmo and creates one undoable revision.",
  inputSchema: { expected_revision: z.number().int().nonnegative(), feature_id: z.string().min(1), x_degrees: z.number().finite(), y_degrees: z.number().finite(), z_degrees: z.number().finite() },
  outputSchema: {
    ok: z.boolean(), revision: z.number(), operation_id: z.string(), feature_id: z.string(),
    previous_rotation: z.object({ x_degrees: z.number(), y_degrees: z.number(), z_degrees: z.number() }),
    rotation: z.object({ x_degrees: z.number(), y_degrees: z.number(), z_degrees: z.number() })
  },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id, x_degrees, y_degrees, z_degrees }) => {
  try {
    const document = await loadDocument();
    assertRevision(document, expected_revision);
    const feature = featureById(document, feature_id);
    if (!["box", "cylinder", "cone", "sphere", "torus", "body_transform", "assembly_instance"].includes(feature.kind)) throw new Error(`unsupported_edit: '${feature_id}' requires a directly rotatable primitive, body transform, or assembly instance`);
    assertAssemblyInstanceEditable(document, feature, "rotation_x");
    for (const key of ["rotation_x", "rotation_y", "rotation_z"]) if (!(key in feature.params)) throw new Error(`invalid_parameter: '${key}' is not defined on '${feature_id}'`);
    const previousRotation = { x_degrees: feature.params.rotation_x, y_degrees: feature.params.rotation_y, z_degrees: feature.params.rotation_z };
    const rotation = { x_degrees, y_degrees, z_degrees };
    feature.params.rotation_x = x_degrees; feature.params.rotation_y = y_degrees; feature.params.rotation_z = z_degrees;
    const operationId = recordOperation(document, { kind: "rotate_feature", feature_id, previous_rotation: previousRotation, rotation });
    await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, feature_id, previous_rotation: previousRotation, rotation }, `Rotated '${feature.name}' to (${x_degrees}°, ${y_degrees}°, ${z_degrees}°). Revision is now ${document.revision}.`);
  } catch (error) { return toolError(error); }
});

server.registerTool("axis_cad_create_body_transform", {
  title: "Create Axis CAD Move Body Feature",
  description: "Create a reversible kernel-backed body_transform over one primitive or derived solid, suppressing the source while preserving it as a dependency. Translation is in document units, rotation is in world-axis degrees, and scale is positive per world axis.",
  inputSchema: {
    expected_revision: z.number().int().nonnegative(), feature_id: z.string().regex(/^[a-z][a-z0-9-]{1,63}$/), name: z.string().min(1).max(120), input_feature_id: z.string().min(1),
    x: z.number().finite().default(0), y: z.number().finite().default(0), z: z.number().finite().default(0),
    x_degrees: z.number().finite().default(0), y_degrees: z.number().finite().default(0), z_degrees: z.number().finite().default(0),
    x_scale: z.number().positive().finite().default(1), y_scale: z.number().positive().finite().default(1), z_scale: z.number().positive().finite().default(1)
  },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), feature: featureSchema, suppressed_feature_ids: z.array(z.string()) },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id, name, input_feature_id, x, y, z: positionZ, x_degrees, y_degrees, z_degrees, x_scale, y_scale, z_scale }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    if (document.features.some((feature) => feature.id === feature_id)) throw new Error(`duplicate_feature: '${feature_id}' already exists`);
    const input = featureById(document, input_feature_id);
    if (!bodyTransformSourceKinds.has(input.kind) || input.kind === "body_transform") throw new Error(`unsupported_kernel_feature: '${input_feature_id}' must be an untransformed primitive or kernel-derived body`);
    const params = { x, y, z: positionZ, rotation_x: x_degrees, rotation_y: y_degrees, rotation_z: z_degrees, scale_x: x_scale, scale_y: y_scale, scale_z: z_scale };
    assertFeatureParameters("body_transform", params);
    input.visible = false;
    const feature = { id: feature_id, name: name.trim(), kind: "body_transform", visible: true, params, input_feature_ids: [input_feature_id] };
    document.features.push(feature);
    const operationId = recordOperation(document, { kind: "create_body_transform", feature_id, input_feature_ids: feature.input_feature_ids, pose: params });
    await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, feature, suppressed_feature_ids: [input_feature_id] }, `Created reversible Move Body feature '${feature.name}' at revision ${document.revision}; the external kernel will rebuild it for Metal and STEP.`);
  } catch (error) { return toolError(error, "Inspect the current feature tree and retry with an untransformed solid source plus a unique transform feature ID."); }
});

server.registerTool("axis_cad_scale_feature", {
  title: "Scale Axis CAD Body",
  description: "Atomically set the positive world-axis scale of a body_transform. Create a body_transform first when scaling a primitive or derived source. Matches the native Scale gizmo and creates one undoable revision.",
  inputSchema: {
    expected_revision: z.number().int().nonnegative(), feature_id: z.string().min(1),
    x_scale: z.number().positive().finite(), y_scale: z.number().positive().finite(), z_scale: z.number().positive().finite()
  },
  outputSchema: {
    ok: z.boolean(), revision: z.number(), operation_id: z.string(), feature_id: z.string(),
    previous_scale: z.object({ x_scale: z.number(), y_scale: z.number(), z_scale: z.number() }),
    scale: z.object({ x_scale: z.number(), y_scale: z.number(), z_scale: z.number() })
  },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id, x_scale, y_scale, z_scale }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    const feature = featureById(document, feature_id);
    if (!["body_transform", "assembly_instance"].includes(feature.kind)) throw new Error(`unsupported_edit: '${feature_id}' must be a body_transform or assembly instance before scaling`);
    assertAssemblyInstanceEditable(document, feature, "scale_x");
    const previousScale = { x_scale: feature.params.scale_x ?? 1, y_scale: feature.params.scale_y ?? 1, z_scale: feature.params.scale_z ?? 1 };
    const scale = { x_scale, y_scale, z_scale };
    feature.params.scale_x = x_scale; feature.params.scale_y = y_scale; feature.params.scale_z = z_scale;
    const operationId = recordOperation(document, { kind: "scale_feature", feature_id, previous_scale: previousScale, scale });
    await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, feature_id, previous_scale: previousScale, scale }, `Scaled '${feature.name}' to (${x_scale}×, ${y_scale}×, ${z_scale}×). Revision is now ${document.revision}.`);
  } catch (error) { return toolError(error, "Create a body_transform over the solid first, then retry with positive scale factors and the current revision."); }
});

server.registerTool("axis_cad_get_assembly", {
  title: "Inspect Axis CAD Assembly",
  description: "Return assembly instances, their source parts and solved poses, mates, grounding state, and remaining rigid-body degrees of freedom.",
  inputSchema: {},
  outputSchema: {
    revision: z.number(), instance_count: z.number(), mate_count: z.number(),
    instances: z.array(z.object({ id: z.string(), name: z.string(), source_feature_id: z.string(), visible: z.boolean(), fixed: z.boolean(), driven_by: z.string().nullable(), driving_mate_ids: z.array(z.string()), degrees_of_freedom: z.number(), position: selectionVectorSchema, rotation: selectionVectorSchema, scale: selectionVectorSchema })),
    mates: z.array(z.object({ id: z.string(), name: z.string(), type: z.string(), reference_instance_id: z.string().nullable(), moving_instance_id: z.string() }))
  },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async () => {
  try {
    const document = await loadDocument();
    const mates = document.features.filter((feature) => feature.kind === "assembly_mate");
    const instances = document.features.filter((feature) => feature.kind === "assembly_instance").map((instance) => {
      const positionMate = assemblyPositionMateDriving(document, instance.id), orientationMate = assemblyOrientationMateDriving(document, instance.id), driving = assemblyMatesDriving(document, instance.id);
      const degrees = instance.params.fixed === 1 ? 0 : positionMate?.params.mate_type === 3 ? 1 : positionMate?.params.mate_type === 4 ? 2 : 6 - (positionMate ? 3 : 0) - (orientationMate ? 2 : 0);
      return { id: instance.id, name: instance.name, source_feature_id: instance.input_feature_ids?.[0] ?? "", visible: instance.visible, fixed: instance.params.fixed === 1, driven_by: driving[0]?.id ?? null, driving_mate_ids: driving.map((mate) => mate.id), degrees_of_freedom: degrees,
        position: { x: instance.params.x, y: instance.params.y, z: instance.params.z }, rotation: { x: instance.params.rotation_x, y: instance.params.rotation_y, z: instance.params.rotation_z }, scale: { x: instance.params.scale_x, y: instance.params.scale_y, z: instance.params.scale_z } };
    });
    const resolvedMates = mates.map((mate) => ({ id: mate.id, name: mate.name, type: mate.params.mate_type === 0 ? "fixed" : mate.params.mate_type === 2 ? "distance" : mate.params.mate_type === 3 ? "plane" : mate.params.mate_type === 4 ? "concentric" : mate.params.mate_type === 5 ? "angle" : "coincident", reference_instance_id: mate.params.mate_type === 0 ? null : mate.input_feature_ids?.[0] ?? null, moving_instance_id: mate.params.mate_type === 0 ? mate.input_feature_ids?.[0] ?? "" : mate.input_feature_ids?.[1] ?? "" }));
    return result({ revision: document.revision, instance_count: instances.length, mate_count: mates.length, instances, mates: resolvedMates }, `Assembly contains ${instances.length} instance(s), ${mates.length} mate(s), and ${instances.reduce((sum, instance) => sum + instance.degrees_of_freedom, 0)} remaining rigid-body DOF.`);
  } catch (error) { return toolError(error); }
});

server.registerTool("axis_cad_set_material", {
  title: "Set Axis CAD Part Material",
  description: "Assign a lightweight manufacturing material preset to a reusable source part (or the source behind an instance), including density for mass rollups and native Metal color.",
  inputSchema: { expected_revision: z.number().int().nonnegative(), feature_id: z.string().min(1), material: z.enum(["unassigned", "aluminum_6061", "mild_steel", "stainless_steel", "titanium", "abs_plastic"]) },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), source_feature_id: z.string(), material: z.string(), density_g_per_mm3: z.number() },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id, material }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    const selected = featureById(document, feature_id), source = selected.kind === "assembly_instance" ? featureById(document, selected.input_feature_ids?.[0] ?? "") : selected;
    if (!bodyTransformSourceKinds.has(source.kind) || ["assembly_instance", "assembly_mate"].includes(source.kind)) throw new Error(`invalid_reference: '${feature_id}' does not resolve to a reusable solid source`);
    const preset = materialPresets[material], previous = source.params.material_id ?? 0;
    if (preset.id === 0) for (const key of ["material_id", "density", "color_r", "color_g", "color_b"]) delete source.params[key];
    else Object.assign(source.params, { material_id: preset.id, density: preset.density, color_r: preset.color[0], color_g: preset.color[1], color_b: preset.color[2] });
    const operationId = recordOperation(document, { kind: "set_material", feature_id: source.id, parameter: "material_id", previous_value: previous, value: preset.id }); await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, source_feature_id: source.id, material, density_g_per_mm3: preset.density }, `Assigned ${material.replaceAll("_", " ")} to '${source.name}' at revision ${document.revision}; native Metal and assembly mass rollups will update.`);
  } catch (error) { return toolError(error, "Choose a reusable solid source or one of its assembly instances and pass the current revision."); }
});

server.registerTool("axis_cad_get_bom", {
  title: "Get Axis CAD Bill of Materials",
  description: "Group assembly instances by their source part and report a lightweight revision-scoped bill of materials.",
  inputSchema: {},
  outputSchema: { revision: z.number(), total_instances: z.number(), unique_parts: z.number(), assigned_mass_instances: z.number(), total_mass_grams: z.number(), items: z.array(z.object({ part_number: z.string(), description: z.string(), quantity: z.number(), material: z.string(), density_g_per_mm3: z.number().nullable(), exact_volume_mm3: z.number().nullable(), unit_mass_grams: z.number().nullable(), total_mass_grams: z.number().nullable() })) },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async (_, { signal }) => {
  try {
    const document = await loadDocument(), grouped = new Map();
    // Hidden occurrences represent alternate configurations or suppressed
    // layouts. They are intentionally excluded from the active BOM because the
    // kernel rejects hidden bodies and, more importantly, they are not part of
    // the currently manufacturable assembly configuration.
    for (const instance of document.features.filter((feature) => feature.kind === "assembly_instance" && feature.visible)) {
      const sourceId = instance.input_feature_ids?.[0] ?? "missing-source", source = document.features.find((feature) => feature.id === sourceId);
      const item = grouped.get(sourceId) ?? { part_number: sourceId, description: source?.name ?? sourceId, quantity: 0, source, instance_ids: [] };
      item.quantity += 1; item.instance_ids.push(instance.id); grouped.set(sourceId, item);
    }
    const items = [];
    for (const item of [...grouped.values()].sort((a, b) => a.part_number.localeCompare(b.part_number))) {
      const materialId = item.source?.params.material_id ?? 0, density = item.source?.params.density ?? 0;
      let volume = null, unitMass = null, totalMass = null;
      if (materialId > 0 && density > 0) {
        const validations = await Promise.all(item.instance_ids.map((instanceId) => validateWithKernel(document, instanceId, signal)));
        const aggregateVolume = validations.reduce((sum, validation) => sum + validation.volume, 0);
        volume = aggregateVolume / item.quantity; unitMass = volume * density; totalMass = aggregateVolume * density;
      }
      items.push({ part_number: item.part_number, description: item.description, quantity: item.quantity, material: materialName(materialId), density_g_per_mm3: density > 0 ? density : null, exact_volume_mm3: volume, unit_mass_grams: unitMass, total_mass_grams: totalMass });
    }
    const totalInstances = items.reduce((sum, item) => sum + item.quantity, 0);
    const assignedMassInstances = items.reduce((sum, item) => sum + (item.total_mass_grams == null ? 0 : item.quantity), 0), totalMass = items.reduce((sum, item) => sum + (item.total_mass_grams ?? 0), 0);
    return result({ revision: document.revision, total_instances: totalInstances, unique_parts: items.length, assigned_mass_instances: assignedMassInstances, total_mass_grams: totalMass, items }, `BOM has ${items.length} unique part(s), ${totalInstances} instance(s), and ${totalMass.toFixed(3)} g assigned exact-kernel mass.`);
  } catch (error) { return toolError(error); }
});

const sourcingCandidateSchema = z.object({
  id: z.string(), status: z.literal("candidate"), manufacturer: z.string(), part_number: z.string(), description: z.string(),
  source_url: z.string().url(), retrieved_at: z.string(), category: z.enum(["actuator", "display_mount", "cable_carrier", "rail", "caster", "fastener", "other"]),
  interface_notes: z.string(), load_rating_n: z.number().nonnegative().nullable(), display_mass_kg: z.number().nonnegative().nullable(),
  stroke_mm: z.number().nonnegative().nullable(), voltage_v: z.number().nonnegative().nullable(), license_notes: z.string()
});

server.registerTool("axis_cad_add_sourcing_candidate", {
  title: "Add Axis CAD Sourcing Candidate",
  description: "Store a dated, research-only supplier candidate for the active project. This never purchases, requests a quote, changes a released BOM, or approves a safety-critical part.",
  inputSchema: {
    id: z.string().regex(/^[a-z][a-z0-9-]{1,63}$/), manufacturer: z.string().min(1), part_number: z.string().min(1), description: z.string().min(1), source_url: z.string().url(),
    category: z.enum(["actuator", "display_mount", "cable_carrier", "rail", "caster", "fastener", "other"]), interface_notes: z.string().min(1),
    load_rating_n: z.number().nonnegative().nullable().default(null), display_mass_kg: z.number().nonnegative().nullable().default(null), stroke_mm: z.number().nonnegative().nullable().default(null), voltage_v: z.number().nonnegative().nullable().default(null), license_notes: z.string().min(1)
  },
  outputSchema: sourcingCandidateSchema,
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true }
}, async (input) => {
  try {
    const candidates = await loadSourcingCandidates();
    if (candidates.some((candidate) => candidate.id === input.id)) throw new Error(`duplicate_candidate: '${input.id}' already exists`);
    const candidate = { ...input, status: "candidate", retrieved_at: new Date().toISOString() };
    await saveSourcingCandidates([...candidates, candidate]);
    return result(candidate, `Added research-only sourcing candidate '${candidate.part_number}'. Engineering review is still required before approval or purchase.`);
  } catch (error) { return toolError(error, "Use a unique candidate ID and a direct manufacturer or distributor URL."); }
});

server.registerTool("axis_cad_list_sourcing_candidates", {
  title: "List Axis CAD Sourcing Candidates",
  description: "List research-only supplier candidates stored locally for the active project. Candidate status is never an approval or purchasing instruction.",
  inputSchema: {},
  outputSchema: { count: z.number(), candidates: z.array(sourcingCandidateSchema) },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async () => {
  try { const candidates = await loadSourcingCandidates(); return result({ count: candidates.length, candidates }, `${candidates.length} research-only sourcing candidate(s) recorded.`); }
  catch (error) { return toolError(error); }
});

server.registerTool("axis_cad_validate_sourcing_candidate", {
  title: "Validate Candidate Interface Against Axis CAD",
  description: "Perform a declared-data compatibility screen against a CAD feature. It flags missing ratings and never certifies structural safety, purchases a part, or substitutes a released BOM item.",
  inputSchema: { candidate_id: z.string().min(1), feature_id: z.string().min(1), required_load_n: z.number().nonnegative().default(0), required_stroke_mm: z.number().nonnegative().default(0), required_voltage_v: z.number().nonnegative().default(0) },
  outputSchema: { candidate_id: z.string(), feature_id: z.string(), compatible: z.boolean(), warnings: z.array(z.string()) },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async ({ candidate_id, feature_id, required_load_n, required_stroke_mm, required_voltage_v }) => {
  try {
    const candidate = (await loadSourcingCandidates()).find((item) => item.id === candidate_id);
    const document = await loadDocument(); featureById(document, feature_id);
    if (!candidate) throw new Error(`invalid_reference: sourcing candidate '${candidate_id}' does not exist`);
    const warnings = [];
    if (required_load_n && candidate.load_rating_n == null) warnings.push("candidate has no declared load rating");
    else if (candidate.load_rating_n != null && candidate.load_rating_n < required_load_n) warnings.push(`declared load ${candidate.load_rating_n} N is below required ${required_load_n} N`);
    if (required_stroke_mm && candidate.stroke_mm == null) warnings.push("candidate has no declared stroke");
    else if (candidate.stroke_mm != null && candidate.stroke_mm < required_stroke_mm) warnings.push(`declared stroke ${candidate.stroke_mm} mm is below required ${required_stroke_mm} mm`);
    if (required_voltage_v && candidate.voltage_v != null && candidate.voltage_v !== required_voltage_v) warnings.push(`declared voltage ${candidate.voltage_v} V differs from required ${required_voltage_v} V`);
    if (candidate.category === "display_mount" && candidate.display_mass_kg == null) warnings.push("display-mount candidate has no declared display mass rating");
    warnings.push("screening is based only on declared supplier data; engineering, fatigue, stability, and certification review remain required");
    return result({ candidate_id, feature_id, compatible: warnings.length === 1, warnings }, warnings.length === 1 ? `Candidate '${candidate.part_number}' passes the declared-data screen only.` : `Candidate '${candidate.part_number}' has ${warnings.length - 1} compatibility warning(s).`);
  } catch (error) { return toolError(error, "Use an existing candidate ID and a current CAD feature ID."); }
});

server.registerTool("axis_cad_create_instance", {
  title: "Create Axis CAD Assembly Instance",
  description: "Create a reusable assembly occurrence of one solid-producing part with an independent GPU/BRep pose. The source part is retained once and may feed multiple instances.",
  inputSchema: {
    expected_revision: z.number().int().nonnegative(), feature_id: z.string().regex(/^[a-z][a-z0-9-]{1,63}$/), name: z.string().min(1).max(120), source_feature_id: z.string().min(1),
    position: selectionVectorSchema.default({ x: 0, y: 0, z: 0 }), rotation: selectionVectorSchema.default({ x: 0, y: 0, z: 0 }), scale: z.object({ x: z.number().positive(), y: z.number().positive(), z: z.number().positive() }).default({ x: 1, y: 1, z: 1 })
  },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), feature: featureSchema, source_feature_id: z.string() },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id, name, source_feature_id, position, rotation, scale }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    if (document.features.some((feature) => feature.id === feature_id)) throw new Error(`duplicate_feature: '${feature_id}' already exists`);
    const source = featureById(document, source_feature_id);
    if (!bodyTransformSourceKinds.has(source.kind) || ["assembly_instance", "assembly_mate"].includes(source.kind)) throw new Error(`unsupported_kernel_feature: '${source_feature_id}' is not a reusable solid part`);
    const params = { x: position.x, y: position.y, z: position.z, rotation_x: rotation.x, rotation_y: rotation.y, rotation_z: rotation.z, scale_x: scale.x, scale_y: scale.y, scale_z: scale.z, fixed: 0 };
    assertFeatureParameters("assembly_instance", params);
    source.visible = false;
    const feature = { id: feature_id, name: name.trim(), kind: "assembly_instance", visible: true, params, input_feature_ids: [source_feature_id] };
    document.features.push(feature); const operationId = recordOperation(document, { kind: "create_instance", feature_id, input_feature_ids: [source_feature_id], pose: params }); await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, feature, source_feature_id }, `Created assembly instance '${feature.name}' from '${source.name}' at revision ${document.revision}; it will stream into Metal as an independently placed BRep.`);
  } catch (error) { return toolError(error, "Choose a solid-producing source part, a unique instance ID, and the current revision."); }
});

server.registerTool("axis_cad_create_mate", {
  title: "Create Axis CAD Assembly Mate",
  description: "Ground an instance or create regenerative coincident, distance, plane, concentric, or angle mates. Angle mates are orientation-only and can compose with one translation mate.",
  inputSchema: {
    expected_revision: z.number().int().nonnegative(), feature_id: z.string().regex(/^[a-z][a-z0-9-]{1,63}$/), name: z.string().min(1).max(120), type: z.enum(["fixed", "coincident", "distance", "plane", "concentric", "angle"]),
    moving_instance_id: z.string().min(1), reference_instance_id: z.string().min(1).optional(), reference_anchor: selectionVectorSchema.default({ x: 0, y: 0, z: 0 }), moving_anchor: selectionVectorSchema.default({ x: 0, y: 0, z: 0 }), offset: selectionVectorSchema.default({ x: 0, y: 0, z: 0 }), axis: selectionVectorSchema.default({ x: 1, y: 0, z: 0 }), distance: z.number().nonnegative().default(10), reference_normal: selectionVectorSchema.default({ x: 0, y: 0, z: 1 }), moving_normal: selectionVectorSchema.default({ x: 0, y: 0, z: 1 }), hinge_axis: selectionVectorSchema.default({ x: 1, y: 0, z: 0 }), angle: z.number().min(0).max(180).default(90), reference_axis: selectionVectorSchema.default({ x: 0, y: 0, z: 1 }), moving_axis: selectionVectorSchema.default({ x: 0, y: 0, z: 1 }), axial_offset: z.number().default(0), opposed: z.boolean().default(false), spin: z.number().default(0)
  },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), feature: featureSchema, solved_position: selectionVectorSchema },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id, name, type, moving_instance_id, reference_instance_id, reference_anchor, moving_anchor, offset, axis, distance, reference_normal, moving_normal, hinge_axis, angle, reference_axis, moving_axis, axial_offset, opposed, spin }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    if (document.features.some((feature) => feature.id === feature_id)) throw new Error(`duplicate_feature: '${feature_id}' already exists`);
    const moving = featureById(document, moving_instance_id);
    if (moving.kind !== "assembly_instance") throw new Error(`invalid_reference: '${moving_instance_id}' is not an assembly instance`);
    let params, inputs;
    if (type === "fixed") {
      if (document.features.some((feature) => feature.kind === "assembly_mate" && feature.params.mate_type === 0 && feature.input_feature_ids?.[0] === moving_instance_id) || assemblyMatesDriving(document, moving_instance_id).length) throw new Error(`mate_conflict: '${moving_instance_id}' is already constrained`);
      params = { mate_type: 0 }; inputs = [moving_instance_id];
    } else {
      if (!reference_instance_id || reference_instance_id === moving_instance_id) throw new Error(`invalid_reference: ${type} mate requires two distinct instances`);
      const reference = featureById(document, reference_instance_id);
      if (reference.kind !== "assembly_instance") throw new Error(`invalid_reference: '${reference_instance_id}' is not an assembly instance`);
      const positionDriver = assemblyPositionMateDriving(document, moving_instance_id), orientationDriver = assemblyOrientationMateDriving(document, moving_instance_id);
      if (moving.params.fixed === 1 || (type === "angle" ? orientationDriver : positionDriver) || (["plane", "concentric"].includes(type) && orientationDriver)) throw new Error(`mate_conflict: '${moving_instance_id}' already has an incompatible mate driver`);
      const reachesReference = (start, seen = new Set()) => {
        if (start === reference_instance_id) return true; if (seen.has(start)) return false; seen.add(start);
        return document.features.filter((feature) => feature.kind === "assembly_mate" && [1, 2, 3, 4, 5].includes(feature.params.mate_type) && feature.input_feature_ids?.[0] === start).some((feature) => reachesReference(feature.input_feature_ids[1], seen));
      };
      if (reachesReference(moving_instance_id)) throw new Error(`mate_cycle: ${type} mate would create a cyclic assembly dependency`);
      const anchors = { reference_anchor_x: reference_anchor.x, reference_anchor_y: reference_anchor.y, reference_anchor_z: reference_anchor.z, moving_anchor_x: moving_anchor.x, moving_anchor_y: moving_anchor.y, moving_anchor_z: moving_anchor.z };
      params = type === "angle" ? { mate_type: 5, reference_normal_x: reference_normal.x, reference_normal_y: reference_normal.y, reference_normal_z: reference_normal.z, moving_normal_x: moving_normal.x, moving_normal_y: moving_normal.y, moving_normal_z: moving_normal.z, hinge_axis_x: hinge_axis.x, hinge_axis_y: hinge_axis.y, hinge_axis_z: hinge_axis.z, angle, spin } : type === "concentric" ? { mate_type: 4, ...anchors, reference_axis_x: reference_axis.x, reference_axis_y: reference_axis.y, reference_axis_z: reference_axis.z, moving_axis_x: moving_axis.x, moving_axis_y: moving_axis.y, moving_axis_z: moving_axis.z, axial_offset, opposed: opposed ? 1 : 0, spin } : type === "plane" ? { mate_type: 3, ...anchors, reference_normal_x: reference_normal.x, reference_normal_y: reference_normal.y, reference_normal_z: reference_normal.z, moving_normal_x: moving_normal.x, moving_normal_y: moving_normal.y, moving_normal_z: moving_normal.z, distance, opposed: opposed ? 1 : 0, spin } : type === "distance" ? { mate_type: 2, ...anchors, axis_x: axis.x, axis_y: axis.y, axis_z: axis.z, distance } : { mate_type: 1, ...anchors, offset_x: offset.x, offset_y: offset.y, offset_z: offset.z };
      inputs = [reference_instance_id, moving_instance_id];
    }
    assertFeatureParameters("assembly_mate", params);
    const feature = { id: feature_id, name: name.trim(), kind: "assembly_mate", visible: true, params, input_feature_ids: inputs };
    document.features.push(feature); const operationId = recordOperation(document, { kind: "create_mate", feature_id, type, input_feature_ids: inputs }); await saveDocument(document);
    const solvedPositionDriver = assemblyPositionMateDriving(document, moving_instance_id), solvedOrientationDriver = assemblyOrientationMateDriving(document, moving_instance_id);
    const dof = moving.params.fixed === 1 ? 0 : solvedPositionDriver?.params.mate_type === 3 ? 1 : solvedPositionDriver?.params.mate_type === 4 ? 2 : 6 - (solvedPositionDriver ? 3 : 0) - (solvedOrientationDriver ? 2 : 0);
    return result({ ok: true, revision: document.revision, operation_id: operationId, feature, solved_position: { x: moving.params.x, y: moving.params.y, z: moving.params.z } }, `Created ${type} mate '${feature.name}' at revision ${document.revision}; '${moving.name}' now has ${dof} rigid-body DOF.`);
  } catch (error) { return toolError(error, "Use assembly instances, avoid mate cycles or duplicate drivers, and pass the current revision."); }
});

server.registerTool("axis_cad_get_sketch", {
  title: "Inspect Axis CAD Sketch",
  description: "Read the solved base profile, hole centers, constraints, and degrees of freedom used by the native sketch workbench and solid mesh.",
  inputSchema: {},
  outputSchema: {
    feature_id: z.string(), plane: z.string(), profile: z.string(), width: z.number(), height: z.number(),
    hole_diameter: z.number(), hole_offset: z.number(), hole_centers: z.array(z.object({ id: z.string(), x: z.number(), y: z.number() })),
    constraint_count: z.number(), degrees_of_freedom: z.number(), fully_constrained: z.boolean(), errors: z.array(z.string())
  },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async () => {
  try { return result(solveSketch(await loadDocument())); }
  catch (error) { return toolError(error, "Create or restore the sketch-base and pocket-holes features, then retry."); }
});

server.registerTool("axis_cad_set_sketch_dimensions", {
  title: "Set Axis CAD Sketch Dimensions",
  description: "Atomically solve the centered plate profile and four symmetric mounting holes from width, height, equal diameter, and edge offset. Matches the native sketch editor.",
  inputSchema: {
    expected_revision: z.number().int().nonnegative(), width: z.number().positive(), height: z.number().positive(),
    hole_diameter: z.number().positive(), hole_offset: z.number().positive()
  },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), sketch: z.object({
    feature_id: z.string(), plane: z.string(), profile: z.string(), width: z.number(), height: z.number(), hole_diameter: z.number(), hole_offset: z.number(),
    hole_centers: z.array(z.object({ id: z.string(), x: z.number(), y: z.number() })), constraint_count: z.number(), degrees_of_freedom: z.number(), fully_constrained: z.boolean(), errors: z.array(z.string())
  }) },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, width, height, hole_diameter, hole_offset }) => {
  try {
    const active = await loadDocument();
    assertRevision(active, expected_revision);
    const document = structuredClone(active);
    featureById(document, "sketch-base").params = { ...featureById(document, "sketch-base").params, width, height };
    featureById(document, "pocket-holes").params = { ...featureById(document, "pocket-holes").params, diameter: hole_diameter, offset: hole_offset };
    const sketch = solveSketch(document);
    if (sketch.errors.length) throw new Error(`constraint_conflict: ${sketch.errors.join(" ")}`);
    const operationId = recordOperation(document, { kind: "solve_sketch", feature_id: "sketch-base", dimensions: { width, height, hole_diameter, hole_offset } });
    await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, sketch }, `Solved the mounting plate sketch at revision ${document.revision}; ${sketch.constraint_count} constraints, 0 degrees of freedom.`);
  } catch (error) { return toolError(error); }
});

server.registerTool("axis_cad_validate_sketch", {
  title: "Validate Axis CAD Sketch",
  description: "Check the active sketch constraints and report conflicts or remaining degrees of freedom without changing the document.",
  inputSchema: {},
  outputSchema: { ok: z.boolean(), revision: z.number(), fully_constrained: z.boolean(), degrees_of_freedom: z.number(), errors: z.array(z.string()) },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async () => {
  try {
    const document = await loadDocument(); const sketch = solveSketch(document);
    return result({ ok: sketch.errors.length === 0, revision: document.revision, fully_constrained: sketch.fully_constrained, degrees_of_freedom: sketch.degrees_of_freedom, errors: sketch.errors });
  } catch (error) { return toolError(error, "Create or restore the sketch-base and pocket-holes features, then retry."); }
});

server.registerTool("axis_cad_apply_edits", {
  title: "Apply Atomic Axis CAD Edits",
  description: "Atomically apply up to 50 parameter, rename, or visibility edits. All edits validate before the shared document is replaced; one failure leaves it unchanged.",
  inputSchema: {
    expected_revision: z.number().int().nonnegative(),
    edits: z.array(z.object({
      action: z.enum(["set_parameter", "rename_feature", "set_visibility"]),
      feature_id: z.string().min(1), parameter: z.string().optional(), value: z.number().optional(),
      name: z.string().max(120).optional(), visible: z.boolean().optional()
    }).strict()).min(1).max(50)
  },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), edits_applied: z.number(), changes: z.array(z.record(z.string(), z.union([z.string(), z.number(), z.boolean()]))) },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, edits }) => {
  try {
    const active = await loadDocument();
    assertRevision(active, expected_revision);
    const document = structuredClone(active);
    const changes = edits.map((edit) => applyEdit(document, edit));
    const operationId = recordOperation(document, { kind: "apply_edits", changes });
    await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, edits_applied: changes.length, changes }, `Applied ${changes.length} edit(s) atomically. Native document revision is now ${document.revision}.`);
  } catch (error) { return toolError(error); }
});

server.registerTool("axis_cad_create_feature", {
  title: "Create Axis CAD Feature",
  description: "Add a named parametric feature to the native document. Supported generic kinds are sketch, pad, pocket, fillet, chamfer, shell, pattern, primitive, revolve, sweep, and loft.",
  inputSchema: {
    expected_revision: z.number().int().nonnegative(),
    feature_id: z.string().regex(/^[a-z][a-z0-9-]{1,63}$/),
    name: z.string().min(1).max(120),
    kind: z.enum(["sketch", "pad", "pocket", "fillet", "chamfer", "shell", "pattern", "primitive", "box", "cylinder", "cone", "sphere", "torus", "revolve", "sweep", "loft"]),
    params: z.record(z.string(), z.number().finite())
  },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), feature: featureSchema },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id, name, kind, params }) => {
  try {
    const document = await loadDocument();
    assertRevision(document, expected_revision);
    if (document.features.some((feature) => feature.id === feature_id)) throw new Error(`duplicate_feature: '${feature_id}' already exists`);
    const normalizedParams = ["box", "cylinder", "cone", "sphere", "torus"].includes(kind)
      ? { rotation_x: 0, rotation_y: 0, rotation_z: 0, ...params }
      : params;
    for (const [key, value] of Object.entries(normalizedParams)) assertValidParameter(value, key);
    assertFeatureParameters(kind, normalizedParams);
    const feature = { id: feature_id, name: name.trim(), kind, visible: true, params: normalizedParams };
    document.features.push(feature);
    const operationId = recordOperation(document, { kind: "create_feature", feature_id, feature_kind: kind });
    await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, feature }, `Created ${kind} feature '${name}' at revision ${document.revision}.`);
  } catch (error) { return toolError(error); }
});

server.registerTool("axis_cad_create_boolean", {
  title: "Create Axis CAD Boolean Feature",
  description: "Create a dependency-aware union, difference, or intersection from two existing bodies. Inputs are suppressed, the external kernel rebuilds the result for Metal, and one undoable revision is committed.",
  inputSchema: {
    expected_revision: z.number().int().nonnegative(), feature_id: z.string().regex(/^[a-z][a-z0-9-]{1,63}$/), name: z.string().min(1).max(120),
    operation: z.enum(["union", "difference", "intersection"]), left_feature_id: z.string().min(1), right_feature_id: z.string().min(1)
  },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), feature: featureSchema, suppressed_feature_ids: z.array(z.string()) },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id, name, operation, left_feature_id, right_feature_id }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    if (document.features.some((feature) => feature.id === feature_id)) throw new Error(`duplicate_feature: '${feature_id}' already exists`);
    if (left_feature_id === right_feature_id) throw new Error("invalid_dependency: boolean inputs must be different features");
    const left = featureById(document, left_feature_id), right = featureById(document, right_feature_id);
    const supported = new Set(["pad", "pocket", "box", "cylinder", "cone", "sphere", "torus", ...kernelDerivedKinds]);
    if (!supported.has(left.kind) || !supported.has(right.kind)) throw new Error("unsupported_kernel_feature: boolean inputs must be solid-producing features");
    const suppressed = new Set();
    for (const input of [left, right]) {
      const ids = ["sketch-base", "pad-base", "pocket-holes", "fillet-edges"].includes(input.id)
        ? ["sketch-base", "pad-base", "pocket-holes", "fillet-edges"] : [input.id];
      for (const id of ids) { const candidate = document.features.find((feature) => feature.id === id); if (candidate) { candidate.visible = false; suppressed.add(id); } }
    }
    const feature = { id: feature_id, name: name.trim(), kind: `boolean_${operation}`, visible: true, params: {}, input_feature_ids: [left_feature_id, right_feature_id] };
    document.features.push(feature);
    const operationId = recordOperation(document, { kind: "create_boolean", feature_id, boolean_operation: operation, input_feature_ids: feature.input_feature_ids });
    await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, feature, suppressed_feature_ids: [...suppressed] }, `Created ${operation} '${feature.name}' from '${left.name}' and '${right.name}' at revision ${document.revision}. The native app will stream the kernel mesh into Metal.`);
  } catch (error) { return toolError(error, "Inspect the current feature tree and retry with two distinct solid-producing feature IDs."); }
});

server.registerTool("axis_cad_create_modifier", {
  title: "Create Axis CAD Modifier Feature",
  description: "Create an editable fillet, chamfer, shell, linear pattern, or circular pattern over one existing solid. Fillet/chamfer edges can use a stable topology edge ID with adjacent-face verification and a point fallback, a face-constrained point, or a direction.",
  inputSchema: {
    expected_revision: z.number().int().nonnegative(), feature_id: z.string().regex(/^[a-z][a-z0-9-]{1,63}$/), name: z.string().min(1).max(120),
    modifier: z.enum(["edge_fillet", "edge_chamfer", "shell_feature", "linear_pattern", "circular_pattern"]), input_feature_id: z.string().min(1),
    params: z.record(z.string(), z.number().finite()).optional(),
    edge_selector: z.discriminatedUnion("type", [
      z.object({ type: z.literal("all") }),
      z.object({ type: z.literal("topology"), edge_id: z.number().int().nonnegative(), adjacent_face_ids: z.array(z.number().int().nonnegative()).length(2), fallback_point: selectionVectorSchema, topology_face_id: z.number().int().nonnegative() }),
      z.object({ type: z.literal("near"), point: selectionVectorSchema, topology_face_id: z.number().int().nonnegative().optional() }),
      z.object({ type: z.literal("direction"), axis: selectionVectorSchema, tolerance_degrees: z.number().positive().max(90).default(10) })
    ]).optional()
  },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), feature: featureSchema, suppressed_feature_ids: z.array(z.string()) },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id, name, modifier, input_feature_id, params, edge_selector }) => {
  try {
    const document = await loadDocument(); assertRevision(document, expected_revision);
    if (document.features.some((feature) => feature.id === feature_id)) throw new Error(`duplicate_feature: '${feature_id}' already exists`);
    const input = featureById(document, input_feature_id);
    const supported = new Set(["pad", "pocket", "fillet", "box", "cylinder", "cone", "sphere", "torus", ...kernelDerivedKinds]);
    if (!supported.has(input.kind)) throw new Error(`unsupported_kernel_feature: '${input_feature_id}' is not a solid-producing feature`);
    if (edge_selector && !["edge_fillet", "edge_chamfer"].includes(modifier)) throw new Error("invalid_parameters: edge_selector is only valid for fillet or chamfer");
    const selectorParams = !edge_selector ? {} : edge_selector.type === "all" ? { selector_mode: 0 }
      : edge_selector.type === "topology" ? { selector_mode: 3, selector_edge_id: edge_selector.edge_id, selector_edge_face_a: Math.min(...edge_selector.adjacent_face_ids), selector_edge_face_b: Math.max(...edge_selector.adjacent_face_ids), selector_x: edge_selector.fallback_point.x, selector_y: edge_selector.fallback_point.y, selector_z: edge_selector.fallback_point.z, selector_face_id: edge_selector.topology_face_id, selector_tolerance: 10 }
      : edge_selector.type === "near" ? { selector_mode: 1, selector_x: edge_selector.point.x, selector_y: edge_selector.point.y, selector_z: edge_selector.point.z, selector_tolerance: 10, ...(edge_selector.topology_face_id === undefined ? {} : { selector_face_id: edge_selector.topology_face_id }) }
      : { selector_mode: 2, selector_x: edge_selector.axis.x, selector_y: edge_selector.axis.y, selector_z: edge_selector.axis.z, selector_tolerance: edge_selector.tolerance_degrees };
    const resolvedParams = { ...modifierDefaults(modifier), ...(params || {}), ...selectorParams };
    for (const [key, value] of Object.entries(resolvedParams)) assertValidParameter(value, key);
    assertModifierParameters(modifier, resolvedParams);
    const suppressed = [];
    const ids = ["sketch-base", "pad-base", "pocket-holes", "fillet-edges"].includes(input_feature_id)
      ? ["sketch-base", "pad-base", "pocket-holes", "fillet-edges"] : [input_feature_id];
    for (const id of ids) { const candidate = document.features.find((feature) => feature.id === id); if (candidate) { candidate.visible = false; suppressed.push(id); } }
    const feature = { id: feature_id, name: name.trim(), kind: modifier, visible: true, params: resolvedParams, input_feature_ids: [input_feature_id] };
    document.features.push(feature);
    const operationId = recordOperation(document, { kind: "create_modifier", feature_id, modifier, input_feature_ids: feature.input_feature_ids });
    await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, feature, suppressed_feature_ids: suppressed }, `Created '${feature.name}' from '${input.name}' at revision ${document.revision}; the kernel result will stream into Metal.`);
  } catch (error) { return toolError(error, "Inspect the source feature and retry with valid modifier parameters."); }
});

server.registerTool("axis_cad_delete_feature", {
  title: "Delete Axis CAD Feature",
  description: "Permanently remove one feature from the active document. Requires confirm=true. Create a checkpoint first when the feature matters.",
  inputSchema: { expected_revision: z.number().int().nonnegative(), feature_id: z.string().min(1), confirm: z.literal(true) },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), deleted_feature_id: z.string() },
  annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, feature_id }) => {
  try {
    const document = await loadDocument();
    assertRevision(document, expected_revision);
    const index = document.features.findIndex((feature) => feature.id === feature_id);
    if (index < 0) throw new Error(`invalid_reference: feature '${feature_id}' does not exist`);
    const dependent = document.features.find((feature) => (feature.input_feature_ids || []).includes(feature_id));
    if (dependent) throw new Error(`dependency_conflict: '${feature_id}' is used by '${dependent.id}'; delete the dependent feature first`);
    const [removed] = document.features.splice(index, 1);
    for (const inputId of removed.kind === "assembly_mate" ? [] : removed.input_feature_ids || []) {
      if (removed.kind === "assembly_instance" && document.features.some((feature) => feature.kind === "assembly_instance" && feature.input_feature_ids?.[0] === inputId)) continue;
      const ids = ["sketch-base", "pad-base", "pocket-holes", "fillet-edges"].includes(inputId)
        ? ["sketch-base", "pad-base", "pocket-holes", "fillet-edges"] : [inputId];
      for (const id of ids) { const input = document.features.find((feature) => feature.id === id); if (input) input.visible = true; }
    }
    const operationId = recordOperation(document, { kind: "delete_feature", feature_id });
    await saveDocument(document);
    return result({ ok: true, revision: document.revision, operation_id: operationId, deleted_feature_id: feature_id }, `Deleted feature '${feature_id}'. Document revision is now ${document.revision}.`);
  } catch (error) { return toolError(error); }
});

server.registerTool("axis_cad_validate_document", {
  title: "Validate Axis CAD Document",
  description: "Check IDs, positive finite dimensions, sketch constraints, and native renderer support. This is fast structural validation; use axis_cad_validate_with_kernel for BRep and tessellation evidence.",
  inputSchema: {},
  outputSchema: { ok: z.boolean(), revision: z.number(), errors: z.array(z.string()), warnings: z.array(z.string()) },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async () => {
  try {
    const document = await loadDocument();
    const errors = [], warnings = [], ids = new Set();
    for (const feature of document.features) {
      if (ids.has(feature.id)) errors.push(`duplicate feature id: ${feature.id}`);
      ids.add(feature.id);
      for (const [key, value] of Object.entries(feature.params)) {
        try { assertValidParameter(value, key); } catch { errors.push(`${feature.id}.${key} has an invalid value`); }
      }
      if (!["sketch", "profile_sketch", "pad", "pocket", "fillet", "box", "cylinder", "cone", "sphere", "torus", "extrude_feature", "pocket_feature", "revolve_feature", "sweep_feature", "loft_feature", "boolean_union", "boolean_difference", "boolean_intersection", "edge_fillet", "edge_chamfer", "shell_feature", "linear_pattern", "circular_pattern", "body_transform", "assembly_instance", "assembly_mate"].includes(feature.kind)) warnings.push(`${feature.id}: '${feature.kind}' is stored in the feature tree but not yet rendered by a native or external mesh adapter`);
      for (const inputId of feature.input_feature_ids || []) if (!document.features.some((candidate) => candidate.id === inputId)) errors.push(`${feature.id} references missing input '${inputId}'`);
      if (feature.kind === "imported_step" && (!feature.asset_path || typeof feature.asset_path !== "string")) errors.push(`${feature.id} has no retained STEP asset path`);
      if (["edge_fillet", "edge_chamfer", "shell_feature", "linear_pattern", "circular_pattern"].includes(feature.kind)) {
        try { assertModifierParameters(feature.kind, feature.params); } catch (error) { errors.push(`${feature.id}: ${error instanceof Error ? error.message : String(error)}`); }
      }
      if (feature.kind === "profile_sketch") {
        const profile = validateProfileSketch(feature); if (!profile.closed) warnings.push(`${feature.id}: ${profile.errors.join(" ")}`);
      }
      if (feature.kind === "loft_feature" && (feature.input_feature_ids || []).length < 2) errors.push(`${feature.id}: loft requires at least two profile sketches`);
      if (feature.kind === "sweep_feature") {
        const profileStationCount = feature.params.profile_station_count || 0;
        if ((feature.input_feature_ids || []).length !== profileStationCount + 1) errors.push(`${feature.id}: morph profile stations do not match its sketch inputs`);
        if (profileStationCount > 0) {
          for (const inputId of feature.input_feature_ids || []) {
            const source = document.features.find((candidate) => candidate.id === inputId);
            const loops = new Set((source?.sketch?.entities || []).filter((entity) => !entity.construction).map((entity) => entity.loop_id || "outer"));
            if (source?.kind !== "profile_sketch" || loops.size !== 1 || !loops.has("outer")) errors.push(`${feature.id}: morph source '${inputId}' must be one closed outer loop without holes`);
          }
        }
      }
      if (["box", "cylinder", "cone", "sphere", "torus", "extrude_feature", "pocket_feature", "revolve_feature", "sweep_feature", "loft_feature", "body_transform", "assembly_instance", "assembly_mate"].includes(feature.kind)) {
        try { assertFeatureParameters(feature.kind, feature.params); } catch (error) { errors.push(`${feature.id}: ${error instanceof Error ? error.message : String(error)}`); }
      }
    }
    const visiting = new Set(), visited = new Set();
    const visit = (featureId) => {
      if (visiting.has(featureId)) { errors.push(`cyclic feature dependency at '${featureId}'`); return; }
      if (visited.has(featureId)) return;
      const feature = document.features.find((candidate) => candidate.id === featureId); if (!feature) return;
      visiting.add(featureId); for (const inputId of feature.input_feature_ids || []) visit(inputId); visiting.delete(featureId); visited.add(featureId);
    };
    for (const feature of document.features) visit(feature.id);
    try { errors.push(...solveSketch(document).errors); } catch (error) { errors.push(error instanceof Error ? error.message : String(error)); }
    warnings.push("Native Metal backend active: call axis_cad_validate_with_kernel for revision-scoped BRep mass properties and tessellation manifold evidence.");
    const payload = { ok: errors.length === 0, revision: document.revision, errors, warnings };
    return result(payload, errors.length ? `Validation failed with ${errors.length} error(s).` : `Revision ${document.revision} is structurally valid with ${warnings.length} explicit limitation(s).`);
  } catch (error) { return toolError(error, "Verify the shared AxisCAD document is readable."); }
});

server.registerTool("axis_cad_measure_document", {
  title: "Measure Axis CAD Document",
  description: "Report model bounds plus mesh/primitive-derived surface and volume estimates. Read-only and explicit about the lack of exact BRep mass properties.",
  inputSchema: {},
  outputSchema: {
    revision: z.number(), units: z.string(), backend: z.string(), bounds: z.object({
      minimum: z.object({ x: z.number(), y: z.number(), z: z.number() }), maximum: z.object({ x: z.number(), y: z.number(), z: z.number() }),
      size: z.object({ x: z.number(), y: z.number(), z: z.number() })
    }), estimated_volume: z.number(), estimated_surface_area: z.number(), exact_mass_properties: z.boolean(), warning: z.string()
  },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async (_, { signal }) => {
  try { const document = await loadDocument(); return result(await measureDocumentWithKernel(document, signal)); }
  catch (error) { return toolError(error, "Restore the base sketch, pad, and pocket features, then retry."); }
});

server.registerTool("axis_cad_measure_selected_edge", {
  title: "Measure Selected Axis CAD Edge",
  description: "Measure the stable BRep edge selected in the native Metal viewport. Straight boundaries and recognized cylinder/cone circular arcs use exact kernel geometry; unsupported curves retain an explicitly labeled display-tessellation estimate. Read-only and revision scoped.",
  inputSchema: {},
  outputSchema: {
    revision: z.number(), units: z.string(), feature_id: z.string(), topology_edge_id: z.number().int().nonnegative(),
    adjacent_face_ids: z.array(z.number().int().nonnegative()).length(2), length: z.number().nonnegative(),
    segment_count: z.number().int().positive(), exact: z.boolean(), exact_for_linear_edge: z.boolean(), curve_kind: z.enum(["line", "circle", "tessellated"]), radius: z.number().positive().nullable(),
    evidence: z.enum(["exact-linear-brep-boundary", "exact-analytic-brep-circle", "vcad-display-tessellation-48"])
  },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async (_, { signal }) => {
  try {
    const document = await loadDocument();
    const selection = JSON.parse(await readFile(selectionPath, "utf8"));
    const surface = selection.revision === document.revision ? selection.surface : null;
    if (!surface?.feature_id || !Number.isInteger(surface.topology_edge_id)) throw new Error("invalid_selection: select a BRep edge in the native viewport first");
    featureById(document, surface.feature_id);
    const mesh = await getRenderMesh(document, surface.feature_id, signal);
    const edge = mesh.topology_edges.find((candidate) => candidate.id === surface.topology_edge_id);
    if (!edge) throw new Error(`stale_topology: edge E${surface.topology_edge_id} no longer exists on '${surface.feature_id}'`);
    const expectedFaces = [...(surface.topology_edge_face_ids || [])].sort((a, b) => a - b);
    const adjacentFaces = [...edge.face_ids].sort((a, b) => a - b);
    if (expectedFaces.length === 2 && (expectedFaces[0] !== adjacentFaces[0] || expectedFaces[1] !== adjacentFaces[1])) throw new Error(`stale_topology: edge E${edge.id} now has different adjacent faces`);
    const segmentCount = edge.positions.length / 6, exact = edge.length_exact === true, curveKind = edge.curve_kind || (segmentCount === 1 ? "line" : "tessellated");
    const evidence = exact ? (curveKind === "circle" ? "exact-analytic-brep-circle" : "exact-linear-brep-boundary") : "vcad-display-tessellation-48";
    const payload = { revision: document.revision, units: document.units, feature_id: surface.feature_id, topology_edge_id: edge.id, adjacent_face_ids: adjacentFaces, length: edge.length, segment_count: segmentCount, exact, exact_for_linear_edge: exact && curveKind === "line", curve_kind: curveKind, radius: edge.radius ?? null, evidence };
    return result(payload, `${exact ? "Exact" : "Tessellated"} ${curveKind} edge length: ${edge.length.toFixed(3)} ${document.units}${edge.radius ? `; radius ${edge.radius.toFixed(3)} ${document.units}` : ""}.`);
  } catch (error) { return toolError(error, "Select a currently rendered BRep edge in Axis CAD and retry."); }
});

server.registerTool("axis_cad_measure_selected_face", {
  title: "Measure Selected Axis CAD Face",
  description: "Measure the deterministic BRep face selected in the native Metal viewport. Analytic primitive faces and straight-boundary planar faces report exact area; unsupported trimmed curved faces report a qualified tessellation estimate. Read-only and revision scoped.",
  inputSchema: {},
  outputSchema: {
    revision: z.number(), units: z.string(), feature_id: z.string(), topology_face_id: z.number().int().nonnegative(),
    area: z.number().nonnegative(), exact: z.boolean(), surface_kind: z.string(), radius: z.number().positive().nullable(),
    evidence: z.enum(["exact-analytic-brep-face", "vcad-display-tessellation-48"])
  },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async (_, { signal }) => {
  try {
    const document = await loadDocument();
    const selection = JSON.parse(await readFile(selectionPath, "utf8"));
    const surface = selection.revision === document.revision ? selection.surface : null;
    if (!surface?.feature_id || !Number.isInteger(surface.topology_face_id)) throw new Error("invalid_selection: select a BRep face in the native viewport first");
    featureById(document, surface.feature_id);
    const mesh = await getRenderMesh(document, surface.feature_id, signal);
    const face = mesh.topology_faces.find((candidate) => candidate.id === surface.topology_face_id);
    if (!face) throw new Error(`stale_topology: face F${surface.topology_face_id} no longer exists on '${surface.feature_id}'`);
    const payload = { revision: document.revision, units: document.units, feature_id: surface.feature_id, topology_face_id: face.id, area: face.area, exact: face.area_exact, surface_kind: face.surface_kind, radius: face.radius ?? null, evidence: face.area_exact ? "exact-analytic-brep-face" : "vcad-display-tessellation-48" };
    return result(payload, `${face.area_exact ? "Exact" : "Tessellated"} ${face.surface_kind} face area: ${face.area.toFixed(3)} ${document.units}²${face.radius ? `; radius ${face.radius.toFixed(3)} ${document.units}` : ""}.`);
  } catch (error) { return toolError(error, "Select a currently rendered BRep face in Axis CAD and retry."); }
});

server.registerTool("axis_cad_get_kernel_status", {
  title: "Inspect Axis CAD Kernel Adapter",
  description: "Check whether the vcad WASM BRep adapter is installed and loadable. Release apps bundle it in an isolated worker; the development MCP may use AXIS_VCAD_KERNEL_DIR.",
  inputSchema: {},
  outputSchema: {
    available: z.boolean(), adapter: z.string(), version: z.string().optional(), license: z.string().optional(),
    kernel_directory: z.string(), execution: z.string().optional(), bundled_with_app: z.boolean().optional(), error: z.string().optional()
  },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async (_, { signal }) => {
  try { return result(await getKernelStatus(signal)); }
  catch (error) { return toolError(error, "Set AXIS_VCAD_KERNEL_DIR to the vcad kernel-wasm package and restart the MCP server."); }
});

server.registerTool("axis_cad_check_clearance", {
  title: "Check Axis CAD Clearance",
  description: "Measure minimum signed clearance between two solid-producing features with vcad. Reports clear, touching, or interference plus witness points; does not modify the document.",
  inputSchema: { feature_id: z.string().min(1), second_feature_id: z.string().min(1) },
  outputSchema: {
    ok: z.boolean(), revision: z.number(), feature_id: z.string(), second_feature_id: z.string(),
    distance: z.number(), intersecting: z.boolean(), classification: z.enum(["clear", "touching", "interference"]),
    point_a: selectionVectorSchema, point_b: selectionVectorSchema,
    adapter: z.string(), tessellation_segments: z.number().int().positive()
  },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async ({ feature_id, second_feature_id }, { signal }) => {
  try {
    const clearance = await checkClearance(await loadDocument(), feature_id, second_feature_id, signal);
    const message = clearance.classification === "interference"
      ? `'${clearance.feature_id}' interferes with '${clearance.second_feature_id}' by ${Math.abs(clearance.distance).toFixed(3)} mm.`
      : clearance.classification === "touching"
        ? `'${clearance.feature_id}' touches '${clearance.second_feature_id}'.`
        : `Minimum clearance between '${clearance.feature_id}' and '${clearance.second_feature_id}' is ${clearance.distance.toFixed(3)} mm.`;
    return result(clearance, message);
  } catch (error) { return toolError(error, "Choose two distinct solid-producing feature IDs from axis_cad_get_document."); }
});

server.registerTool("axis_cad_import_step", {
  title: "Import Axis CAD STEP",
  description: "Copy a local STEP/STP file into the managed Axis CAD asset directory, retain each exact BRep body as a reusable feature, and stream its kernel tessellation into native Metal. This is additive and revisioned.",
  inputSchema: { expected_revision: z.number().int().nonnegative(), source_path: z.string().min(1), feature_prefix: z.string().regex(/^[a-z][a-z0-9-]{1,47}$/), name: z.string().min(1).max(120) },
  outputSchema: { ok: z.boolean(), revision: z.number(), operation_id: z.string(), asset_path: z.string(), byte_count: z.number(), body_count: z.number(), exact_volume_mm3: z.number(), features: z.array(featureSchema) },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true }
}, async ({ expected_revision, source_path, feature_prefix, name }, { signal }) => {
  try {
    let document = await loadDocument(); assertRevision(document, expected_revision);
    const sourcePath = path.resolve(source_path), extension = path.extname(sourcePath).toLowerCase();
    if (![".step", ".stp"].includes(extension)) throw new Error("invalid_asset: source_path must end in .step or .stp");
    const sourceStat = await stat(sourcePath); if (!sourceStat.isFile() || sourceStat.size > 100 * 1024 * 1024) throw new Error("invalid_asset: STEP import must be a file no larger than 100 MB");
    const inspection = await inspectStepFile(sourcePath, signal); if (inspection.body_count > 128) throw new Error("invalid_asset: STEP import is limited to 128 solid bodies");
    const featureIds = Array.from({ length: inspection.body_count }, (_, index) => inspection.body_count === 1 ? feature_prefix : `${feature_prefix}-body-${index + 1}`);
    if (featureIds.some((id) => document.features.some((feature) => feature.id === id))) throw new Error("duplicate_feature: one or more imported body IDs already exist");
    document = await loadDocument(); assertRevision(document, expected_revision);
    const assetsDirectory = path.join(dataRoot, "assets"); await mkdir(assetsDirectory, { recursive: true });
    const assetPath = path.join(assetsDirectory, `${feature_prefix}-${randomUUID()}.step`);
    await writeFile(assetPath, await readFile(sourcePath), { flag: "wx" });
    const features = inspection.bodies.map((body, index) => ({ id: featureIds[index], name: inspection.body_count === 1 ? name : `${name} · Body ${body.body_number}`, kind: "imported_step", visible: true, params: { body_number: body.body_number }, asset_path: assetPath }));
    document.features.push(...features);
    const operationId = recordOperation(document, { kind: "import_step", feature_id: features[0].id, parameter: "body_count", value: features.length }); await saveDocument(document);
    const exactVolume = inspection.bodies.reduce((sum, body) => sum + body.volume, 0);
    return result({ ok: true, revision: document.revision, operation_id: operationId, asset_path: assetPath, byte_count: inspection.byte_count, body_count: features.length, exact_volume_mm3: exactVolume, features }, `Imported ${features.length} retained STEP BRep bod${features.length === 1 ? "y" : "ies"} as ${featureIds.join(", ")} at revision ${document.revision}; native Metal rebuild is available.`);
  } catch (error) { return toolError(error, "Use the current revision, a readable local .step/.stp file under 100 MB, and a new stable feature prefix."); }
});

server.registerTool("axis_cad_validate_with_kernel", {
  title: "Validate Axis CAD Feature with BRep Kernel",
  description: "Rebuild one feature with the external vcad BRep kernel and report mass properties, analytic-reference deviation, STEP availability, retained-BRep STEP reopen evidence (with a separate re-import volume metric), and closed-manifold tessellation status.",
  inputSchema: { feature_id: z.string().min(1).default("pad-base").describe("pad-base/base-bracket for the mounting plate, or a visible primitive feature ID") },
  outputSchema: {
    ok: z.boolean(), revision: z.number(), feature_id: z.string(), source_features: z.array(z.string()), adapter: z.string(), kernel_mass_properties: z.boolean(),
    bounds: z.object({ minimum: z.object({ x: z.number(), y: z.number(), z: z.number() }), maximum: z.object({ x: z.number(), y: z.number(), z: z.number() }) }),
    volume: z.number(), analytic_reference_volume: z.number().nullable(), volume_deviation: z.number().nullable(), volume_relative_error: z.number().nullable(), volume_within_one_percent: z.boolean().nullable(),
    surface_area: z.number(), center_of_mass: z.object({ x: z.number(), y: z.number(), z: z.number() }), triangle_count: z.number(),
    boundary_edge_segments: z.number(), closed_manifold_mesh: z.boolean(), can_export_step: z.boolean(),
    step_roundtrip: z.object({ attempted: z.boolean(), passed: z.boolean(), reader: z.string(), body_count: z.number(), triangle_count: z.number(), volume: z.number().nullable(), volume_relative_error: z.number().nullable(), bounds_max_deviation: z.number().nullable(), error: z.string().optional() }),
    warnings: z.array(z.string())
  },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async ({ feature_id }, { signal }) => {
  try {
    const validation = await validateWithKernel(await loadDocument(), feature_id, signal);
    const message = validation.ok
      ? `Kernel validation passed for '${validation.feature_id}' with kernel-derived mass properties, a closed tessellated mesh, and STEP reader round-trip agreement.`
      : `Kernel rebuilt '${validation.feature_id}', but validation has ${validation.warnings.length} warning(s); inspect boundary_edge_segments before manufacturing use.`;
    return result(validation, message);
  } catch (error) { return toolError(error, "Call axis_cad_get_kernel_status, then retry with pad-base or a visible box/cylinder/cone/sphere/torus feature."); }
});

server.registerTool("axis_cad_export_step", {
  title: "Export Axis CAD STEP",
  description: "Rebuild one feature with the external vcad BRep kernel and write a revision-stamped STEP file in Axis CAD's local exports directory. Existing arbitrary files are never targeted.",
  inputSchema: {
    feature_id: z.string().min(1).default("pad-base"),
    filename_prefix: z.string().regex(/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,60}$/).optional()
  },
  outputSchema: {
    ok: z.boolean(), revision: z.number(), feature_id: z.string(), path: z.string(), byte_count: z.number(), adapter: z.string(),
    validation: z.object({
      bounds: z.object({ minimum: z.object({ x: z.number(), y: z.number(), z: z.number() }), maximum: z.object({ x: z.number(), y: z.number(), z: z.number() }) }),
      volume: z.number(), analytic_reference_volume: z.number().nullable(), volume_deviation: z.number().nullable(), volume_relative_error: z.number().nullable(), volume_within_one_percent: z.boolean().nullable(),
      surface_area: z.number(), center_of_mass: z.object({ x: z.number(), y: z.number(), z: z.number() }), triangle_count: z.number(),
      boundary_edge_segments: z.number(), closed_manifold_mesh: z.boolean(), can_export_step: z.boolean(),
      step_roundtrip: z.object({ attempted: z.boolean(), passed: z.boolean(), reader: z.string(), body_count: z.number(), triangle_count: z.number(), volume: z.number().nullable(), volume_relative_error: z.number().nullable(), bounds_max_deviation: z.number().nullable(), error: z.string().optional() }),
      warnings: z.array(z.string())
    })
  },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async ({ feature_id, filename_prefix }, { signal }) => {
  try {
    const document = await loadDocument();
    const exportDirectory = path.join(dataRoot, "exports");
    const prefix = filename_prefix || document.name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "axis-part";
    const target = path.join(exportDirectory, `${prefix}-r${document.revision}-${feature_id === "pad-base" ? "base-bracket" : feature_id}.step`);
    const exported = await exportStep(document, feature_id, target, signal);
    return result(exported, `Exported STEP for '${exported.feature_id}' to ${target}.${exported.validation.warnings.length ? ` Kernel warning: ${exported.validation.warnings[0]}` : ""}`);
  } catch (error) { return toolError(error, "Call axis_cad_get_kernel_status and axis_cad_validate_with_kernel, then retry with a simple filename prefix."); }
});

server.registerTool("axis_cad_export_assembly_step", {
  title: "Export Axis CAD Assembly STEP",
  description: "Export every visible solved assembly instance into one flattened multi-body STEP file, then reopen the file and verify body count, aggregate bounds, retained BRep, and volume before reporting success.",
  inputSchema: { filename_prefix: z.string().regex(/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,60}$/).optional() },
  outputSchema: {
    ok: z.boolean(), revision: z.number(), path: z.string(), byte_count: z.number(), adapter: z.string(), instance_count: z.number(), body_count: z.number(), instance_ids: z.array(z.string()),
    bounds: z.object({ minimum: selectionVectorSchema, maximum: selectionVectorSchema }), volume: z.number(),
    step_roundtrip: z.object({ attempted: z.boolean(), passed: z.boolean(), reader: z.string(), body_count: z.number(), triangle_count: z.number(), volume: z.number(), volume_relative_error: z.number().nullable(), bounds_max_deviation: z.number() })
  },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async ({ filename_prefix }, { signal }) => {
  try {
    const document = await loadDocument(), exportDirectory = path.join(dataRoot, "exports");
    const prefix = filename_prefix || document.name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "axis-assembly";
    const target = path.join(exportDirectory, `${prefix}-r${document.revision}-assembly.step`);
    const exported = await exportAssemblyStep(document, target, signal);
    return result(exported, `Exported ${exported.body_count}-body solved assembly STEP to ${target}; exact reader round-trip passed.`);
  } catch (error) { return toolError(error, "Create at least one visible assembly instance and validate its source BRep before retrying."); }
});

server.registerTool("axis_cad_get_drawing", {
  title: "Inspect Axis CAD Technical Drawing",
  description: "Return the current A4 drawing sheet definition with front, top, and right orthographic projections and model dimensions.",
  inputSchema: {},
  outputSchema: { document_name: z.string(), document_id: z.string(), revision: z.number(), units: z.string(), sheet: z.string(), projections: z.array(z.object({ id: z.string(), title: z.string(), width: z.number(), height: z.number(), outlines: z.array(z.record(z.string(), z.union([z.string(), z.number()]))) })) },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async () => {
  try { return result(drawingSheet(await loadDocument())); }
  catch (error) { return toolError(error, "Restore the base sketch, pad, and pocket features, then retry."); }
});

server.registerTool("axis_cad_export_drawing", {
  title: "Export Axis CAD Technical Drawing",
  description: "Export the current front/top/right drawing as vector PDF or editable millimeter DXF into Axis CAD's local exports directory. Revision-stamped files do not overwrite arbitrary user files.",
  inputSchema: { format: z.enum(["pdf", "dxf"]).default("pdf"), filename_prefix: z.string().regex(/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,60}$/).optional() },
  outputSchema: { ok: z.boolean(), revision: z.number(), format: z.enum(["pdf", "dxf"]), path: z.string(), byte_count: z.number() },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async ({ format, filename_prefix }) => {
  try {
    const document = await loadDocument(), sheet = drawingSheet(document), bytes = format === "dxf" ? drawingDxfBytes(sheet) : drawingPdfBytes(sheet);
    const exportDirectory = path.join(dataRoot, "exports"); await mkdir(exportDirectory, { recursive: true });
    const prefix = filename_prefix || document.name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "axis-part";
    const target = path.join(exportDirectory, `${prefix}-r${document.revision}-drawing.${format}`);
    await writeFile(target, bytes);
    return result({ ok: true, revision: document.revision, format, path: target, byte_count: bytes.length }, `Exported the revision ${document.revision} ${format.toUpperCase()} drawing to ${target}.`);
  } catch (error) { return toolError(error, "Use a simple filename prefix and verify the AxisCAD data directory is writable."); }
});

server.registerTool("axis_cad_checkpoint_document", {
  title: "Checkpoint Axis CAD Document",
  description: "Save an immutable named snapshot of the current native document before a complex or destructive edit.",
  inputSchema: { label: z.string().min(1).max(80) },
  outputSchema: { ok: z.boolean(), revision: z.number(), checkpoint_id: z.string() },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async ({ label }) => {
  try {
    const document = await loadDocument();
    await mkdir(checkpointsPath, { recursive: true });
    const safeLabel = label.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 40) || "checkpoint";
    const checkpointId = `r${document.revision}-${safeLabel}`;
    const target = path.join(checkpointsPath, `${checkpointId}.json`);
    await writeFile(target, `${JSON.stringify(document, null, 2)}\n`, { encoding: "utf8", flag: "wx" }).catch((error) => { if (error?.code !== "EEXIST") throw error; });
    return result({ ok: true, revision: document.revision, checkpoint_id: checkpointId }, `Checkpoint '${checkpointId}' saved at revision ${document.revision}.`);
  } catch (error) { return toolError(error, "Choose a short checkpoint label and retry."); }
});

server.registerTool("axis_cad_list_checkpoints", {
  title: "List Axis CAD Checkpoints",
  description: "List available local checkpoints without loading or modifying the document.",
  inputSchema: {},
  outputSchema: { checkpoint_ids: z.array(z.string()), total_count: z.number() },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, async () => {
  try {
    await mkdir(checkpointsPath, { recursive: true });
    const checkpointIds = (await readdir(checkpointsPath)).filter((name) => name.endsWith(".json")).map((name) => name.slice(0, -5)).sort().reverse();
    return result({ checkpoint_ids: checkpointIds, total_count: checkpointIds.length });
  } catch (error) { return toolError(error, "Verify the AxisCAD checkpoints directory is readable."); }
});

server.registerTool("axis_cad_restore_checkpoint", {
  title: "Restore Axis CAD Checkpoint",
  description: "Replace the active document with a named local checkpoint. Requires current revision and confirm=true because later changes are discarded.",
  inputSchema: { expected_revision: z.number().int().nonnegative(), checkpoint_id: z.string().regex(/^r\d+-[a-z0-9-]+$/), confirm: z.literal(true) },
  outputSchema: { ok: z.boolean(), revision: z.number(), restored_checkpoint_id: z.string() },
  annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false }
}, async ({ expected_revision, checkpoint_id }) => {
  try {
    const active = await loadDocument();
    assertRevision(active, expected_revision);
    const checkpointPath = path.join(checkpointsPath, `${checkpoint_id}.json`);
    const restored = JSON.parse(await readFile(checkpointPath, "utf8"));
    restored.revision = active.revision + 1;
    restored.operations = active.operations;
    restored.operations.unshift({ operation_id: `op-${restored.revision}`, author: "codex", kind: "restore_checkpoint", checkpoint_id, revision: restored.revision, timestamp: new Date().toISOString() });
    await saveDocument(restored);
    return result({ ok: true, revision: restored.revision, restored_checkpoint_id: checkpoint_id }, `Restored '${checkpoint_id}' as revision ${restored.revision}.`);
  } catch (error) { return toolError(error, "Call axis_cad_list_checkpoints, then retry with an exact checkpoint ID and the current revision."); }
});

async function main() {
  await ensureDocument();
  await server.connect(new StdioServerTransport());
}

main().catch((error) => {
  console.error("Axis CAD MCP server failed:", error);
  process.exitCode = 1;
});
