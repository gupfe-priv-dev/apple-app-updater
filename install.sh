#!/usr/bin/env zsh
set -euo pipefail
DIR="${0:A:h}"
ME=$(whoami)

echo "==> Building UpdateAll.app..."
"$DIR/build-app.sh"

echo ""
echo "==> Installing LaunchAgent (run at login)..."
cp "$DIR/com.gunnar.update-all.plist" ~/Library/LaunchAgents/
launchctl unload ~/Library/LaunchAgents/com.gunnar.update-all.plist 2>/dev/null || true
launchctl load ~/Library/LaunchAgents/com.gunnar.update-all.plist 2>/dev/null || true
echo "    ✓ Registered"

echo ""
echo "==> Enabling Touch ID for sudo..."
printf '# sudo_local: local config file which survives system update and is included by /etc/pam.d/sudo\nauth       sufficient     pam_tid.so\n' \
  | /usr/libexec/authopen -w /etc/pam.d/sudo_local
echo "    ✓ /etc/pam.d/sudo_local written"

echo ""
echo "==> Allowing passwordless sudo for update commands..."
_sudoers_tmp=$(mktemp)
printf '# Passwordless sudo for system update commands (update-all)\n%s ALL=(ALL) NOPASSWD: /usr/sbin/installer, /usr/sbin/softwareupdate\n' "$ME" > "$_sudoers_tmp"
visudo -c -f "$_sudoers_tmp" || { echo "    ✗ sudoers syntax error"; rm "$_sudoers_tmp"; exit 1; }
osascript -e "do shell script \"cp $_sudoers_tmp /etc/sudoers.d/update-all && chmod 0440 /etc/sudoers.d/update-all\" with administrator privileges"
rm "$_sudoers_tmp"
echo "    ✓ /etc/sudoers.d/update-all written"

echo ""
echo "==> Installing update-all command to ~/.local/bin..."
mkdir -p ~/.local/bin
ln -sf "$DIR/update-all.sh" ~/.local/bin/update-all
echo "    ✓ update-all available in PATH"

echo ""
echo "All done. UpdateAll.app will open automatically at next login."
echo "Run manually: open \"$DIR/UpdateAll.app\""
