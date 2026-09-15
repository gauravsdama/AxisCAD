# Axis CAD

Axis CAD is a native macOS CAD workspace built with SwiftUI and Metal. It keeps
the document model, renderer, geometry worker, and Codex integration on the local
machine. Manual edits and MCP edits use the same revisioned document, so a stale
automation request cannot overwrite newer work.

The application supports parametric primitives, profile sketches, extrusion,
pockets, revolve, sweep, loft, booleans, fillet, chamfer, shell, patterns,
assemblies, measurements, STEP import and export, STL, DXF, and vector PDF. The
native viewport renders with Metal while exact geometry runs in a separate,
timeout-bounded WebAssembly worker.

## Run on a Mac

Axis CAD requires macOS 14 or later. Building requires Node.js 22.12, 24, or 26+,
Swift 6, and Deno 2. Rust is needed only for the independent STEP conformance
suite.

Check the current Mac without installing anything:

```bash
./scripts/setup_macos.sh
```

Install the locked dependencies and build a local application:

```bash
./scripts/setup_macos.sh --install
./scripts/setup_macos.sh --package
open native/build/AxisCAD.app
```

The package is ad-hoc signed for local use and is built for the architecture of
the Mac that creates it. A Developer ID is not required for personal use, but a
Mac may ask the user to confirm the first launch in Privacy & Security. Build on
each target architecture for the most reliable transfer.

The packaged application is self-contained. It includes the native executable,
kernel worker, pinned geometry kernel, app icon, and license notices. Node, Deno,
Rust, Homebrew, and the source checkout are not required at runtime.

Axis CAD stores its live document at:

```text
~/Library/Application Support/AxisCAD/active-document.json
```

Saved projects use the portable `.axiscad` JSON format. Imported STEP assets are
copied into the managed document store and included beside a saved project using
relative paths.

## Codex MCP bridge

The local MCP server exposes typed CAD inspection, editing, validation, export,
measurement, assembly, and checkpoint operations. Every mutation includes an
expected document revision.

```bash
codex mcp add axis-cad -- node /absolute/path/to/AxisCAD/mcp/server.mjs
codex mcp list
```

Restart Codex after adding the server. Geometry changes go through MCP operations;
the assistant does not drive the macOS interface. The in-app terminal is a separate
user-operated shell and runs commands with the current macOS user's permissions.

## Architecture

- `native/` contains the SwiftUI application, Metal viewport, document model,
  persistence, native exporters, and package script.
- `mcp/` contains the STDIO MCP server and revision-safe CAD operations.
- `kernel/` contains the out-of-process adapter used by the app and MCP server.
- `third_party/vcad-source/` contains the VCAD-derived kernel source and Tang dependency.
- `third_party/vcad-kernel/` contains the pinned source-built WebAssembly runtime and its notices.
- `conformance/step-reader/` contains an independent OpenCASCADE reader used only
  by the test suite.
- `docs/product/` contains the approved UI copy record and exact source inventory.

The Vite interface remains a development reference. The native application is the
product runtime and does not require a web server.

## Verification

Run the complete release gate:

```bash
npm run check
```

That command verifies kernel hashes and notices, audits runtime dependencies, runs
the TypeScript and Swift suites, builds the web reference, generates and reopens an
18-case STEP corpus with OpenCASCADE, packages the native app, exercises the bundled
kernel worker, and verifies the app signature.

The UI wording is reviewed through [docs/product/UI_COPY.md](docs/product/UI_COPY.md).
The release gate rejects a stale [docs/product/UI_COPY_FULL.md](docs/product/UI_COPY_FULL.md)
inventory.

## Third-party geometry kernel

Axis CAD uses [VCAD](https://github.com/ecto/vcad) as the foundation for its B-rep
geometry kernel and STEP support. Axis CAD supplies the native macOS application,
Metal viewport, document model, MCP bridge, packaging, and its application-specific
kernel bindings. The kernel source is retained under `third_party/vcad-source`, and
the pinned source-built WebAssembly runtime is stored under `third_party/vcad-kernel` so the
packaged application works without a separate VCAD checkout or network connection.
VCAD's Apache-2.0 attribution and the Tang MIT license are included in every package.

Axis CAD is licensed under Apache-2.0. See [LICENSE](LICENSE), [NOTICE](NOTICE), and
[SECURITY.md](SECURITY.md).
