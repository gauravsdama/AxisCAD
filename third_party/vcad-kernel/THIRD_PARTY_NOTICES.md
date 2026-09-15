# Third-party kernel

Axis CAD includes a modified vcad-derived WebAssembly kernel for BRep validation,
STEP import and export, mass properties, mesh clearance, and the tested modeling
operations exposed by the application. The kernel runs out of process and loads
only when an operation needs exact geometry. Axis CAD's document model, native
renderer, MCP tools, and application code remain separate from this component.

The pinned runtime files in this directory are `vcad_kernel_wasm.js` and `vcad_kernel_wasm_bg.wasm`. Their SHA-256 digests are recorded below so packaging and CI can reject an unexpected replacement.

- JavaScript: `8c3869784e6062bdb416cbc27e7786b2bd188eda078793da9db92aebb9a983bb`
- WebAssembly: `7ae23e8d289447af16d314541c8d2fb57ae477fbed75b6048cfdbabd522a826e`

The distributed WebAssembly file has non-runtime debug and producer metadata
removed. Embedded local build-path prefixes are replaced with a neutral source
root of the same byte length. The release gate validates the resulting module and
its geometry behavior.

[vcad](https://github.com/ecto/vcad) is distributed with an Apache-2.0 license
file and notice. Some upstream package metadata identifies MIT. Axis CAD applies
the Apache-2.0 terms, preserves the upstream license and notice, and identifies
the bundled artifacts as modified.

The package metadata reports version 0.9.4. The exact artifact hashes, behavior,
and package self-check are the release identity. Updating either artifact requires
a recorded upstream revision, a source build, new hashes, and the complete Axis CAD
verification gate.
