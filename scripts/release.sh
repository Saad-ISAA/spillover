#!/bin/sh
# Package a release of Spillover for GitHub Releases and Homebrew.
#
#   scripts/release.sh
#
# Builds a universal Spillover.app (Apple silicon and Intel) and writes to dist/release/:
#   Spillover-<version>.dmg   open it and drag Spillover to Applications
#   Spillover-<version>.zip   the same app, zipped
#   SHA256SUMS                checksums of both
#   spillover.rb              the Homebrew cask for this version (copy it into the tap)
#
# The version comes from Sources/spillover/main.swift. The working tree must be clean, so the
# release matches a commit (ALLOW_DIRTY=1 skips that check for a trial run).
#
# Signing and notarization (optional, needs an Apple Developer ID):
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE=<profile saved with: xcrun notarytool store-credentials>
# With both set, the app and the disk image are signed, notarized and stapled, so they open
# without a Gatekeeper prompt. Without them the build is ad-hoc signed.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
VERSION=$(sed -n 's/^let version = "\(.*\)"$/\1/p' Sources/spillover/main.swift)
[ -n "$VERSION" ] || { echo "release: no version in Sources/spillover/main.swift" >&2; exit 1; }
if [ "${ALLOW_DIRTY:-0}" != 1 ] && [ -n "$(git status --porcelain)" ]; then
    echo "release: commit or stash your changes first (or ALLOW_DIRTY=1 for a trial run)" >&2
    exit 1
fi
if [ -n "${NOTARY_PROFILE:-}" ] && [ -z "${SIGN_IDENTITY:-}" ]; then
    echo "release: NOTARY_PROFILE needs SIGN_IDENTITY (a Developer ID Application identity)" >&2
    exit 1
fi

APP="$ROOT/dist/Spillover.app"
OUT="$ROOT/dist/release"
NAME="Spillover-$VERSION"

UNIVERSAL=1 scripts/build-app.sh
lipo -info "$APP/Contents/MacOS/Spillover"

rm -rf "${OUT:?}"
mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK:?}"' EXIT

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

# Notarize the app itself first, so the ticket is stapled into the bundle that goes into both
# the zip and the disk image.
if [ -n "${NOTARY_PROFILE:-}" ]; then
    ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
    notarize "$WORK/notarize.zip"
    xcrun stapler staple "$APP"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$NAME.zip"

# Disk image: the app next to a link to /Applications.
mkdir -p "$WORK/dmg"
cp -R "$APP" "$WORK/dmg/"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -quiet -volname "Spillover $VERSION" -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO \
    -ov "$OUT/$NAME.dmg"
if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$OUT/$NAME.dmg"
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
    notarize "$OUT/$NAME.dmg"
    xcrun stapler staple "$OUT/$NAME.dmg"
fi

(cd "$OUT" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS)
DMG_SHA=$(shasum -a 256 "$OUT/$NAME.dmg" | cut -d' ' -f1)
sed -e "s/@VERSION@/$VERSION/g" -e "s/@SHA256@/$DMG_SHA/g" packaging/homebrew/spillover.rb.in \
    > "$OUT/spillover.rb"

echo
echo "Release $VERSION in $OUT:"
ls -lh "$OUT"
if [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "Not notarized: first launch on other Macs needs approval in System Settings > Privacy & Security."
fi
