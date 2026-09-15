# Geometry kernel source

Axis CAD keeps its geometry source and release runtime in the repository. The
native app does not clone VCAD, load a submodule, or contact a package registry
when it runs.

The VCAD source snapshot is based on commit
`898d0b112c9241661275411060084b67b0044d8e`. Only the crates required by the
Axis CAD geometry boundary are included. The workspace manifest limits builds
to that dependency closure. Its package metadata uses Apache-2.0 to match the
license distributed at the root of VCAD.

Tang is included at commit
`9d28b81067f1a416c73a9e84b7f4f9af29bbfa34`. It supplies the math crates used
by VCAD. Its MIT license is preserved beside the source and in the packaged
application notices.

`crates/axis-kernel-wasm` is the Axis CAD binding layer. It exposes the solid,
mesh, clearance, and STEP operations used by the local worker. The checked-in
runtime under `third_party/vcad-kernel` remains the release artifact and is
verified by hash and behavior before packaging.

The source toolchain is Rust 1.97.1 and wasm-pack 0.13.1. Runtime users do not
need either tool; they are only required when working on the geometry kernel.
