#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
app_version="${APP_VERSION-0.1.0}"
app_build_number="${APP_BUILD_NUMBER-1}"
if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "APP_VERSION must be a numeric version such as 0.1.0." >&2
    exit 1
fi
if [[ ! "$app_build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "APP_BUILD_NUMBER must be a positive integer." >&2
    exit 1
fi
swift build --build-system native -c "$configuration" --product InfraTerminal
bin_dir="$(swift build --build-system native -c "$configuration" --show-bin-path)"
app="$PWD/dist/Infra Terminal.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Licenses"
cp "$bin_dir/InfraTerminal" "$app/Contents/MacOS/InfraTerminal"
# Incremental builds must not ship helpers left by older app bundles.
rm -f "$app/Contents/Helpers/luluTerminalAskPass" "$app/Contents/Helpers/luluTerminalKeychain"
bash scripts/make-icon.sh Resources/AppIcon.png "$app/Contents/Resources/AppIcon.icns"
for resource in "$bin_dir"/*.bundle; do
    [ -d "$resource" ] || continue
    ditto "$resource" "$app/Contents/Resources/$(basename "$resource")"
done
python3 scripts/check-licenses.py --copy-notices-to "$app/Contents/Resources/Licenses"
python3 scripts/check-licenses.py --app "$app"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>InfraTerminal</string>
  <key>CFBundleIdentifier</key><string>dev.chanyoung.infra-terminal</string>
  <key>CFBundleName</key><string>luluTerminal</string>
  <key>CFBundleDisplayName</key><string>luluTerminal</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$app_version</string>
  <key>CFBundleVersion</key><string>$app_build_number</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$app_version"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" = "$app_build_number"
python3 scripts/check-no-keychain.py --app "$app"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
