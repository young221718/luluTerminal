#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
repository="$PWD"
output_root="${1:?usage: prepare-ghostty14.sh <new-output-directory> <zig-0.17.0-executable>}"
zig_bin="${2:?}"
if [ -e "$output_root" ] || [ -L "$output_root" ]; then
    echo "Output already exists; choose a new isolated directory." >&2
    exit 1
fi
if [ "$("$zig_bin" version)" != "0.17.0" ]; then
    echo "Ghostty 1.4 requires Zig 0.17.0." >&2
    exit 1
fi
mkdir -p "$output_root"
output_root="$(cd "$output_root" && pwd)"
inputs="$repository/third-party/ghostty14"
git clone --no-checkout https://github.com/Lakr233/libghostty-spm.git "$output_root/libghostty-spm"
git -C "$output_root/libghostty-spm" checkout --detach 5b9cb63d83e687b4a66d6c3a3c2a840341c576d9
git clone --no-checkout https://github.com/ghostty-org/ghostty.git "$output_root/ghostty"
git -C "$output_root/ghostty" checkout --detach 83fb95624b0439ee660c2679b43b38c8b63769cd
git -C "$output_root/libghostty-spm" apply "$inputs/wrapper-v1.4-port.patch"
git -C "$output_root/libghostty-spm" apply "$inputs/drop-confirmation.patch"
bash "$inputs/build-macos-rehearsal.sh" "$output_root/libghostty-spm" "$output_root/ghostty" "$zig_bin" "$output_root"
cp "$output_root/libghostty-spm/Package.local.swift" "$output_root/libghostty-spm/Package.swift"
python3 scripts/record-ghostty14-manifest.py "$output_root/libghostty-spm" --output "$output_root/manifest-ghostty14.candidate.json"
echo "Built local package: $output_root/libghostty-spm"
echo "Review the generated provenance and refresh manifest-ghostty14.json before app packaging."
