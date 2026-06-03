#!/usr/bin/env zsh
# update-all-scan.sh — companion to update-all.sh that ONLY checks for
# available updates per tool. No installs, no prompts. The companion app
# runs this first on launch so it can show what's available before any
# actual install is offered.
#
# Section titles must match those in update-all.sh's print_header() calls
# so the app's sidebar can map results to the right rows.

set -uo pipefail

export _SCRIPT_DIR="${0:A:h}"
export _STATE_DIR="${HOME}/Library/Application Support/UpdateAll"
mkdir -p "$_STATE_DIR"

# Same brew env hygiene as the full script — no auto-update / hints / emoji.
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_EMOJI=1
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

if [[ -t 1 ]]; then
  C_HEADER=$'\033[1;33m'; C_RESET=$'\033[0m'
else
  C_HEADER=''; C_RESET=''
fi

print_header() {
  local cols=${COLUMNS:-110}
  echo ""
  printf "${C_HEADER}"
  printf '━%.0s' {1..$cols}
  printf '\n  %s\n' "$1"
  printf "${C_RESET}"
}

# Report a section's scan result.
#   _report <count> [<item> ...]
#   count == 0  → "✓ Up to date"
#   count >  0  → "↑ N update(s) available" plus list (truncated)
_report() {
  local count="$1"; shift
  if (( count == 0 )); then
    echo "  ✓ Up to date"
  else
    echo "  ↑ $count update(s) available"
    local shown=0
    for item in "$@"; do
      [[ -z "$item" ]] && continue
      echo "    • $item"
      shown=$((shown + 1))
      (( shown >= 10 )) && { echo "    … and $((count - shown)) more"; break; }
    done
  fi
}

printf "${C_HEADER}🔍 macOS Update Scan${C_RESET}\n"

# ── App registry ─────────────────────────────────────────────────────────
# Cheap to run and tells the user how many apps the script knows about.
# We invoke the full script's discovery step only if the registry is stale.
print_header "App registry"
_apps_count=$(ls -1 /Applications 2>/dev/null | grep -c '\.app$' || echo 0)
echo "  ${_apps_count} apps in /Applications (full scan happens during install)"

# ── Homebrew formulae ────────────────────────────────────────────────────
print_header "Homebrew — formulae"
if ! brew update &>/dev/null; then
  echo "  ⚠ brew update failed (network down or VPN not connected?) — using cached formulae"
fi
_outdated=( $(brew outdated --formula --quiet 2>/dev/null) )
_report ${#_outdated[@]} "${_outdated[@]}"

# ── Homebrew casks ───────────────────────────────────────────────────────
print_header "Homebrew — casks"
_outdated=( $(brew outdated --cask --greedy --quiet 2>/dev/null) )
_report ${#_outdated[@]} "${_outdated[@]}"

# ── MacPorts ─────────────────────────────────────────────────────────────
print_header "MacPorts"
if command -v port &>/dev/null; then
  _lines=( "${(@f)$(port outdated 2>/dev/null | grep -v 'No installed ports are outdated' || true)}" )
  # filter empty entries
  _filtered=()
  for line in "${_lines[@]}"; do [[ -n "$line" ]] && _filtered+=("$line"); done
  _report ${#_filtered[@]} "${_filtered[@]}"
else
  echo "  port not installed — skipping"
fi

# ── Mac App Store ────────────────────────────────────────────────────────
print_header "Mac App Store"
if command -v mas &>/dev/null; then
  _lines=( "${(@f)$(mas outdated 2>/dev/null)}" )
  _filtered=()
  for line in "${_lines[@]}"; do [[ -n "$line" ]] && _filtered+=("$line"); done
  _report ${#_filtered[@]} "${_filtered[@]}"
else
  echo "  mas not installed — skipping"
fi

# ── npm ──────────────────────────────────────────────────────────────────
print_header "npm"
if command -v npm &>/dev/null; then
  # npm outdated -g exits 1 when packages are outdated (CI-friendly behavior)
  _lines=( "${(@f)$(npm outdated -g --parseable 2>/dev/null || true)}" )
  _filtered=()
  for line in "${_lines[@]}"; do
    [[ -n "$line" ]] || continue
    # format: path:current:wanted:latest:location — show just the name
    name=${line##*:}
    _filtered+=("$name")
  done
  _report ${#_filtered[@]} "${_filtered[@]}"
else
  echo "  npm not installed — skipping"
fi

# ── Ruby gems ────────────────────────────────────────────────────────────
print_header "Ruby gems"
_gem="$(brew --prefix ruby 2>/dev/null)/bin/gem"
if [[ -x "$_gem" ]]; then
  _lines=( "${(@f)$("$_gem" outdated 2>/dev/null | grep -vE 'warning: (already initialized|previous definition)')}" )
  _filtered=()
  for line in "${_lines[@]}"; do [[ -n "$line" ]] && _filtered+=("$line"); done
  _report ${#_filtered[@]} "${_filtered[@]}"
else
  echo "  gem not available — skipping"
fi

# ── Rust ─────────────────────────────────────────────────────────────────
print_header "Rust (rustup)"
if command -v rustup &>/dev/null; then
  out=$(rustup check 2>&1 || true)
  if echo "$out" | grep -q "Update available"; then
    echo "  ↑ Update available"
    echo "$out" | grep "Update available" | sed 's/^/    • /'
  else
    echo "  ✓ Up to date"
  fi
else
  echo "  rustup not installed — skipping"
fi

# ── pipx ─────────────────────────────────────────────────────────────────
print_header "pipx"
if command -v pipx &>/dev/null; then
  # pipx doesn't have a structured "outdated" command; use list and parse
  _count=$(pipx list 2>/dev/null | grep -c '   package' || echo 0)
  # this is "total installed", not outdated — pipx upgrade-all is cheap so
  # we just hint at availability
  echo "  ? $_count package(s) tracked — pipx has no scan-only mode"
else
  echo "  pipx not installed — skipping"
fi

# ── Claude Code ──────────────────────────────────────────────────────────
print_header "Claude Code"
if command -v claude &>/dev/null; then
  # claude has no dry-run; the only way to know is to invoke `claude update`
  # which actually updates. We report version and hint.
  ver=$(claude --version 2>/dev/null | head -1)
  echo "  ? installed ${ver:-(version unknown)} — run install to check"
else
  echo "  claude not installed — skipping"
fi

# ── Sparkle apps ─────────────────────────────────────────────────────────
print_header "Sparkle updates (unmanaged apps)"
echo "  ? per-app feed check happens during install run"

# ── macOS Software Update ────────────────────────────────────────────────
print_header "macOS Software Update"
_su_log=$(mktemp)
softwareupdate --list &>"$_su_log" || true
_count=$(grep -c '^\* Label:' "$_su_log" 2>/dev/null) || _count=0
if [[ "$_count" -eq 0 ]]; then
  echo "  ✓ No updates available"
else
  echo "  ↑ $_count update(s) available"
  grep -E '^\* Label:|^[[:space:]]+Title:' "$_su_log" 2>/dev/null | sed 's/^/    /'
fi
rm -f "$_su_log"

echo ""
echo "✅ Scan complete."
