#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
kernel_dir="$project_root/third_party/vcad-kernel"
expected_js="8c3869784e6062bdb416cbc27e7786b2bd188eda078793da9db92aebb9a983bb"
expected_wasm="7ae23e8d289447af16d314541c8d2fb57ae477fbed75b6048cfdbabd522a826e"

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
