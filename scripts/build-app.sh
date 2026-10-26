#!/bin/sh
# Build Switchboard.app into dist/. Needs only Xcode or the Command Line Tools.
#
#   scripts/build-app.sh            release build, ad-hoc signed (no Apple developer account)
#   SIGN_IDENTITY="Developer ID Application: ..." scripts/build-app.sh   sign with a real identity
#
# The bundle contains the menu bar app plus the `switchboard` CLI and the `switchboard-launch`
# launcher, which the app installs into ~/.switchboard/bin when you connect an editor or terminal.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$(sed -n 's/^let version = "\(.*\)"$/\1/p' "$ROOT/Sources/switchboard/main.swift")
APP="$ROOT/dist/Switchboard.app"
IDENTITY=${SIGN_IDENTITY:--}

cd "$ROOT"
swift build -c release --product SwitchboardApp
swift build -c release --product switchboard
swift build -c release --product switchboard-launch
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/SwitchboardApp" "$APP/Contents/MacOS/Switchboard"
# Helpers live in Contents/Helpers: "switchboard" and "Switchboard" would be the same file in
# Contents/MacOS on a case-insensitive volume.
cp "$BIN/switchboard" "$APP/Contents/Helpers/switchboard"
cp "$BIN/switchboard-launch" "$APP/Contents/Helpers/switchboard-launch"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Switchboard</string>
    <key>CFBundleDisplayName</key><string>Switchboard</string>
    <key>CFBundleIdentifier</key><string>app.switchboard.menubar</string>
    <key>CFBundleExecutable</key><string>Switchboard</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

# Sign helpers first, then the bundle. "-" is an ad-hoc signature: fine for local use; other
# Macs will ask the user to confirm the first launch (right-click > Open).
for exe in switchboard switchboard-launch; do
    codesign --force --sign "$IDENTITY" --options runtime "$APP/Contents/Helpers/$exe"
done
codesign --force --sign "$IDENTITY" --options runtime "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP ($VERSION)"
echo "Open it with: open \"$APP\""
