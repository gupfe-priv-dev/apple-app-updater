#!/bin/zsh
set -euo pipefail
DIR="${0:A:h}"
APP="$DIR/UpdateAll.app"

echo "Building UpdateAll.app..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Build version info — stamped into Info.plist below.
#   CFBundleShortVersionString: human-readable (free-form).
#   CFBundleVersion:            integer-tuple (macOS uses internally).
# Falls back to "dev"/"0" when not in a git checkout (e.g. unzipped tarball).
COMMIT=$(cd "$DIR" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || echo "dev")
COMMIT_COUNT=$(cd "$DIR" 2>/dev/null && git rev-list --count HEAD 2>/dev/null || echo "0")
BUILD_TIME=$(date '+%Y-%m-%d %H:%M')
SHORT_VERSION="1.0 ($COMMIT, $BUILD_TIME)"
BUILD_VERSION="$COMMIT_COUNT"
echo "  version: $SHORT_VERSION   (build $BUILD_VERSION)"

swiftc -o "$APP/Contents/MacOS/UpdateAll" "$DIR/UpdateAll.swift" \
    -framework AppKit -framework Foundation -O

# bundle the shell scripts so the .app is self-contained
cp "$DIR/update-all.sh" "$APP/Contents/Resources/"
cp "$DIR/features.sh"   "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/update-all.sh" "$APP/Contents/Resources/features.sh"

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
codesign --sign - --force --deep "$APP" &>/dev/null

# Reset macOS App Management TCC for our bundle ID. Each rebuild produces a
# new ad-hoc signature; the prior "on" toggle in System Settings becomes stale
# and tccd will silently deny the first cask install once it notices the
# signature mismatch. Wiping the TCC entry forces a fresh consent prompt that
# UpdateAll's startup probe can detect cleanly.
tccutil reset SystemPolicyAppBundles com.gunnar.update-all &>/dev/null || true

# Sync the freshly-built app to /Applications so it lives at the canonical
# location System Settings shows when adding entries to App Management. We
# keep the in-repo copy too (it's what swiftc just wrote into) so dev /
# debug flows still work.
INSTALLED="/Applications/UpdateAll.app"
rm -rf "$INSTALLED"
cp -R "$APP" "$INSTALLED"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$INSTALLED" >/dev/null 2>&1

echo "Done → $APP"
echo "      → $INSTALLED  (installed)"
