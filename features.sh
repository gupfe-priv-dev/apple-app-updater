#!/usr/bin/env zsh
# Usage: features.sh <feature> <action>
#   feature: touchid | sudoers | codesign
#   action:  status | check | enable | disable
#
# `status` reports on/off based on file presence (no admin needed).
# `check`  also reports whether the rule format is current (for the app's
#          startup self-heal flow — bump SUDOERS_RULE_VERSION when you
#          change the rule's content).
set -euo pipefail
ME=$(whoami)

# Bump this whenever the sudoers rule body changes. The app checks this
# against the version stamped at the last enable, and offers to re-write.
SUDOERS_RULE_VERSION=2
STATE_DIR="$HOME/Library/Application Support/UpdateAll"
SUDOERS_VERSION_FILE="$STATE_DIR/sudoers.version"
# Common name of the self-signed identity used to sign UpdateAll.
# Signing with a stable certificate instead of ad-hoc is what makes
# macOS treat each rebuild as the *same* app, so the App Management
# grant survives. Ad-hoc signatures identify a build by its hash, which
# changes every time, so TCC revokes the grant on every rebuild.
mkdir -p "$STATE_DIR"

# Centralised rule body — keep this in sync with SUDOERS_RULE_VERSION.
#  /usr/sbin/installer       — brew cask installer (`sudo -E installer …`)
#  /usr/sbin/softwareupdate  — macOS Software Update
#  /opt/local/bin/port       — MacPorts on Apple Silicon
#  /usr/local/bin/port       — MacPorts on Intel
# Deliberately NOT NOPASSWD: /bin/rm (stuck-cask cleanup) — too dangerous
# to grant unconditionally; that rare case keeps prompting via Touch ID.
sudoers_rule_body() {
  printf '# Passwordless sudo for update-all (v%s)\n%s ALL=(ALL) NOPASSWD:SETENV: /usr/sbin/installer, /usr/sbin/softwareupdate, /opt/local/bin/port, /usr/local/bin/port\n' \
    "$SUDOERS_RULE_VERSION" "$ME"
}

case "${1:-}" in
  touchid)
    case "${2:-}" in
      status)
        if [[ -f /etc/pam.d/sudo_local ]] && grep -q "pam_tid.so" /etc/pam.d/sudo_local; then
          echo enabled
        else
          echo disabled
        fi
        ;;
      check)
        if [[ -f /etc/pam.d/sudo_local ]] && grep -q "pam_tid.so" /etc/pam.d/sudo_local; then
          echo current
        else
          echo missing
        fi
        ;;
      enable)
        if [[ -f /etc/pam.d/sudo_local ]] && grep -q "pam_tid.so" /etc/pam.d/sudo_local; then
          echo "already enabled"; exit 0
        fi
        printf '# sudo_local: local config file which survives system update and is included by /etc/pam.d/sudo\nauth       sufficient     pam_tid.so\n' \
          | /usr/libexec/authopen -c -w /etc/pam.d/sudo_local
        echo "Touch ID for sudo enabled"
        ;;
      disable)
        if [[ ! -f /etc/pam.d/sudo_local ]]; then
          echo "already disabled"; exit 0
        fi
        # truncate sudo_local (removes the pam_tid entry; system falls back to password)
        : | /usr/libexec/authopen -w /etc/pam.d/sudo_local
        echo "Touch ID for sudo disabled"
        ;;
      *) echo "Usage: $0 touchid {status|check|enable|disable}" >&2; exit 2 ;;
    esac
    ;;
  sudoers)
    case "${2:-}" in
      status)
        [[ -f /etc/sudoers.d/update-all ]] && echo enabled || echo disabled
        ;;
      check)
        # Reports whether the rule is current. Used by the app at launch to
        # decide whether to offer a one-click upgrade.
        if [[ ! -f /etc/sudoers.d/update-all ]]; then
          echo missing
        else
          current=$(cat "$SUDOERS_VERSION_FILE" 2>/dev/null || echo 0)
          if [[ "$current" -lt "$SUDOERS_RULE_VERSION" ]]; then
            echo outdated
          else
            echo current
          fi
        fi
        ;;
      enable)
        # always overwrite — lets us re-run "enable" to upgrade the rule format
        _tmp=$(mktemp)
        sudoers_rule_body > "$_tmp"
        visudo -c -f "$_tmp" || { echo "sudoers syntax error"; rm "$_tmp"; exit 1; }
        osascript -e "do shell script \"cp $_tmp /etc/sudoers.d/update-all && chmod 0440 /etc/sudoers.d/update-all\" with administrator privileges"
        rm "$_tmp"
        echo "$SUDOERS_RULE_VERSION" > "$SUDOERS_VERSION_FILE"
        echo "Passwordless sudo for updates enabled (v$SUDOERS_RULE_VERSION)"
        ;;
      disable)
        if [[ ! -f /etc/sudoers.d/update-all ]]; then
          echo "already disabled"; exit 0
        fi
        osascript -e "do shell script \"rm -f /etc/sudoers.d/update-all\" with administrator privileges"
        rm -f "$SUDOERS_VERSION_FILE"
        echo "Passwordless sudo for updates disabled"
        ;;
      *) echo "Usage: $0 sudoers {status|check|enable|disable}" >&2; exit 2 ;;
    esac
    ;;
  codesign)
    # Delegated to signing-identity.sh so creation, export and restore all live
    # in one place — it's bundled next to this script inside the .app.
    _si="${0:A:h}/signing-identity.sh"
    [[ -x "$_si" ]] || { echo "signing-identity.sh missing"; exit 1; }
    case "${2:-}" in
      status|check) "$_si" status ;;
      name)         "$_si" name ;;
      enable)       "$_si" create ;;
      disable)      "$_si" remove ;;
      *) echo "Usage: $0 codesign {status|check|name|enable|disable}" >&2; exit 2 ;;
    esac
    ;;
  *)
    echo "Usage: $0 {touchid|sudoers|codesign} {status|check|enable|disable}" >&2
    exit 2
    ;;
esac
