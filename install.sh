#!/bin/bash
# install.sh — downloads and installs UpdateAll from the latest GitHub Release.
#
# Usage:
#   /bin/bash -c "$(curl -fsSL https://cdn.jsdelivr.net/gh/gupfe-priv-dev/apple-app-updater@main/install.sh)"
#
# (jsDelivr is preferred over raw.githubusercontent.com because some
# corporate proxies aggressively cache the GitHub raw URL and return
# stale content. jsDelivr's CDN invalidates per commit and is rarely
# rate-limited or blocked.)
#
# What it does:
#   • fetches the latest release zip
#   • strips com.apple.quarantine so macOS doesn't show "downloaded from
#     the internet" / "cannot verify developer" on first launch
#   • copies the .app to /Applications, replacing any prior install
#   • re-registers with Launch Services and launches the app
#
# For source-clone / development installs (build from this repo + LaunchAgent +
# Touch ID + sudoers prompts), use ./setup.sh instead.

set -euo pipefail

REPO="gupfe-priv-dev/apple-app-updater"
APP_NAME="UpdateAll"
DEST="/Applications/$APP_NAME.app"

# ── Language detection ────────────────────────────────────────────────────────
PRIMARY_LANG=$(defaults read -g AppleLanguages 2>/dev/null | grep -m1 -o '"[a-z][a-z]' | tr -d '"' || echo "en")
if [[ "$PRIMARY_LANG" == "de" ]]; then
    T_TITLE="UpdateAll  Installation"
    T_FETCHING="  Neueste Version wird ermittelt..."
    T_DOWNLOADING="  Wird heruntergeladen"
    T_QUESTION="  UpdateAll in /Applications installieren?"
    T_YES="    [J]  Ja  — jetzt installieren  (empfohlen)"
    T_NO="    [N]  Nein — abbrechen"
    T_YES_KEYS="^[JjYy]"
    T_PROMPT="  Ihre Wahl [J/n]: "
    T_ABORTED="  Abgebrochen."
    T_INSTALLING="  Installiere in /Applications..."
    T_INSTALLED="  ✓  Installiert."
    T_LAUNCHING="  Wird gestartet..."
    T_DONE="  Fertig."
    T_WHATSNEW="  Neuerungen:"
    T_UPTODATE="  ✓ Bereits aktuell — nichts zu tun."
else
    T_TITLE="UpdateAll  Installer"
    T_FETCHING="  Fetching latest release..."
    T_DOWNLOADING="  Downloading"
    T_QUESTION="  Install UpdateAll to /Applications?"
    T_YES="    [Y]  Yes — install now  (recommended)"
    T_NO="    [N]  No  — cancel"
    T_YES_KEYS="^[Yy]"
    T_PROMPT="  Your choice [Y/n]: "
    T_ABORTED="  Aborted."
    T_INSTALLING="  Installing to /Applications..."
    T_INSTALLED="  ✓  Installed."
    T_LAUNCHING="  Launching..."
    T_DONE="  Done."
    T_WHATSNEW="  What's new:"
    T_UPTODATE="  ✓ Already up to date — nothing to do."
fi

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
echo "  ╔═══════════════════════════════════╗"
echo "  ║  $T_TITLE  ║"
echo "  ╚═══════════════════════════════════╝"
echo ""

# ── Fetch latest release info ─────────────────────────────────────────────────
echo "$T_FETCHING"
LATEST_JSON=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")
TAG=$(echo "$LATEST_JSON" | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
ZIP_URL=$(echo "$LATEST_JSON" | grep '"browser_download_url"' | grep '\.zip"' | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')
NOTES=$(echo "$LATEST_JSON" | sed -n 's/.*"body": *"\(.*\)".*/\1/p' | sed 's/\\r\\n/\n/g; s/\\n/\n/g; s/\*\*//g')
echo "  $TAG"

# ── Already up to date? ───────────────────────────────────────────────────────
# Compare bundled CFBundleShortVersionString's leading semver (e.g. "1.3.8"
# from "1.3.8 (47fdcca, 2026-06-06 10:44)") against the release tag's
# numeric portion. If equal, short-circuit — no reinstall, no prompt.
INSTALLED_SHORT=""
if [[ -d "/Applications/$APP_NAME.app" ]]; then
    INSTALLED_SHORT=$(defaults read "/Applications/$APP_NAME.app/Contents/Info" CFBundleShortVersionString 2>/dev/null | awk '{print $1}')
fi
TAG_VER="${TAG#v}"
if [[ -n "$INSTALLED_SHORT" && "$INSTALLED_SHORT" == "$TAG_VER" ]]; then
    echo ""
    echo "$T_UPTODATE"
    echo ""
    exit 0
fi

if [[ -n "$NOTES" ]]; then
    echo ""
    echo "$T_WHATSNEW"
    echo "$NOTES" | while IFS= read -r line; do [[ -n "$line" ]] && echo "    $line"; done
fi
echo ""

# ── Ask user ──────────────────────────────────────────────────────────────────
echo "$T_QUESTION"
echo ""
echo "$T_YES"
echo "$T_NO"
echo ""
read -r -p "$T_PROMPT" answer
answer="${answer:-Y}"
echo ""

if [[ ! "$answer" =~ $T_YES_KEYS ]]; then
    echo "$T_ABORTED"
    echo ""
    exit 0
fi

# ── Download ──────────────────────────────────────────────────────────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "$T_DOWNLOADING $TAG..."
# Retries + generous timeouts because some corporate proxies (e.g. FortiClient)
# 504 the first attempt while their anti-malware scanner inspects the binary.
# `--retry-all-errors` retries on HTTP errors too (not just transient TCP).
if ! curl -fsSL \
       --retry 4 --retry-delay 3 --retry-all-errors \
       --connect-timeout 30 --max-time 180 \
       "$ZIP_URL" -o "$TMP/release.zip"; then
    echo ""
    echo "  ✗ Download failed."
    echo "    URL: $ZIP_URL"
    echo "    Open it in your browser, save the zip, drop UpdateAll.app into"
    echo "    /Applications, then run:  xattr -dr com.apple.quarantine /Applications/UpdateAll.app"
    exit 1
fi
unzip -q "$TMP/release.zip" -d "$TMP/extracted"
echo ""

# ── Install ───────────────────────────────────────────────────────────────────
echo "$T_INSTALLING"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5
rm -rf "$DEST"
cp -R "$TMP/extracted/$APP_NAME.app" "$DEST"
# Strip "downloaded from the internet" tag so Gatekeeper doesn't block first launch.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
# Re-register so `open -b com.gunnar.update-all` resolves, and clear any stale
# App Management TCC entry so the new signature gets a fresh consent prompt.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
tccutil reset SystemPolicyAppBundles com.gunnar.update-all >/dev/null 2>&1 || true
echo "$T_INSTALLED"
echo ""

# ── Launch ────────────────────────────────────────────────────────────────────
echo "$T_LAUNCHING"
open "$DEST"
echo ""

echo "  ────────────────────────────────────────"
echo "$T_DONE"
echo ""
