#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
native_root="${script_dir:h}"
project_root="${native_root:h}"
app_root="$native_root/build/AxisCAD.app"
kernel_source="$project_root/third_party/vcad-kernel"
kernel_target="$app_root/Contents/Resources/kernel-wasm"
icon_source="$native_root/Assets/AxisCADIcon.svg"
package_temp="$(mktemp -d -t axis-cad-package)"
package_lock="$native_root/build/.axis-cad-package.lock"
lock_owner=""

acquire_package_lock() {
  local attempts=0
  while ! mkdir "$package_lock" 2>/dev/null; do
    local owner=""
    [[ -f "$package_lock/pid" ]] && owner="$(<"$package_lock/pid")"
    if [[ "$owner" == <-> ]] && ! kill -0 "$owner" 2>/dev/null; then
      /bin/rm -rf -- "$package_lock"
      continue
    fi
    attempts=$((attempts + 1))
    if (( attempts > 120 )); then
      echo "AxisCAD packaging is already running; timed out waiting for its release lock." >&2
      exit 1
    fi
    sleep 1
  done
  lock_owner="$$"
  printf '%s' "$lock_owner" > "$package_lock/pid"
}

cleanup() {
  case "$package_temp" in
    /var/folders/*/T/axis-cad-package.*) /bin/rm -rf -- "$package_temp" ;;
  esac
  if [[ "$lock_owner" == "$$" ]]; then
    /bin/rm -rf -- "$package_lock"
  fi
}
trap cleanup EXIT

mkdir -p "$native_root/build"
acquire_package_lock

python3 "$native_root/scripts/inventory-swift-ui-copy.py" \
  --source "$native_root/Sources" \
  --output "$project_root/docs/product/UI_COPY_FULL.md" \
  --name 'Axis CAD' --check

deno_bin="$(command -v deno || true)"
if [[ -z "$deno_bin" || ! -x "$deno_bin" ]]; then
  echo "AxisCAD packaging requires Deno to compile the standalone kernel worker." >&2
  exit 1
fi
"$project_root/scripts/verify-vcad-kernel.sh"
for kernel_file in package.json vcad_kernel_wasm.js vcad_kernel_wasm_bg.wasm; do
  if [[ ! -f "$kernel_source/$kernel_file" ]]; then
    echo "Missing vcad kernel artifact: $kernel_source/$kernel_file" >&2
    exit 1
  fi
done
if [[ ! -f "$icon_source" ]]; then
  echo "Missing Axis CAD app icon source: $icon_source" >&2
  exit 1
fi

swift build --package-path "$native_root" -c release
mkdir -p "$app_root/Contents/MacOS" "$app_root/Contents/Resources" "$kernel_target"
cp "$native_root/.build/release/AxisCAD" "$app_root/Contents/MacOS/AxisCAD"
cp "$native_root/Info.plist" "$app_root/Contents/Info.plist"
cp "$project_root/LICENSE" "$app_root/Contents/Resources/LICENSE.txt"
cp "$project_root/NOTICE" "$app_root/Contents/Resources/NOTICE.txt"
cp "$project_root/kernel/vcad-kernel.mjs" "$app_root/Contents/Resources/vcad-kernel.mjs"
cp "$kernel_source/package.json" "$kernel_target/package.json"
cp "$kernel_source/vcad_kernel_wasm.js" "$kernel_target/vcad_kernel_wasm.js"
cp "$kernel_source/vcad_kernel_wasm_bg.wasm" "$kernel_target/vcad_kernel_wasm_bg.wasm"
cp "$kernel_source/LICENSE" "$kernel_target/LICENSE.txt"
cp "$kernel_source/THIRD_PARTY_NOTICES.md" "$kernel_target/THIRD_PARTY_NOTICES.md"
cp "$kernel_source/UPSTREAM_NOTICE" "$kernel_target/UPSTREAM_NOTICE.txt"
cp "$project_root/third_party/vcad-source/tang/LICENSE" "$kernel_target/TANG_LICENSE.txt"

iconset="$package_temp/AxisCAD.iconset"
master_icon="$package_temp/AxisCADIcon-1024.png"
mkdir -p "$iconset"
sips -s format png "$icon_source" --out "$master_icon" >/dev/null
for icon_size in 16 32 128 256 512; do
  sips -z "$icon_size" "$icon_size" "$master_icon" --out "$iconset/icon_${icon_size}x${icon_size}.png" >/dev/null
  double_size=$((icon_size * 2))
  sips -z "$double_size" "$double_size" "$master_icon" --out "$iconset/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app_root/Contents/Resources/AxisCAD.icns"

"$deno_bin" compile --quiet --no-check --no-config --node-modules-dir=none \
  --exclude "$project_root/node_modules" --allow-read --allow-write --allow-env --allow-sys \
  --output "$app_root/Contents/MacOS/AxisKernelWorker" "$project_root/kernel/vcad-kernel.mjs"

status_json="$(printf '%s' '{"action":"status"}' | env -i \
  AXIS_CAD_COMPILED_WORKER=1 AXIS_CAD_BUNDLED_KERNEL=1 \
  AXIS_VCAD_KERNEL_DIR="$kernel_target" \
  "$app_root/Contents/MacOS/AxisKernelWorker")"
if [[ "$status_json" != *'"available":true'* || "$status_json" != *'"bundled_with_app":true'* ]]; then
  echo "Packaged kernel self-check failed: $status_json" >&2
  exit 1
fi
for notice_file in LICENSE.txt THIRD_PARTY_NOTICES.md UPSTREAM_NOTICE.txt TANG_LICENSE.txt; do
  if [[ ! -f "$kernel_target/$notice_file" ]]; then
    echo "Packaged kernel notice is missing: $notice_file" >&2
    exit 1
  fi
done

fixture_path="$package_temp/package-check.json"
printf '%s' '{"id":"package-check","name":"Package check","units":"mm","backend":"native-metal","revision":1,"features":[{"id":"box","kind":"box","name":"10 mm box","visible":true,"params":{"width":10,"height":10,"depth":10,"x":0,"y":0,"z":0}}],"operations":[]}' > "$fixture_path"
validation_json="$(printf '{"action":"validate","document_path":"%s","feature_id":"box"}' "$fixture_path" | env -i \
  AXIS_CAD_COMPILED_WORKER=1 AXIS_CAD_BUNDLED_KERNEL=1 \
  AXIS_VCAD_KERNEL_DIR="$kernel_target" \
  "$app_root/Contents/MacOS/AxisKernelWorker")"
if [[ "$validation_json" != *'"ok":true'* || "$validation_json" != *'"closed_manifold_mesh":true'* || "$validation_json" != *'"passed":true'* ]]; then
  echo "Packaged BRep/STEP self-check failed: $validation_json" >&2
  exit 1
fi

codesign --force --sign - "$app_root/Contents/MacOS/AxisKernelWorker"
codesign --force --deep --sign - "$app_root"
codesign --verify --deep --strict "$app_root"
echo "$app_root"
