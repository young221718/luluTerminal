#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="${1:?Expected the helper output path}"
# Exclude UI sources, build-path strings and Mach-O UUIDs from this code identity.
xcrun swiftc -O -whole-module-optimization -gnone -parse-as-library \
  -module-name InfraSSHAskpass -target "$(uname -m)-apple-macosx14.0" \
  -file-prefix-map "$PWD=/luluTerminal" -Xlinker -no_uuid \
  Sources/InfraCore/*.swift Sources/InfraSSHAskpass/AskpassEntry.swift -o "$output"
codesign --force --sign - --identifier dev.chanyoung.infra-terminal.keychain "$output"
codesign --verify --strict "$output"
