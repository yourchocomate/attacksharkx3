#!/bin/bash
# Remove asctl.
#
# Dragging an app to the Bin leaves behind whatever it installed elsewhere, and
# asctl installs two launch agents — one to open itself at login, one for the
# standalone wheel fix. Left running, the scroll agent would keep inverting the
# wheel with nothing visible to blame.
#
# Usage:
#   uninstall.sh              ask whether to keep saved profiles
#   uninstall.sh --keep-data  remove the app, keep ~/.config/asctl
#   uninstall.sh --all        remove everything, including profiles
set -uo pipefail

BUNDLE_ID="io.github.yourchocomate.asctl"
CONFIG="$HOME/.config/asctl"
PREFS="$HOME/Library/Preferences/io.github.yourchocomate.asctl.plist"
AGENTS=(
    "$HOME/Library/LaunchAgents/io.github.yourchocomate.asctl.app.plist"
    "$HOME/Library/LaunchAgents/io.github.yourchocomate.asctl.scroll.plist"
    "$HOME/Library/LaunchAgents/org.opensource.asctl.scroll.plist"   # pre-rename
)
APPS=(
    "/Applications/asctl.app"
    "$HOME/Applications/asctl.app"
    "$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/build/asctl.app"
)

mode="${1:-ask}"

echo "asctl uninstaller"
echo

# What is actually here? Saying "removed" for things that were never installed
# is how an uninstaller ends up trusted less than it should be.
found_any=false
for app in "${APPS[@]}"; do
    [ -d "$app" ] && { echo "  app:    $app"; found_any=true; }
done
for agent in "${AGENTS[@]}"; do
    [ -f "$agent" ] && { echo "  agent:  $agent"; found_any=true; }
done
[ -f "$PREFS" ] && { echo "  prefs:  $PREFS"; found_any=true; }
if [ -d "$CONFIG" ]; then
    count=$(ls -1 "$CONFIG/profiles" 2>/dev/null | grep -c '\.json$' || echo 0)
    echo "  data:   $CONFIG  ($count profile(s))"
    found_any=true
fi

if [ "$found_any" = false ]; then
    echo "  nothing found — asctl does not appear to be installed."
    exit 0
fi

echo
case "$mode" in
    --all)       keep_data=false ;;
    --keep-data) keep_data=true ;;
    *)
        if [ -d "$CONFIG" ]; then
            echo "Your profiles live in $CONFIG."
            echo "The mouse cannot be read back, so that folder is the only record"
            echo "of a configuration that exists anywhere."
            echo
            read -r -p "Keep it for a future reinstall? [Y/n] " answer
            case "$answer" in [Nn]*) keep_data=false ;; *) keep_data=true ;; esac
        else
            keep_data=true
        fi
        ;;
esac

echo
echo "stopping anything that is running…"
# Match the process name, not the command line.
#
# This used to grep for "asctl gui", which never matched: the bundled app is
# launched by macOS with no arguments at all, so its command line is just the
# path. The uninstaller went straight on to delete an app that was still
# running, leaving the menu bar item behind until the user logged out.
pkill -x asctl 2>/dev/null && echo "  quit the app"
pkill -f "asctl scroll" 2>/dev/null && echo "  stopped the wheel fix"
# Give the event tap and the HID handles a moment to go.
sleep 1

for agent in "${AGENTS[@]}"; do
    if [ -f "$agent" ]; then
        label="$(basename "$agent" .plist)"
        launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
        launchctl unload "$agent" 2>/dev/null     # older macOS
        rm -f "$agent" && echo "  removed $(basename "$agent")"
    fi
done

# Revoke the Privacy & Security entries.
#
# Must happen before the app is deleted: tccutil resolves the bundle
# identifier through LaunchServices, which stops knowing it once the bundle is
# gone. Needs no sudo — these are the user's own grants.
if command -v tccutil >/dev/null 2>&1; then
    if tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1; then
        echo "  revoked Input Monitoring, Bluetooth and Accessibility"
    fi
fi

for app in "${APPS[@]}"; do
    if [ -d "$app" ]; then
        rm -rf "$app" && echo "  removed $app"
    fi
done

[ -f "$PREFS" ] && rm -f "$PREFS" && echo "  removed window preferences"

if [ "$keep_data" = true ]; then
    if [ -d "$CONFIG" ]; then
        echo
        echo "kept $CONFIG — a reinstall will pick your profiles up again."
    fi
else
    rm -rf "$CONFIG" && echo "  removed $CONFIG"
fi

echo
echo "done."
echo
echo "One thing this cannot do for you:"
echo "  Any setting already written to the mouse stays on the mouse. The"
echo "  protocol has no readback and no factory reset, so the device keeps"
echo "  whatever it was last told until something writes over it."
