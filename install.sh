#!/usr/bin/env zsh
set -euo pipefail
DIR="${0:A:h}"
ME=$(whoami)

echo "==> Building UpdateAll.app..."
"$DIR/build-app.sh"

echo ""
echo "==> Registering UpdateAll.app with Launch Services..."
# Ensures `open -b com.gunnar.update-all` finds the app no matter where it lives.
# Required because apps outside /Applications are not auto-indexed.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
    -f "$DIR/UpdateAll.app"
echo "    ✓ Registered (bundle id: com.gunnar.update-all)"

echo ""
echo "==> Installing LaunchAgent (run at login)..."
cp "$DIR/com.gunnar.update-all.plist" ~/Library/LaunchAgents/
launchctl unload ~/Library/LaunchAgents/com.gunnar.update-all.plist 2>/dev/null || true
launchctl load ~/Library/LaunchAgents/com.gunnar.update-all.plist 2>/dev/null || true
echo "    ✓ Loaded"

echo ""
echo ""
echo "==> Optional: Touch ID for sudo"
cat <<'EOF'
    What it does:  sudo (used by the updater for softwareupdate / installer) can
                   authenticate via fingerprint or Apple Watch instead of a typed password.
    Without it:    every sudo invocation prompts for your typed password.
    Reversible:    yes — via the app's "Features" menu, or "features.sh touchid disable".
EOF
_ans=""
read -q "?    Enable Touch ID for sudo? [y/N] " _ans 2>/dev/null || true; echo ""
if [[ "$_ans" == [yY] ]]; then
  "$DIR/features.sh" touchid enable
  echo "    ✓ enabled"
else
  echo "    ⊘ skipped"
fi

echo ""
echo "==> Optional: Passwordless sudo for update commands"
cat <<'EOF'
    What it does:  /usr/sbin/installer and /usr/sbin/softwareupdate can be run by
                   you without any prompt (other commands still require auth normally).
    Without it:    when the updater installs macOS updates it will prompt for your
                   password (or Touch ID, if enabled above) every time.
    Reversible:    yes — via the app's "Features" menu, or "features.sh sudoers disable".
EOF
_ans=""
read -q "?    Enable passwordless sudo for updates? [y/N] " _ans 2>/dev/null || true; echo ""
if [[ "$_ans" == [yY] ]]; then
  "$DIR/features.sh" sudoers enable
  echo "    ✓ enabled"
else
  echo "    ⊘ skipped"
fi

echo ""
echo "==> Installing update-all command to ~/.local/bin..."
mkdir -p ~/.local/bin
ln -sf "$DIR/update-all.sh" ~/.local/bin/update-all
echo "    ✓ update-all available in PATH"

echo ""
echo "All done. UpdateAll.app will open automatically at next login."
echo "Run manually: open \"$DIR/UpdateAll.app\""
