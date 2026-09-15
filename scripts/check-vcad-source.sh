#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_root="$project_root/third_party/vcad-source/vcad"

if ! command -v cargo >/dev/null 2>&1; then
  echo "Rust 1.97.1 is required to check the vendored geometry source." >&2
  exit 1
fi

case "$(rustc --version)" in
  "rustc 1.97.1 "*) ;;
  *)
    echo "Expected Rust 1.97.1; found $(rustc --version)." >&2
    exit 1
    ;;
esac

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$source_root/target}"
cargo check --locked --manifest-path "$source_root/Cargo.toml" \
  -p axis-kernel-wasm --target wasm32-unknown-unknown
cargo fmt --manifest-path "$source_root/Cargo.toml" --all -- --check

echo "Vendored Axis CAD geometry source compiled successfully."
