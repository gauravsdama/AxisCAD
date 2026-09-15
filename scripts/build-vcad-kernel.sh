#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_crate="$project_root/third_party/vcad-source/vcad/crates/axis-kernel-wasm"
runtime_dir="$project_root/third_party/vcad-kernel"
build_root=$(mktemp -d -t axis-cad-kernel-build)
stage_dir="$build_root/package"

cleanup() {
  case "$build_root" in
    /tmp/axis-cad-kernel-build.*|/var/folders/*/T/axis-cad-kernel-build.*)
      /bin/rm -rf -- "$build_root"
      ;;
  esac
}
trap cleanup EXIT

if ! command -v wasm-pack >/dev/null 2>&1; then
  echo "wasm-pack 0.13.1 is required to rebuild the geometry kernel." >&2
  exit 1
fi
if [ "$(wasm-pack --version)" != "wasm-pack 0.13.1" ]; then
  echo "Expected wasm-pack 0.13.1; found $(wasm-pack --version)." >&2
  exit 1
fi
if [ "$(rustc --version)" != "rustc 1.97.1 (8bab26f4f 2026-07-14)" ]; then
  echo "Expected Rust 1.97.1; found $(rustc --version)." >&2
  exit 1
fi
if [ ! -x "$project_root/node_modules/.bin/wasm-opt" ]; then
  echo "Run npm ci before rebuilding the geometry kernel." >&2
  exit 1
fi

mkdir -p "$stage_dir"
export CARGO_TARGET_DIR="$build_root/target"
export RUSTFLAGS="--remap-path-prefix=$project_root=/axis-cad-source --remap-path-prefix=$HOME=/axis-cad-build"
wasm-pack build "$source_crate" --target web --release --out-dir "$stage_dir"

mv "$stage_dir/axis_kernel_wasm.js" "$stage_dir/vcad_kernel_wasm.js"
mv "$stage_dir/axis_kernel_wasm_bg.wasm" "$stage_dir/vcad_kernel_wasm_bg.unoptimized.wasm"
perl -pi -e 's/axis_kernel_wasm_bg\.wasm/vcad_kernel_wasm_bg.wasm/g' \
  "$stage_dir/vcad_kernel_wasm.js"
"$project_root/node_modules/.bin/wasm-opt" -Oz --strip-debug --strip-producers \
  --strip-target-features --strip-toolchain-annotations \
  "$stage_dir/vcad_kernel_wasm_bg.unoptimized.wasm" \
  -o "$stage_dir/vcad_kernel_wasm_bg.wasm"
rm "$stage_dir/vcad_kernel_wasm_bg.unoptimized.wasm"

printf '%s\n' \
  '{' \
  '  "name": "vcad-kernel-wasm",' \
  '  "private": true,' \
  '  "version": "0.9.4",' \
  '  "type": "module",' \
  '  "license": "Apache-2.0"' \
  '}' > "$stage_dir/package.json"

if strings "$stage_dir/vcad_kernel_wasm_bg.wasm" | grep -Eq '/Users/|/var/folders/'; then
  echo "Rebuilt kernel contains a local build path." >&2
  exit 1
fi

AXIS_VCAD_KERNEL_DIR="$stage_dir" npm test

case "${1:-check}" in
  check)
    if ! cmp -s "$stage_dir/vcad_kernel_wasm.js" "$runtime_dir/vcad_kernel_wasm.js"; then
      echo "The checked-in JavaScript binding does not match a clean source build." >&2
      exit 1
    fi

    if cmp -s "$stage_dir/vcad_kernel_wasm_bg.wasm" "$runtime_dir/vcad_kernel_wasm_bg.wasm"; then
      echo "A clean source build reproduced the checked-in geometry kernel byte-for-byte and passed the Axis CAD protocol suite."
    elif [ "${AXIS_VCAD_ALLOW_CROSS_HOST_LAYOUT:-0}" = "1" ]; then
      node "$project_root/scripts/compare-wasm-interface.mjs" \
        "$runtime_dir/vcad_kernel_wasm_bg.wasm" \
        "$stage_dir/vcad_kernel_wasm_bg.wasm"
      echo "Checked-in SHA-256: $(shasum -a 256 "$runtime_dir/vcad_kernel_wasm_bg.wasm" | awk '{print $1}')"
      echo "Source-build SHA-256: $(shasum -a 256 "$stage_dir/vcad_kernel_wasm_bg.wasm" | awk '{print $1}')"
      echo "The independent host produced a different optimized function layout with the same interface and passing protocol behavior."
    else
      echo "Checked-in SHA-256: $(shasum -a 256 "$runtime_dir/vcad_kernel_wasm_bg.wasm" | awk '{print $1}')" >&2
      echo "Source-build SHA-256: $(shasum -a 256 "$stage_dir/vcad_kernel_wasm_bg.wasm" | awk '{print $1}')" >&2
      if [ -n "${AXIS_VCAD_DIAGNOSTIC_DIR:-}" ]; then
        mkdir -p "$AXIS_VCAD_DIAGNOSTIC_DIR"
        cp "$stage_dir/vcad_kernel_wasm_bg.wasm" "$AXIS_VCAD_DIAGNOSTIC_DIR/source-built-vcad_kernel_wasm_bg.wasm"
        cp "$runtime_dir/vcad_kernel_wasm_bg.wasm" "$AXIS_VCAD_DIAGNOSTIC_DIR/checked-in-vcad_kernel_wasm_bg.wasm"
      fi
      echo "The checked-in WebAssembly kernel does not match a clean source build." >&2
      exit 1
    fi
    ;;
  install)
    cp "$stage_dir/vcad_kernel_wasm.js" "$runtime_dir/vcad_kernel_wasm.js"
    cp "$stage_dir/vcad_kernel_wasm_bg.wasm" "$runtime_dir/vcad_kernel_wasm_bg.wasm"
    echo "Installed the source-built geometry kernel in $runtime_dir."
    ;;
  *)
    echo "Usage: $0 [check|install]" >&2
    exit 2
    ;;
esac
