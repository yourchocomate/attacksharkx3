#!/bin/bash
# Build a drag-to-install disk image.
#
# macOS has no AppImage equivalent; the native answer is a .dmg holding the app
# next to a symlink to /Applications, so installing is one drag. A .pkg would
# also work but needs an installer certificate to avoid frightening warnings,
# and gains nothing for an app that is just a bundle.
#
# Usage:  Scripts/make-dmg.sh [output-dir]     (default: build/)
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-build}"
NAME="asctl"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    Sources/asctl/Info.plist 2>/dev/null || echo "0.1.0")"
DMG="$OUT/${NAME}-${VERSION}.dmg"
STAGE="$OUT/dmg-stage"

./Scripts/make-app.sh "$OUT" >/dev/null
echo "staging the disk image"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$OUT/$NAME.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Ship the uninstaller alongside the app. Someone who dragged an app in has no
# other way to find out that it also wrote a login agent.
cp Scripts/uninstall.sh "$STAGE/uninstall.sh"
chmod +x "$STAGE/uninstall.sh"

cat > "$STAGE/README.txt" <<'TEXT'
asctl — Attack Shark X3 for macOS

Install
  Drag asctl.app onto the Applications folder.

First launch — macOS will block it once
  This build is signed ad-hoc, not notarised (notarising needs a paid Apple
  Developer ID). Gatekeeper refuses it until you say otherwise. Either:

  a) Open Terminal and run, in one line:
         xattr -dr com.apple.quarantine /Applications/asctl.app
     Then open the app normally. This always works.

  b) Or double-click, let it be refused, then go to
     System Settings > Privacy & Security, scroll to Security, and press
     "Open Anyway" next to the message about asctl.

  Right-clicking and choosing Open used to be enough. On current macOS it is
  not, so ignore that advice if you find it elsewhere.

  Grant these when asked, in System Settings > Privacy & Security:
    Input Monitoring  - configuring over the 2.4GHz receiver or USB cable
    Bluetooth         - configuring over GATT, and the battery level
    Accessibility     - only if you use the wheel-direction fix

Uninstall
  Run uninstall.sh from this disk image, or from a checkout of the source.
  It asks whether to keep your saved profiles.

Your data
  ~/.config/asctl holds profiles and the record of the last configuration
  written. The mouse cannot be read back, so that folder is the only record
  of a configuration that exists anywhere.
TEXT

echo "building $DMG"
hdiutil create -quiet -volname "$NAME $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo
echo "done: $DMG  ($(du -h "$DMG" | cut -f1))"
echo
echo "Ad-hoc signed, not notarised. First launch is blocked until either"
echo "  xattr -dr com.apple.quarantine /Applications/asctl.app"
echo "or System Settings > Privacy & Security > Open Anyway."
