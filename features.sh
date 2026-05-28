#!/usr/bin/env zsh
# Usage: features.sh <feature> <action>
#   feature: touchid | sudoers
#   action:  status | enable | disable
set -euo pipefail
ME=$(whoami)

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
      *) echo "Usage: $0 touchid {status|enable|disable}" >&2; exit 2 ;;
    esac
    ;;
  sudoers)
    case "${2:-}" in
      status)
        [[ -f /etc/sudoers.d/update-all ]] && echo enabled || echo disabled
        ;;
      enable)
        if [[ -f /etc/sudoers.d/update-all ]]; then
          echo "already enabled"; exit 0
        fi
        _tmp=$(mktemp)
        printf '# Passwordless sudo for system update commands (update-all)\n%s ALL=(ALL) NOPASSWD: /usr/sbin/installer, /usr/sbin/softwareupdate\n' "$ME" > "$_tmp"
        visudo -c -f "$_tmp" || { echo "sudoers syntax error"; rm "$_tmp"; exit 1; }
        osascript -e "do shell script \"cp $_tmp /etc/sudoers.d/update-all && chmod 0440 /etc/sudoers.d/update-all\" with administrator privileges"
        rm "$_tmp"
        echo "Passwordless sudo for updates enabled"
        ;;
      disable)
        if [[ ! -f /etc/sudoers.d/update-all ]]; then
          echo "already disabled"; exit 0
        fi
        osascript -e "do shell script \"rm -f /etc/sudoers.d/update-all\" with administrator privileges"
        echo "Passwordless sudo for updates disabled"
        ;;
      *) echo "Usage: $0 sudoers {status|enable|disable}" >&2; exit 2 ;;
    esac
    ;;
  *)
    echo "Usage: $0 {touchid|sudoers} {status|enable|disable}" >&2
    exit 2
    ;;
esac
