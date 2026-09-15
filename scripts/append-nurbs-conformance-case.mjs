#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";

const generatedDirectory = path.resolve(process.argv[2] || "conformance/generated");
const manifestPath = path.join(generatedDirectory, "manifest.json");
const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
manifest.cases.push({
  name: "rational-nurbs-vase",
  file: "rational-nurbs-vase.step",
  units: "mm",
  body_count: 1,
  volume: Math.PI * 20 * (100 + 80 / 6 + 16 / 30),
  bounds: {
    minimum: { x: -11, y: -11, z: 0 },
    maximum: { x: 11, y: 11, z: 20 }
  }
});
manifest.cases.push({
  name: "cylindrical-seam-pcurves",
  file: "cylindrical-seam-pcurves.step",
  units: "mm",
  body_count: 1,
  volume: Math.PI * 10 ** 2 * 20,
  bounds: {
    minimum: { x: -10, y: -10, z: 0 },
    maximum: { x: 10, y: 10, z: 20 }
  }
});
manifest.cases.push({
  name: "planar-circle-pcurve",
  file: "planar-circle-pcurve.step",
  units: "mm",
  body_count: 1,
  volume: Math.PI * 10 ** 2 * 20,
  bounds: {
    minimum: { x: -10, y: -10, z: 0 },
    maximum: { x: 10, y: 10, z: 20 }
  }
});
manifest.cases.push({
  name: "rational-nurbs-pcurve",
  file: "rational-nurbs-pcurve.step",
  units: "mm",
  body_count: 1,
  volume: Math.PI * 10 ** 2 * 20,
  bounds: {
    minimum: { x: -10, y: -10, z: 0 },
    maximum: { x: 10, y: 10, z: 20 }
  }
});
await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
