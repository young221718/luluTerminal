#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -ne 2 ]; then
    printf 'Usage: %s source.png destination.icns\n' "$0" >&2
    exit 1
fi
source_png="$1"
destination_icns="$2"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/luluterminal-icon.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT
iconset="$temporary_dir/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$source_png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" "$source_png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$iconset" --output "$destination_icns"
