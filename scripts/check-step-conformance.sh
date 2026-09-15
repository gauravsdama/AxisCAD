#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
generated_dir="$project_root/conformance/generated"
report_path="$generated_dir/report.json"
cargo_command=$(command -v cargo || true)

if [ -z "$cargo_command" ]; then
  cargo_command="/Users/$(id -un)/.cargo/bin/cargo"
fi

if [ ! -x "$cargo_command" ]; then
  echo "STEP conformance requires Rust cargo on PATH" >&2
  exit 2
fi

node "$project_root/scripts/generate-step-conformance-corpus.mjs" "$generated_dir" >/dev/null
node "$project_root/scripts/generate-step-edge-fixtures.mjs" "$generated_dir"
node "$project_root/scripts/append-nurbs-conformance-case.mjs" "$generated_dir"
if "$cargo_command" run --quiet --locked --manifest-path "$project_root/conformance/step-reader/Cargo.toml" -- "$generated_dir/manifest.json" >"$report_path"; then
  cat "$report_path"
else
  status=$?
  cat "$report_path"
  exit "$status"
fi
