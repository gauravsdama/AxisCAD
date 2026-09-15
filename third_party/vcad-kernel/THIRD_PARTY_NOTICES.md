# Third-party kernel

Axis CAD includes a modified vcad-derived WebAssembly kernel for BRep validation,
STEP import and export, mass properties, mesh clearance, and the tested modeling
operations exposed by the application. The kernel runs out of process and loads
only when an operation needs exact geometry. Axis CAD's document model, native
renderer, MCP tools, and application code remain separate from this component.

The pinned runtime files in this directory are `vcad_kernel_wasm.js` and `vcad_kernel_wasm_bg.wasm`. Their SHA-256 digests are recorded below so packaging and CI can reject an unexpected replacement.

- JavaScript: `3962fe53b04b2ee7c48e68b271411259f6a8a5f2327e3a0e2d41ec17fd8734fd`
- WebAssembly: `2faba958aa8bfdfe962b62a325be77a462d384b16f73859883f56afe5e7968c3`

The distributed WebAssembly file has non-runtime debug and producer metadata
removed. Embedded local build-path prefixes are replaced with a neutral source
root of the same byte length. The release gate validates the resulting module and
its geometry behavior.

[vcad](https://github.com/ecto/vcad) is distributed with an Apache-2.0 license
file and notice. Some upstream package metadata identifies MIT. Axis CAD applies
the Apache-2.0 terms, preserves the upstream license and notice, and identifies
the bundled artifacts as modified.

The package metadata reports version 0.9.4. The retained source and locked
toolchain reproduce these runtime files. Updating either artifact requires a
recorded upstream revision, a clean source build, new hashes, and the complete
Axis CAD verification gate.

The corresponding maintainable source boundary is stored under
`third_party/vcad-source`. It includes the required VCAD crates and Tang math
dependency, with revision records and license files. Neither source tree is a
runtime dependency of the packaged app.
