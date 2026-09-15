#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
kernel_dir="$project_root/third_party/vcad-kernel"
expected_js="3962fe53b04b2ee7c48e68b271411259f6a8a5f2327e3a0e2d41ec17fd8734fd"
expected_wasm="2faba958aa8bfdfe962b62a325be77a462d384b16f73859883f56afe5e7968c3"

verify_file() {
  file_path=$1
  expected=$2
  if [ ! -f "$file_path" ]; then
    echo "Missing pinned vcad kernel file: $file_path" >&2
    exit 1
  fi
  actual=$(shasum -a 256 "$file_path" | cut -d ' ' -f 1)
  if [ "$actual" != "$expected" ]; then
    echo "Pinned vcad kernel checksum mismatch: $file_path" >&2
    exit 1
  fi
}

verify_file "$kernel_dir/vcad_kernel_wasm.js" "$expected_js"
verify_file "$kernel_dir/vcad_kernel_wasm_bg.wasm" "$expected_wasm"

for required_file in LICENSE THIRD_PARTY_NOTICES.md UPSTREAM_NOTICE package.json; do
  if [ ! -f "$kernel_dir/$required_file" ]; then
    echo "Missing vcad attribution file: $kernel_dir/$required_file" >&2
    exit 1
  fi
done

for source_file in \
  "$project_root/third_party/vcad-source/REVISION" \
  "$project_root/third_party/vcad-source/vcad/LICENSE" \
  "$project_root/third_party/vcad-source/tang/LICENSE" \
  "$project_root/third_party/vcad-source/vcad/crates/axis-kernel-wasm/Cargo.toml" \
  "$project_root/third_party/vcad-source/vcad/crates/axis-kernel-wasm/src/lib.rs"; do
  if [ ! -f "$source_file" ]; then
    echo "Missing vendored vcad source boundary: $source_file" >&2
    exit 1
  fi
done

if find "$project_root/third_party/vcad-source" -type l | grep -q .; then
  echo "The vcad source boundary must not depend on symlinks outside the repository." >&2
  exit 1
fi

if ! grep -q '"license": "Apache-2.0"' "$kernel_dir/package.json"; then
  echo "vcad package metadata must retain the conservative Apache-2.0 release license." >&2
  exit 1
fi

if strings "$kernel_dir/vcad_kernel_wasm_bg.wasm" | grep -q '/Users/'; then
  echo "vcad kernel contains a local macOS build path." >&2
  exit 1
fi

if grep -q '/Users/' "$kernel_dir/vcad_kernel_wasm.js"; then
  echo "vcad JavaScript binding contains a local macOS build path." >&2
  exit 1
fi

echo "Pinned vcad kernel checksums verified."
