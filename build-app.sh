#!/bin/zsh
set -euo pipefail
DIR="${0:A:h}"
FINAL_APP="$DIR/UpdateAll.app"

# Assemble + codesign the bundle in a temp dir OUTSIDE the source tree. The
# source tree lives under a cloud file-provider that stamps
# com.apple.FinderInfo / com.apple.fileprovider attributes onto the bundle,
# which `xattr -rc` can't fully strip and which codesign rejects as
# "resource fork, Finder information, or similar detritus". Building in /tmp
# sidesteps that entirely; we copy the signed bundle into place at the end.
_BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$_BUILD_DIR"' EXIT
APP="$_BUILD_DIR/UpdateAll.app"

echo "Building UpdateAll.app..."
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Build version info — stamped into Info.plist below.
#   CFBundleShortVersionString: human-readable (free-form).
#   CFBundleVersion:            integer-tuple (macOS uses internally).
# Falls back to "dev"/"0" when not in a git checkout (e.g. unzipped tarball).
COMMIT=$(cd "$DIR" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || echo "dev")
COMMIT_COUNT=$(cd "$DIR" 2>/dev/null && git rev-list --count HEAD 2>/dev/null || echo "0")
# Latest release tag (e.g. v1.1.0) — strip the leading `v` for the human
# version. Falls back to 0.0 in non-tagged checkouts.
TAG=$(cd "$DIR" 2>/dev/null && git describe --tags --abbrev=0 2>/dev/null || echo "v0.0")
TAG_VERSION="${TAG#v}"
BUILD_TIME=$(date '+%Y-%m-%d %H:%M')
# Only a build sitting exactly ON a release tag may claim that version. The
# release workflow tags HEAD before it builds, so CI produces the clean string;
# a local build is by definition ahead of the last release and says so. Without
# this, a local build stamps the released version number and an installed copy
# is indistinguishable from the published one.
#
# "1.4.0+2-preview" parses as 1.4.0 for the self-update check (the segment after
# the last dot is read up to its '-', and a non-numeric core falls back to 0),
# so a preview build still gets offered the next real release.
AHEAD=$(cd "$DIR" 2>/dev/null && git rev-list --count "$TAG"..HEAD 2>/dev/null || echo "0")
if (cd "$DIR" 2>/dev/null && git describe --exact-match --tags HEAD >/dev/null 2>&1); then
    SHORT_VERSION="$TAG_VERSION ($COMMIT, $BUILD_TIME)"
else
    SHORT_VERSION="$TAG_VERSION+${AHEAD}-preview ($COMMIT, $BUILD_TIME)"
fi
BUILD_VERSION="$COMMIT_COUNT"
echo "  version: $SHORT_VERSION   (build $BUILD_VERSION)"

# Build a universal binary so the .app runs on both Intel and Apple Silicon.
# CI runs on macos-latest (Apple Silicon) and would otherwise ship an arm64-
# only binary that Intel Macs refuse with "not supported on this Mac".
# Targeting macOS 11 (Big Sur) keeps NSImage SF Symbol APIs available.
# All app sources live under Sources/ (recursively — Core/, Tools/, UI/, App/).
# Compiled together as one module (so main.swift is the single top-level-code
# file). make-icon.swift is NOT here — it's a standalone script run below.
SOURCES=( "$DIR"/Sources/**/*.swift(.N) )
swiftc -target x86_64-apple-macos11 -O -framework AppKit -framework Foundation \
    -o "$APP/Contents/MacOS/UpdateAll.x86_64" "${SOURCES[@]}"
swiftc -target arm64-apple-macos11   -O -framework AppKit -framework Foundation \
    -o "$APP/Contents/MacOS/UpdateAll.arm64"  "${SOURCES[@]}"
lipo -create \
    "$APP/Contents/MacOS/UpdateAll.x86_64" \
    "$APP/Contents/MacOS/UpdateAll.arm64" \
    -output "$APP/Contents/MacOS/UpdateAll"
rm "$APP/Contents/MacOS/UpdateAll.x86_64" "$APP/Contents/MacOS/UpdateAll.arm64"

# bundle features.sh (sudo / Touch ID / sudoers management — osascript/authopen).
# All other logic is now native Swift; no Python bridges or update-all*.sh.
cp "$DIR/features.sh" "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/features.sh"

# regenerate icon if missing, then bundle
if [[ ! -f "$DIR/AppIcon.icns" ]]; then
    swift "$DIR/make-icon.swift" "$DIR"
fi
cp "$DIR/AppIcon.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>UpdateAll</string>
    <key>CFBundleIdentifier</key><string>com.gunnar.update-all</string>
    <key>CFBundleName</key><string>Update All</string>
    <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

xattr -rc "$APP"
codesign --sign - --force --deep "$APP"

# Copy the signed bundle from the temp build dir into the source tree. Use
# ditto (not cp) so it doesn't drag along the source dir's FinderInfo; the
# signature was sealed in /tmp and stays valid. The file-provider may re-stamp
# com.apple.provenance on the copy, which codesign tolerates at launch.
rm -rf "$FINAL_APP"
ditto "$APP" "$FINAL_APP"

# SKIP_INSTALL=1 → CI / packaging builds skip everything below (no /Applications
# write, no tccutil) so the runner just produces a zippable .app artifact.
if [[ -z "${SKIP_INSTALL:-}" ]]; then
    # Reset macOS App Management TCC for our bundle ID. Each rebuild produces
    # a new ad-hoc signature; the prior "on" toggle in System Settings becomes
    # stale and tccd will silently deny the first cask install once it notices
    # the signature mismatch. Wiping the TCC entry forces a fresh consent
    # prompt that UpdateAll's startup probe can detect cleanly.
    tccutil reset SystemPolicyAppBundles com.gunnar.update-all &>/dev/null || true

    # Sync the freshly-built app to /Applications so it lives at the canonical
    # location System Settings shows when adding entries to App Management.
    INSTALLED="/Applications/UpdateAll.app"
    rm -rf "$INSTALLED"
    ditto "$APP" "$INSTALLED"
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$INSTALLED" >/dev/null 2>&1
    echo "Done → $FINAL_APP"
    echo "      → $INSTALLED  (installed)"
else
    echo "Done → $FINAL_APP   (SKIP_INSTALL set, /Applications untouched)"
fi
