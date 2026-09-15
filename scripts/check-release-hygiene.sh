#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"

failed=0
path_list=$(mktemp -t axis-cad-release-files.XXXXXX)
trap 'rm -f "$path_list"' EXIT
git ls-files --cached --others --exclude-standard > "$path_list"
while IFS= read -r file_path; do
  case "$file_path" in
    *.env|*.env.*|*.pem|*.p12|*.sqlite|*.sqlite3|*.db|*cookies*.txt|*Cookies*.txt)
      echo "Release guard rejected private or machine-local file: $file_path" >&2
      failed=1
      ;;
  esac
  if [ -f "$file_path" ] && [ "$(wc -c < "$file_path")" -gt 100000000 ]; then
    echo "Release guard rejected file over 100 MB: $file_path" >&2
    failed=1
  fi
done < "$path_list"

if [ "$failed" -ne 0 ]; then
  exit 1
fi

if rg -v '^scripts/check-release-hygiene\.sh$' "$path_list" \
  | xargs rg -n --no-messages \
      '/Users/[A-Za-z0-9._-]+|gh[pousr]_[0-9A-Za-z]{20,}|AIza[0-9A-Za-z_-]{20,}'; then
  echo "Release guard found a local path or credential-shaped value." >&2
  exit 1
fi

echo "Release hygiene checks passed."
