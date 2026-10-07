#!/usr/bin/env bash
# Verify an exact asset in a pinned SHA-256 manifest before extracting/executing.
set -euo pipefail
file="$1" asset="$2" manifest="$3"
expected="$(awk -v asset="$asset" '
  NF == 0 { next }
  { sub(/\r$/, ""); if (NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-fA-F]/) { bad=1; exit }
    name=$2; sub(/^\*/, "", name); if (name == asset) { hash=tolower($1); count++ } }
  END { if (bad || count != 1) exit 1; print hash }
' "$manifest")" || { echo "Missing, malformed, or duplicate checksum for $asset" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$file")"
elif command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "$file")"
else
  echo "A SHA-256 utility is required" >&2; exit 1
fi
[[ "${actual%% *}" == "$expected" ]] || { echo "Checksum mismatch for $asset" >&2; exit 1; }
