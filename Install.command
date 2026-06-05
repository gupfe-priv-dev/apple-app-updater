#!/bin/bash
# Install.command — bundled inside the release zip alongside UpdateAll.app.
# Double-click in Finder (Terminal opens it). Strips the
# com.apple.quarantine xattr that Safari/Chrome/etc. set on downloaded
# zips, then copies the .app to /Applications, re-registers with Launch
# Services, resets App Management TCC, and launches.
#
# Why this exists alongside the curl one-liner installer at the repo
# root: corporate proxies / cloud-side caches sometimes serve a stale
# version of the raw URL, in which case this script (which acts on the
# .app sitting next to it) sidesteps the URL entirely.

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="UpdateAll"
SRC="./$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

PRIMARY_LANG=$(defaults read -g AppleLanguages 2>/dev/null | grep -m1 -o '"[a-z][a-z]' | tr -d '"' || echo "en")
if [[ "$PRIMARY_LANG" == "de" ]]; then
    T_NOT_FOUND="Konnte $APP_NAME.app neben dem Installer nicht finden."
    T_INSTALLING="Installiere $APP_NAME nach /Applications..."
    T_INSTALLED="✓ Installiert."
    T_LAUNCHING="Wird gestartet..."
    T_DONE="Fertig."
    T_PRESS_KEY="Eine Taste drücken zum Schließen..."
else
    T_NOT_FOUND="Couldn't find $APP_NAME.app next to this installer."
    T_INSTALLING="Installing $APP_NAME to /Applications..."
    T_INSTALLED="✓ Installed."
    T_LAUNCHING="Launching..."
    T_DONE="Done."
    T_PRESS_KEY="Press any key to close..."
fi

echo ""
echo "  $APP_NAME  Installer"
echo "  ────────────────────────"
echo ""

if [[ ! -d "$SRC" ]]; then
    echo "  $T_NOT_FOUND"
    echo ""
    read -n 1 -s -r -p "  $T_PRESS_KEY"
    exit 1
fi

echo "  $T_INSTALLING"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
tccutil reset SystemPolicyAppBundles com.gunnar.update-all >/dev/null 2>&1 || true
echo "  $T_INSTALLED"
echo ""

echo "  $T_LAUNCHING"
open "$DEST"
echo ""
echo "  $T_DONE"
echo ""
sleep 1
