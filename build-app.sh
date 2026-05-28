#!/bin/zsh
set -euo pipefail
DIR="${0:A:h}"
APP="$DIR/UpdateAll.app"

echo "Building UpdateAll.app..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

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

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>UpdateAll</string>
    <key>CFBundleIdentifier</key><string>com.gunnar.update-all</string>
    <key>CFBundleName</key><string>Update All</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

xattr -rc "$APP"
codesign --sign - --force --deep "$APP" &>/dev/null
echo "Done → $APP"
