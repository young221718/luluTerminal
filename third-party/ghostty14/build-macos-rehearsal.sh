#!/bin/bash
# Run only on private staged sources: upstream scripts clear staged build outputs.
set -euo pipefail
WRAPPER=${1:?usage: build-macos-rehearsal.sh <private-wrapper> <private-engine> <zig-bin> <private-output-root>}
ENGINE=${2:?}
ZIG_BIN=${3:?}
OUTPUT_ROOT=${4:?}
SCRIPT_ROOT=$(cd "$(dirname "$0")" && pwd)
: "${DEVELOPER_DIR:=$(xcode-select -p)}"
export DEVELOPER_DIR
export PATH="$(dirname "$ZIG_BIN"):/usr/bin:/bin:/usr/sbin:/sbin"
export BUILD_CACHE_ROOT="$OUTPUT_ROOT/cache"
export ZIG_GLOBAL_CACHE_DIR="$BUILD_CACHE_ROOT/zig-global"
export ZIG_BUILD_EXTRA_ARGS=-j2
[[ $(git -C "$ENGINE" rev-parse HEAD) == 83fb95624b0439ee660c2679b43b38c8b63769cd ]]
[[ $(git -C "$WRAPPER" rev-parse HEAD) == 5b9cb63d83e687b4a66d6c3a3c2a840341c576d9 ]]
[[ $("$ZIG_BIN" version) == 0.17.0 ]]
cd "$WRAPPER"
./Script/build-platform.sh "$ENGINE" macos "$OUTPUT_ROOT/artifacts"
./Script/merge-xcframework.sh "$OUTPUT_ROOT/artifacts" "$WRAPPER/BinaryTarget/GhosttyKit.xcframework" "$OUTPUT_ROOT/GhosttyKit.xcframework.zip"
python3 "$SCRIPT_ROOT/generate-provenance.py" "$WRAPPER" "$ENGINE" "$ZIG_BIN"
