#!/usr/bin/env node

import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.dirname(scriptDirectory);
const outputDirectory = path.resolve(process.argv[2] || "conformance/generated");
const kernelDirectory = path.join(projectRoot, "third_party/vcad-kernel");
const kernel = await import(pathToFileURL(path.join(kernelDirectory, "vcad_kernel_wasm.js")));
kernel.initSync({ module: await readFile(path.join(kernelDirectory, "vcad_kernel_wasm_bg.wasm")) });

const template = `ISO-10303-21;
HEADER;
FILE_DESCRIPTION((''), '2;1');
FILE_NAME('axis-conformance.step', '2026-01-01', (''), (''), '', '', '');
FILE_SCHEMA(('AUTOMOTIVE_DESIGN'));
ENDSEC;
DATA;
#1 = CARTESIAN_POINT('', (10.0, 0.0, 0.0));
#2 = CARTESIAN_POINT('', (10.0, 0.0, 20.0));
#3 = VERTEX_POINT('', #1);
#4 = VERTEX_POINT('', #2);
#10 = CARTESIAN_POINT('', (0.0, 0.0, 0.0));
#11 = DIRECTION('', (0.0, 0.0, 1.0));
#12 = DIRECTION('', (1.0, 0.0, 0.0));
#13 = AXIS2_PLACEMENT_3D('', #10, #11, #12);
#14 = CIRCLE('', #13, 10.0);
#15 = CARTESIAN_POINT('', (0.0, 0.0, 20.0));
#16 = AXIS2_PLACEMENT_3D('', #15, #11, #12);
#17 = CIRCLE('', #16, 10.0);
#18 = VECTOR('', #11, 20.0);
#19 = LINE('', #1, #18);
#20 = EDGE_CURVE('', #3, #3, #14, .T.);
#21 = EDGE_CURVE('', #4, #4, #17, .T.);
#22 = EDGE_CURVE('', #3, #4, <SEAM>, .T.);
#23 = ORIENTED_EDGE('', *, *, #20, .T.);
#24 = ORIENTED_EDGE('', *, *, #22, .T.);
#25 = ORIENTED_EDGE('', *, *, #21, .F.);
#26 = ORIENTED_EDGE('', *, *, #22, .F.);
#27 = EDGE_LOOP('', (#23, #24, #25, #26));
#28 = FACE_OUTER_BOUND('', #27, .T.);
#29 = ADVANCED_FACE('', (#28), #40, .T.);
#30 = DIRECTION('', (0.0, 0.0, -1.0));
#31 = AXIS2_PLACEMENT_3D('', #10, #30, #12);
#32 = PLANE('', #31);
#33 = ORIENTED_EDGE('', *, *, #20, .F.);
#34 = EDGE_LOOP('', (#33));
#35 = FACE_OUTER_BOUND('', #34, .T.);
#36 = ADVANCED_FACE('', (#35), #32, .T.);
#37 = AXIS2_PLACEMENT_3D('', #15, #11, #12);
#38 = PLANE('', #37);
#39 = ORIENTED_EDGE('', *, *, #21, .T.);
#41 = EDGE_LOOP('', (#39));
#42 = FACE_OUTER_BOUND('', #41, .T.);
#43 = ADVANCED_FACE('', (#42), #38, .T.);
<LATERAL>
#44 = CLOSED_SHELL('', (#29, #36, #43));
#45 = MANIFOLD_SOLID_BREP('part', #44);
ENDSEC;
END-ISO-10303-21;
`;

function fixture(seam, lateral) {
  return template.replace("<SEAM>", seam).replace("<LATERAL>", lateral);
}

const cases = [
  {
    name: "rational-nurbs-vase",
    source: fixture("#51", `#50 = CARTESIAN_POINT('', (12.0, 0.0, 10.0));
#51 = B_SPLINE_CURVE_WITH_KNOTS('', 2, (#1, #50, #2), .UNSPECIFIED., .F., .F., (3, 3), (0.0, 1.0), .UNSPECIFIED.);
#52 = AXIS1_PLACEMENT('', #10, #11);
#40 = SURFACE_OF_REVOLUTION('', #51, #52);`)
  },
  {
    name: "cylindrical-seam-pcurves",
    source: fixture("#71", `#40 = CYLINDRICAL_SURFACE('', #13, 10.0);
#60 = CARTESIAN_POINT('', (0.0, 0.0));
#61 = DIRECTION('', (0.0, 1.0));
#62 = VECTOR('', #61, 1.0);
#63 = LINE('', #60, #62);
#64 = (GEOMETRIC_REPRESENTATION_CONTEXT(2) PARAMETRIC_REPRESENTATION_CONTEXT() REPRESENTATION_CONTEXT('2D SPACE',''));
#65 = DEFINITIONAL_REPRESENTATION('', (#63), #64);
#66 = PCURVE('', #40, #65);
#67 = CARTESIAN_POINT('', (6.283185307179586, 0.0));
#68 = LINE('', #67, #62);
#69 = DEFINITIONAL_REPRESENTATION('', (#68), #64);
#70 = PCURVE('', #40, #69);
#71 = SEAM_CURVE('', #19, (#66, #70), .PCURVE_S1.);`)
  },
  {
    name: "planar-circle-pcurve",
    source: fixture("#19", `#40 = CYLINDRICAL_SURFACE('', #13, 10.0);
#60 = CARTESIAN_POINT('', (0.0, 0.0));
#61 = DIRECTION('', (1.0, 0.0));
#62 = AXIS2_PLACEMENT_2D('', #60, #61);
#63 = CIRCLE('', #62, 10.0);
#64 = (GEOMETRIC_REPRESENTATION_CONTEXT(2) PARAMETRIC_REPRESENTATION_CONTEXT() REPRESENTATION_CONTEXT('2D SPACE',''));
#65 = DEFINITIONAL_REPRESENTATION('', (#63), #64);
#66 = PCURVE('', #32, #65);
#67 = SURFACE_CURVE('', #14, (#66), .CURVE_3D.);`).replace(
      "#20 = EDGE_CURVE('', #3, #3, #14, .T.);",
      "#20 = EDGE_CURVE('', #3, #3, #67, .T.);"
    )
  },
  {
    name: "rational-nurbs-pcurve",
    source: fixture("#19", `#40 = CYLINDRICAL_SURFACE('', #13, 10.0);
#60 = CARTESIAN_POINT('', (0.0, 0.0));
#61 = CARTESIAN_POINT('', (0.5, 0.25));
#62 = CARTESIAN_POINT('', (1.0, 0.0));
#63 = (BOUNDED_CURVE() B_SPLINE_CURVE(2, (#60, #61, #62), .UNSPECIFIED., .F., .F.) B_SPLINE_CURVE_WITH_KNOTS((3, 3), (0.0, 1.0), .UNSPECIFIED.) CURVE() GEOMETRIC_REPRESENTATION_ITEM() RATIONAL_B_SPLINE_CURVE((1.0, 0.5, 1.0)) REPRESENTATION_ITEM(''));
#64 = (GEOMETRIC_REPRESENTATION_CONTEXT(2) PARAMETRIC_REPRESENTATION_CONTEXT() REPRESENTATION_CONTEXT('2D SPACE',''));
#65 = DEFINITIONAL_REPRESENTATION('', (#63), #64);
#66 = PCURVE('', #32, #65);
#67 = SURFACE_CURVE('', #14, (#66), .CURVE_3D.);`).replace(
      "#20 = EDGE_CURVE('', #3, #3, #14, .T.);",
      "#20 = EDGE_CURVE('', #3, #3, #67, .T.);"
    )
  }
];

await mkdir(outputDirectory, { recursive: true });
for (const entry of cases) {
  const solid = kernel.Solid.fromStepBuffer(new TextEncoder().encode(entry.source), 0);
  try {
    await writeFile(path.join(outputDirectory, `${entry.name}.step`), solid.toStepBuffer());
  } finally {
    solid.free();
  }
}
