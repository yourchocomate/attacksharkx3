#!/bin/bash
# Wrap the asctl binary in a .app bundle.
#
# The GUI runs fine as a bare binary, but macOS attributes privacy permissions
# to the *requesting process*. Launched from a terminal, Input Monitoring and
# Bluetooth get attributed to the terminal, which means every terminal you own
# inherits them and the prompts name the wrong app. A bundle gets its own
# identity and its own entries in System Settings.
#
# Usage:  Scripts/make-app.sh [output-dir]      (default: build/)
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-build}"
APP="$OUT/asctl.app"

echo "building release binary…"
swift build -c release

# SwiftPM does not treat Info.plist as a build input — it is linked in via
# -sectcreate — so a stale binary can survive a plist edit. Force the relink.
rm -f .build/release/asctl
swift build -c release

echo "rendering the app icon…"
ICONSET="$OUT/asctl.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift Scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$OUT/asctl.icns"
rm -rf "$ICONSET"

echo "assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/asctl "$APP/Contents/MacOS/asctl"
cp Sources/asctl/Info.plist "$APP/Contents/Info.plist"
cp "$OUT/asctl.icns" "$APP/Contents/Resources/asctl.icns"

# A bundled app needs the keys a bare binary does not: a package type, and the
# high-resolution flag so the window is not rendered at 1x on a Retina display.
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 12.0" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string asctl" "$APP/Contents/Info.plist" 2>/dev/null || true

printf 'APPL????' > "$APP/Contents/PkgInfo"

# The bundle launches straight into the GUI; the same binary still takes CLI
# subcommands when invoked directly.
cat > "$APP/Contents/MacOS/launch" <<'LAUNCH'
#!/bin/bash
exec "$(dirname "$0")/asctl" gui
LAUNCH
chmod +x "$APP/Contents/MacOS/launch"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable launch" "$APP/Contents/Info.plist"

# Ad-hoc signing keeps the TCC grant stable across rebuilds. Without a stable
# signature macOS treats each rebuild as a different app and re-prompts.
codesign --force --deep --sign - "$APP" 2>/dev/null \
  && echo "signed (ad-hoc)" \
  || echo "note: codesign failed — the app still runs, but permissions may re-prompt after each rebuild"

echo
echo "done: $APP"
echo "run it with:  open $APP"
echo
echo "On first launch, grant these in System Settings ▸ Privacy & Security:"
echo "  • Input Monitoring  — for the 2.4 GHz receiver and USB cable"
echo "  • Bluetooth         — for the --ble transport and battery"
