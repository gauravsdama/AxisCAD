#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
install=false
build=false
package=false
verify=false
assume_yes=false

usage() {
  printf '%s\n' \
    'Usage: ./scripts/setup_macos.sh [--check] [--install] [--build] [--package] [--verify] [--yes]' \
    '' \
    '  --check    Inspect this Mac without changing it (default).' \
    '  --install  Install locked Node dependencies in this checkout.' \
    '  --build    Build the web reference and native release executable.' \
    '  --package  Create the self-contained, ad-hoc signed AxisCAD.app.' \
    '  --verify   Run the complete test, conformance, build, and package gate.' \
    '  --yes      Accept prompts; intended for an already-reviewed command.'
}

for arg in "$@"; do
  case "$arg" in
    --check) ;;
    --install) install=true ;;
    --build) build=true ;;
    --package) package=true ;;
    --verify) verify=true ;;
    --yes) assume_yes=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ $(uname -s) != Darwin ]]; then
  printf '%s\n' 'This setup helper supports macOS only.' >&2
  exit 2
fi

macos_version=$(sw_vers -productVersion)
macos_major=${macos_version%%.*}
arch=$(uname -m)
memory_bytes=$(sysctl -n hw.memsize)
memory_gib=$((memory_bytes / 1024 / 1024 / 1024))
free_kib=$(df -Pk "$project_dir" | awk 'NR == 2 {print $4}')
free_gib=$((free_kib / 1024 / 1024))
printf 'macOS %s, %s, %s GiB memory, %s GiB free disk\n' \
  "$macos_version" "$arch" "$memory_gib" "$free_gib"

(( macos_major >= 14 )) || printf '%s\n' 'Axis CAD requires macOS 14 or later.' >&2
printf 'Package architecture: %s (build on each target Mac architecture)\n' "$arch"
(( memory_gib >= 8 )) || printf '%s\n' 'At least 8 GiB memory is recommended for CAD and kernel work.' >&2
(( free_gib >= 3 )) || printf '%s\n' 'Keep at least 3 GiB free for dependencies and build products.' >&2

for command in node npm swift deno; do
  if command -v "$command" >/dev/null 2>&1; then
    printf '%s: available\n' "$command"
  else
    printf '%s: missing\n' "$command" >&2
  fi
done
if command -v cargo >/dev/null 2>&1 || [[ -x "$HOME/.cargo/bin/cargo" ]]; then
  printf '%s\n' 'cargo: available'
else
  printf '%s\n' 'cargo: missing' >&2
fi
if ! command -v swift >/dev/null 2>&1; then
  printf '%s\n' 'Install Xcode Command Line Tools with: xcode-select --install'
fi
if ! command -v node >/dev/null 2>&1; then
  printf '%s\n' 'Install Node.js 22 or later with: brew install node@22'
fi
if ! command -v deno >/dev/null 2>&1; then
  printf '%s\n' 'Deno is required only to compile the standalone kernel worker: brew install deno'
fi
if ! command -v cargo >/dev/null 2>&1; then
  printf '%s\n' 'Rust is needed only for the independent STEP conformance reader: brew install rust'
fi

if ! $install && ! $build && ! $package && ! $verify; then
  printf '%s\n' 'Check complete. No files or packages were changed.'
  exit 0
fi

confirm() {
  local prompt=$1
  if $assume_yes; then return 0; fi
  printf '%s [y/N] ' "$prompt"
  read -r reply
  [[ "$reply" == [Yy] || "$reply" == [Yy][Ee][Ss] ]]
}

cd "$project_dir"
if $install; then
  command -v npm >/dev/null 2>&1 || { printf '%s\n' 'npm is required.' >&2; exit 1; }
  confirm 'Install the locked Node dependencies in this checkout?' || exit 0
  npm ci
fi
if $build; then
  confirm 'Build the Axis CAD web reference and native release executable?' || exit 0
  npm run build
  npm run native:build
fi
if $package; then
  command -v deno >/dev/null 2>&1 || { printf '%s\n' 'Deno is required for packaging.' >&2; exit 1; }
  confirm 'Create and ad-hoc sign the self-contained AxisCAD.app?' || exit 0
  npm run native:package
fi
if $verify; then
  if ! command -v cargo >/dev/null 2>&1 && [[ ! -x "$HOME/.cargo/bin/cargo" ]]; then
    printf '%s\n' 'cargo is required for STEP conformance.' >&2
    exit 1
  fi
  confirm 'Run the complete Axis CAD release gate?' || exit 0
  npm run check
fi

printf '%s\n' 'Setup complete. Build products remain ignored by Git.'
