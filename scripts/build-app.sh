#!/bin/sh
# Build Spillover.app into dist/. Needs only Xcode or the Command Line Tools.
#
#   scripts/build-app.sh            release build, ad-hoc signed (no Apple developer account)
#   SIGN_IDENTITY="Developer ID Application: ..." scripts/build-app.sh   sign with a real identity
#   UNIVERSAL=1 scripts/build-app.sh   one binary for Apple silicon and Intel (used for releases)
#
# The bundle contains the menu bar app plus the `spillover` CLI and the `spillover-launch`
# launcher, which the app installs into ~/.spillover/bin when you connect an editor or terminal.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$(sed -n 's/^let version = "\(.*\)"$/\1/p' "$ROOT/Sources/spillover/main.swift")
APP="$ROOT/dist/Spillover.app"
IDENTITY=${SIGN_IDENTITY:--}

ARCH_FLAGS=""
[ "${UNIVERSAL:-0}" = 1 ] && ARCH_FLAGS="--arch arm64 --arch x86_64"

cd "$ROOT"
# shellcheck disable=SC2086
for product in SpilloverApp spillover spillover-launch; do
    swift build -c release $ARCH_FLAGS --product "$product"
done
# shellcheck disable=SC2086
BIN=$(swift build -c release $ARCH_FLAGS --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/SpilloverApp" "$APP/Contents/MacOS/Spillover"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Helpers live in Contents/Helpers: "spillover" and "Spillover" would be the same file in
# Contents/MacOS on a case-insensitive volume.
cp "$BIN/spillover" "$APP/Contents/Helpers/spillover"
cp "$BIN/spillover-launch" "$APP/Contents/Helpers/spillover-launch"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Spillover</string>
    <key>CFBundleDisplayName</key><string>Spillover</string>
    <key>CFBundleIdentifier</key><string>app.spillover.menubar</string>
    <key>CFBundleExecutable</key><string>Spillover</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

# Sign helpers first, then the bundle. "-" is an ad-hoc signature: fine for local use; other
# Macs ask the user to approve the first launch (System Settings > Privacy & Security).
# A real identity also gets a secure timestamp, which notarization requires.
TIMESTAMP=""
[ "$IDENTITY" != "-" ] && TIMESTAMP="--timestamp"
for exe in spillover spillover-launch; do
    codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP "$APP/Contents/Helpers/$exe"
done
codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP ($VERSION)"
echo "Open it with: open \"$APP\""
