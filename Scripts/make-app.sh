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

# A prebuilt binary can be supplied instead of building here. CI uses this to
# hand over a universal binary lipo'd from two native builds — cross-building
# both architectures in one pass needs full Xcode, which not every machine has.
if [ -n "${ASCTL_BINARY:-}" ]; then
    echo "using the supplied binary: $ASCTL_BINARY"
    BINARY="$ASCTL_BINARY"
else
    echo "building release binary…"
    swift build -c release

    # SwiftPM does not treat Info.plist as a build input — it is linked in via
    # -sectcreate — so a stale binary can survive a plist edit. Force the relink.
    rm -f .build/release/asctl
    swift build -c release
    BINARY=".build/release/asctl"
fi

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

cp "$BINARY" "$APP/Contents/MacOS/asctl"
cp Sources/asctl/Info.plist "$APP/Contents/Info.plist"
cp "$OUT/asctl.icns" "$APP/Contents/Resources/asctl.icns"

# A bundled app needs the keys a bare binary does not: a package type, and the
# high-resolution flag so the window is not rendered at 1x on a Retina display.
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 12.0" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string asctl" "$APP/Contents/Info.plist" 2>/dev/null || true

printf 'APPL????' > "$APP/Contents/PkgInfo"

# No wrapper script. CFBundleExecutable must name the binary that actually
# runs: macOS only treats a process as a bundle's main executable when the two
# match, and otherwise never reads Contents/Info.plist. That meant the Bluetooth
# usage description was invisible and TCC killed the app with SIGABRT the first
# time it touched CoreBluetooth. The binary opens the GUI on its own when it is
# started from inside a bundle with no arguments.
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable asctl" "$APP/Contents/Info.plist"

# Ship the uninstaller inside the bundle.
#
# It also travels in the disk image, but that is ejected and thrown away the
# moment the app is dragged to Applications — after which the only copy is gone
# and Settings' "reveal uninstaller" button pointed at a path that had never
# existed. Keeping one here means the app can always produce it.
cp Scripts/uninstall.sh "$APP/Contents/Resources/uninstall.sh"
chmod +x "$APP/Contents/Resources/uninstall.sh"

# Sign with a certificate when one is available, ad-hoc otherwise.
#
# This decides whether privacy permissions survive an update. An ad-hoc
# signature has no certificate, so the designated requirement macOS records is
# a hash of this exact build — measured: `cdhash H"c55eff…"`. TCC stores that,
# every build hashes differently, and so every update re-prompts for Input
# Monitoring, Bluetooth and Accessibility.
#
# Signing with a certificate, even an untrusted self-signed one, produces
# `identifier "…" and certificate root = H"…"` instead, which is identical for
# every build signed with the same certificate. Verified on two builds with
# different code hashes: the requirement strings matched exactly.
#
# Scripts/make-signing-cert.sh generates the certificate. Gatekeeper is
# unaffected either way — that needs notarisation.
if [ -n "${SIGN_IDENTITY:-}" ]; then
    SIGN_ARGS=(--force --deep --sign "$SIGN_IDENTITY")
    [ -n "${SIGN_KEYCHAIN:-}" ] && SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
    if codesign "${SIGN_ARGS[@]}" "$APP" 2>/dev/null; then
        echo "signed with: $SIGN_IDENTITY"
        codesign -dr - "$APP" 2>&1 | grep designated || true
    else
        echo "error: signing with '$SIGN_IDENTITY' failed" >&2
        exit 1
    fi
else
    codesign --force --deep --sign - "$APP" 2>/dev/null \
      && echo "signed (ad-hoc — permissions will re-prompt after every update;" \
      && echo "         see Scripts/make-signing-cert.sh)" \
      || echo "note: codesign failed — the app still runs, but macOS will treat it as unidentified"
fi

echo
echo "done: $APP"
echo "run it with:  open $APP"
echo
echo "On first launch, grant these in System Settings ▸ Privacy & Security:"
echo "  • Input Monitoring  — for the 2.4 GHz receiver and USB cable"
echo "  • Bluetooth         — for the --ble transport and battery"

# Optional: install it, leaving exactly one asctl on the machine.
#
# The staging bundle carries the same identifier as the installed one, so while
# both exist LaunchServices knows two apps by that identity and Finder and
# Launchpad each offer two asctl entries — one of them a build artefact that
# must never be launched, because it is replaced on every build and holds its
# own TCC grants. Unregistering it does not stick: macOS rescans and re-adds a
# newly created bundle within seconds. Removing it does.
if [ "${INSTALL:-}" = "1" ]; then
    DEST="/Applications/$(basename "$APP")"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    codesign --force --deep --sign - "$DEST" >/dev/null 2>&1 || true
    rm -rf "$APP"
    echo
    echo "installed to $DEST, staging copy removed"
fi
