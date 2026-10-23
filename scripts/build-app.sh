#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
swift build --build-system native -c "$configuration" --product InfraTerminal
bin_dir="$(swift build --build-system native -c "$configuration" --show-bin-path)"
app="$PWD/dist/Infra Terminal.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources/Licenses"
cp "$bin_dir/InfraTerminal" "$app/Contents/MacOS/InfraTerminal"
install -m 755 scripts/luluTerminalAskPass "$app/Contents/Helpers/luluTerminalAskPass"
bash scripts/build-askpass-helper.sh "$app/Contents/Helpers/luluTerminalKeychain"
bash scripts/make-icon.sh Resources/AppIcon.png "$app/Contents/Resources/AppIcon.icns"
for resource in "$bin_dir"/*.bundle; do
    [ -d "$resource" ] || continue
    ditto "$resource" "$app/Contents/Resources/$(basename "$resource")"
done
python3 scripts/check-licenses.py
install -m 644 docs/THIRD_PARTY.md "$app/Contents/Resources/Licenses/THIRD_PARTY.md"
for notice in docs/licenses/*.txt; do
    install -m 644 "$notice" "$app/Contents/Resources/Licenses/$(basename "$notice")"
done
(
    export LC_ALL=C
    cat docs/THIRD_PARTY.md
    for notice in docs/licenses/*.txt; do
        printf '\n\n===== %s =====\n\n' "$(basename "$notice")"
        cat "$notice"
    done
) > "$app/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.txt"
python3 scripts/check-licenses.py --app "$app"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>InfraTerminal</string>
  <key>CFBundleIdentifier</key><string>dev.chanyoung.infra-terminal</string>
  <key>CFBundleName</key><string>luluTerminal</string>
  <key>CFBundleDisplayName</key><string>luluTerminal</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
# Sign the wrapper separately; preserve the already signed Keychain helper.
codesign --force --sign - "$app/Contents/Helpers/luluTerminalAskPass"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
