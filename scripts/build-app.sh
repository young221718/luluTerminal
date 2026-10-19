#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
swift build --build-system native -c "$configuration" --product InfraTerminal
bin_dir="$(swift build --build-system native -c "$configuration" --show-bin-path)"
app="$PWD/dist/Infra Terminal.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Licenses"
cp "$bin_dir/InfraTerminal" "$app/Contents/MacOS/InfraTerminal"
bash scripts/make-icon.sh Resources/AppIcon.png "$app/Contents/Resources/AppIcon.icns"
for resource in "$bin_dir"/*.bundle; do
    [ -d "$resource" ] || continue
    ditto "$resource" "$app/Contents/Resources/$(basename "$resource")"
done
install -m 644 docs/THIRD_PARTY.md "$app/Contents/Resources/Licenses/THIRD_PARTY.md"
for dependency in libghostty-spm DisplayLink; do
    install -m 644 ".build/checkouts/$dependency/LICENSE" "$app/Contents/Resources/Licenses/$dependency.txt"
done
install -m 644 docs/licenses/Ghostty.txt "$app/Contents/Resources/Licenses/Ghostty.txt"
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
codesign --force --deep --sign - "$app"
printf '%s\n' "$app"
