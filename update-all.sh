#!/usr/bin/env zsh
# -u catches typos in variable names; pipefail surfaces real exit codes when
# we explicitly check $pipestatus. We deliberately DO NOT use `-e` — any
# single tool failure (cask conflict, network blip, missing CLI) must print
# a warning and continue, not kill the whole run. Each section is responsible
# for its own failure messaging.
set -uo pipefail

export _SCRIPT_DIR="${0:A:h}"
# State (registry) and cache (catalog) — kept OUT of the .app bundle so rebuilds
# don't wipe them and writes don't break the bundle's code signature.
export _STATE_DIR="${HOME}/Library/Application Support/UpdateAll"
export _CACHE_DIR="${HOME}/Library/Caches/UpdateAll"
mkdir -p "$_STATE_DIR" "$_CACHE_DIR"

# Quieter brew output — disable hints, emoji, and (most importantly) the
# spinner that uses ANSI cursor-up + clear-line escapes. Those don't render
# in the .app's NSTextView (we'd see hundreds of stacked frames). Pair with
# `--quiet` on individual brew calls to suppress the cask download progress bar.
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_EMOJI=1
export HOMEBREW_NO_AUTO_UPDATE=1     # we call `brew update` explicitly; skip implicit
export HOMEBREW_NO_INSTALL_CLEANUP=1 # keep the run focused; cleanup is unrelated

# colors — only when stdout is a TTY
if [[ -t 1 ]]; then
  C_HEADER=$'\033[1;33m'  # bold yellow
  C_RESET=$'\033[0m'
else
  C_HEADER=''
  C_RESET=''
fi

print_header() {
  local cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
  echo ""
  printf "${C_HEADER}"
  printf '━%.0s' {1..$cols}
  printf '\n  %s\n' "$1"
  printf "${C_RESET}"
}

# Ask yes/no.
#  - In a terminal: prints "  <question> [y/N] " and reads one keypress
#  - Under UpdateAll.app (UPDATER_GUI=1) or any non-TTY context: pops a native
#    macOS dialog via osascript. Returns 0 for yes, 1 for no.
ask_yn() {
  local question="$1"
  if [[ -n "${UPDATER_GUI:-}" ]] || ! [[ -t 0 ]]; then
    # escape any double-quotes in the question for safe AppleScript embedding
    local q="${question//\"/\\\"}"
    # bring UpdateAll.app to front first so the user can see who is asking,
    # then show the dialog (which appears over our now-foreground app).
    # `button returned of (...)` returns just "Yes" or "No" — no "button returned:" prefix.
    local btn
    btn=$(osascript \
      -e 'tell application id "com.gunnar.update-all" to activate' \
      -e "button returned of (display dialog \"$q\" buttons {\"No\", \"Yes\"} default button \"Yes\" with title \"Update All\")" \
      2>/dev/null || echo "")
    echo "  → ${btn:-cancelled}"
    [[ "$btn" == "Yes" ]]
  else
    local _ans=""
    printf '  %s [y/N] ' "$question"
    read -k1 _ans 2>/dev/null || _ans=""; echo ""
    [[ "$_ans" == [yY]* ]]
  fi
}

# run a command, stream its output live, or print "✓ label" if nothing was produced
run_or_ok() {
  local label="$1"; shift
  local tmp
  tmp=$(mktemp)
  { "$@" 2>&1 || true; } | tee "$tmp"
  [[ -s "$tmp" ]] || echo "  ✓ $label"
  rm -f "$tmp"
}

# Returns 0 (true) if this section is in $UPDATER_SKIP_SECTIONS — the launching
# app set this when the most recent scan determined the section's tool wasn't
# installed. The caller should bail out without emitting print_header / doing
# any work, so the sidebar's "skipped" state stays visible instead of cycling
# through "active" → "skipped" for a few ms per absent tool.
_skip_section() {
  [[ -z "${UPDATER_SKIP_SECTIONS:-}" ]] && return 1
  case ",${UPDATER_SKIP_SECTIONS}," in
    *,"$1",*) return 0 ;;
    *)        return 1 ;;
  esac
}

# Drop brew's cask download spinner frames. brew's Ruby tty-progressbar uses
# ANSI cursor-up + clear-line escapes — which, once ANSI-stripped in the .app's
# NSTextView, pile up as hundreds of "Cask X (Y) Downloading N.NMB/total" lines.
# The frame lines are recognizable; brew's "==> …" headers and errors pass through.
_brew_filter() {
  grep --line-buffered -vE \
    'Cask [a-zA-Z0-9_-]+ \([0-9][0-9.]*\)[[:space:]]+(Downloading|Downloaded|Verifying|Verified)' \
    || true
}

printf "${C_HEADER}🔄 macOS Updater${C_RESET}\n"

# ══════════════════════════════════════════
#  1. UPDATE APP REGISTRY
#     Scan /Applications vs brew/mas lists,
#     detect update method for new apps,
#     save to apps.json
# ══════════════════════════════════════════
print_header "App registry"
# tempfile for Python → shell handoff of "safe to install" brew cask tokens
_BREW_SAFE_LIST=$(mktemp)
export _BREW_SAFE_LIST
python3 - << 'PYEOF'
import json, os, subprocess
from pathlib import Path
from collections import Counter

SCRIPT_DIR = Path(os.environ['_SCRIPT_DIR'])
STATE_DIR  = Path(os.environ['_STATE_DIR'])
CACHE_DIR  = Path(os.environ['_CACHE_DIR'])
REGISTRY   = STATE_DIR / 'apps.json'
APPS_DIR   = Path('/Applications')

# one-time migration: move apps.json out of any old script-relative location
# (which on the .app build lived inside Contents/Resources/ and got wiped on rebuild)
for _old in (SCRIPT_DIR / 'apps.json', SCRIPT_DIR.parent / 'apps.json'):
    if _old.exists() and not REGISTRY.exists():
        try: _old.rename(REGISTRY); print(f'  migrated apps.json → {REGISTRY}')
        except Exception: pass

# Tokens the user said "No" to in a previous safe-bucket prompt — we keep
# them out of future suggestions until the user clears the file.
DECLINED_FILE = STATE_DIR / 'declined-casks.json'
declined_casks = set()
if DECLINED_FILE.exists():
    try: declined_casks = set(json.loads(DECLINED_FILE.read_text()))
    except Exception: pass

def plist_get(plist, key):
    r = subprocess.run(['/usr/libexec/PlistBuddy', '-c', f'Print {key}', str(plist)],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None

def get_brew_apps():
    """Return app_name → cask_token for every locally-installed cask.
    Reads both `app:` artifacts AND /Applications/*.app paths in `uninstall.delete`
    so pkg-installer casks (adobe-acrobat-reader, microsoft-office, zoom, etc.)
    are correctly recognized as 'managed' instead of staying in the unmanaged
    registry and being re-offered every run."""
    casks = subprocess.run(['brew', 'list', '--cask'], capture_output=True, text=True).stdout.split()
    if not casks: return {}
    r = subprocess.run(['brew', 'info', '--cask', '--json=v2'] + casks, capture_output=True, text=True)
    result = {}
    import os as _os
    try:
        for c in json.loads(r.stdout).get('casks', []):
            token = c['token']
            for art in c.get('artifacts', []):
                if not isinstance(art, dict): continue
                for name in art.get('app', []) or []:
                    if isinstance(name, str): result[name] = token
                for u in art.get('uninstall', []) or []:
                    if not isinstance(u, dict): continue
                    for path in u.get('delete', []) or []:
                        if not isinstance(path, str): continue
                        if not (path.startswith('/Applications/') and path.endswith('.app')): continue
                        if '*' in path: continue
                        result[_os.path.basename(path)] = token
    except Exception: pass
    return result

def get_mas_apps():
    r = subprocess.run(['mas', 'list'], capture_output=True, text=True)
    result = {}
    for line in r.stdout.strip().splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2:
            mas_id, rest = parts
            result[f'{rest.rsplit("(", 1)[0].strip()}.app'] = mas_id
    return result

def load_cask_catalog():
    """Download (or reuse cached) full Homebrew cask catalog.
    Returns app_name → list of {token, version} candidates.

    Two sources of app names per cask:
      1. `app:` artifact — drag-to-/Applications casks (e.g. libreoffice).
      2. `uninstall.delete` paths matching /Applications/*.app — pkg-installer
         casks (zoom, microsoft-office, adobe-acrobat-reader, onedrive, …).
         Without (2) we'd miss most enterprise apps because they don't declare
         an `app:` stanza."""
    catalog_path = CACHE_DIR / 'brew_cask_catalog_v4.json'
    import time, os, sys
    if catalog_path.exists() and time.time() - catalog_path.stat().st_mtime < 86400:
        return json.loads(catalog_path.read_text())
    print('  ⤓ Fetching Homebrew cask catalog (~15MB, cached for 24h)...', flush=True)
    r = subprocess.run(['curl', '-sf', 'https://formulae.brew.sh/api/cask.json'],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print('    ✗ catalog fetch failed — continuing without cask suggestions')
        return {}
    casks = json.loads(r.stdout)
    catalog = {}
    for c in casks:
        token, ver = c['token'], c.get('version', '')
        apps_for_this = set()
        for art in c.get('artifacts', []):
            if not isinstance(art, dict): continue
            # source 1: explicit app artifact
            for a in art.get('app', []) or []:
                if isinstance(a, str): apps_for_this.add(a)
            # source 2: paths under /Applications removed by uninstall
            for u in art.get('uninstall', []) or []:
                if not isinstance(u, dict): continue
                for path in u.get('delete', []) or []:
                    if not isinstance(path, str): continue
                    if not (path.startswith('/Applications/') and path.endswith('.app')): continue
                    if '*' in path: continue   # wildcards aren't a real app name
                    name = os.path.basename(path)
                    if name: apps_for_this.add(name)
        for a in apps_for_this:
            catalog.setdefault(a.lower().removesuffix('.app'), []).append({
                'token': token, 'version': ver,
            })
    catalog_path.write_text(json.dumps(catalog))
    print(f'    ✓ catalog indexed: {len(catalog)} apps from {len(casks)} casks', flush=True)
    # purge orphaned old-format / old-location caches
    for old in (CACHE_DIR / 'brew_cask_catalog.json',
                CACHE_DIR / 'brew_cask_catalog_v2.json',
                CACHE_DIR / 'brew_cask_catalog_v3.json',
                SCRIPT_DIR / 'brew_cask_catalog.json',
                SCRIPT_DIR / 'brew_cask_catalog_v2.json'):
        if old.exists():
            try: old.unlink()
            except Exception: pass
    return catalog

_cask_catalog = None
def find_brew_cask(app_name, installed_version=None):
    """Find the best-matching brew cask for this .app.
    When multiple casks install the same .app, prefer the one whose major
    version matches the installed major (e.g. LibreOffice 26.x → libreoffice,
    not libreoffice-still 25.x). Returns {token, version} or None."""
    global _cask_catalog
    if _cask_catalog is None:
        _cask_catalog = load_cask_catalog()
    candidates = _cask_catalog.get(app_name.lower().removesuffix('.app'))
    if not candidates: return None
    if len(candidates) == 1: return candidates[0]
    def major(s):
        import re as _re
        m = _re.match(r'(\d+)', s or '')
        return int(m.group(1)) if m else -1
    if installed_version:
        iv_maj = major(installed_version)
        same = [c for c in candidates if major(c.get('version', '')) == iv_maj]
        if same: return same[0]
    # fall back to candidate with highest major version
    return max(candidates, key=lambda c: major(c.get('version', '')))

import re as _re
def _first_int(s):
    m = _re.match(r'(\d+)', s or '')
    return int(m.group(1)) if m else None

def _sortv(a, b):
    """sort -V comparison. 1 if a > b, -1 if a < b, 0 if equal."""
    if a == b: return 0
    r = subprocess.run(['bash', '-c', f'printf "%s\\n%s\\n" "{a}" "{b}" | sort -V | tail -1'],
                       capture_output=True, text=True)
    top = r.stdout.strip()
    return 1 if top == a else (-1 if top == b else 0)

def cmp_version(a, b):
    """Return 1 if a > b, -1 if a < b, 0 if equal, None if structurally
    incomparable. Handles Brave-style concatenations like '148.1.90.122'
    (Chromium-major prefixed onto Brave's '1.90.122') by also trying the
    version with its leading segment stripped before giving up."""
    if not a or not b: return None
    a_clean = a.split(',')[0].split()[0]
    b_clean = b.split(',')[0].split()[0]
    if a_clean == b_clean: return 0

    fa, fb = _first_int(a_clean), _first_int(b_clean)
    pairs = [(a_clean, b_clean)]
    # If one side's leading int is an order of magnitude bigger than the
    # other, it's probably a Chromium-style prefix concatenated onto the real
    # version (Brave: "148.1.90.122" = chromium_major + "." + brave_version).
    # Try stripping the leading segment from that side only.
    if fa is not None and fb is not None:
        if fa >= 10 * max(fb, 1) and '.' in a_clean:
            pairs.append((a_clean.split('.', 1)[1], b_clean))
        if fb >= 10 * max(fa, 1) and '.' in b_clean:
            pairs.append((a_clean, b_clean.split('.', 1)[1]))

    for ax, bx in pairs:
        ma, mb = _first_int(ax), _first_int(bx)
        if ma is None or mb is None: continue
        hi, lo = max(ma, mb), max(min(ma, mb), 1)
        if hi < 10 * lo:
            return _sortv(ax, bx)
    return None

brew_managed = get_brew_apps()
mas_managed  = get_mas_apps()
managed      = set(brew_managed) | set(mas_managed)
installed    = {p.name for p in APPS_DIR.glob('*.app')}
unmanaged    = installed - managed

print(f'  {len(installed)} apps in /Applications')
print(f'  brew: {len(brew_managed)}  mas: {len(mas_managed)}  unmanaged: {len(unmanaged)}')

registry = json.loads(REGISTRY.read_text()) if REGISTRY.exists() else {}
changed  = False

for name in [n for n in list(registry) if n in managed or n not in installed]:
    print(f'  - {name} (now managed or removed)')
    del registry[name]; changed = True

brew_suggestions = []
for name in sorted(unmanaged - set(registry)):
    plist = APPS_DIR / name / 'Contents' / 'Info.plist'
    if plist.exists():
        feed = plist_get(plist, 'SUFeedURL')
        if feed:
            entry = {'manager': 'sparkle', 'feed_url': feed}
        elif (APPS_DIR / name / 'Contents/Frameworks/Electron Framework.framework').exists():
            entry = {'manager': 'electron'}
        else:
            entry = {'manager': 'unmanaged'}
    else:
        entry = {'manager': 'unmanaged'}

    # check if a brew cask exists for this app (pass installed version so we
    # pick the right variant when multiple casks install the same .app)
    installed_ver = plist_get(plist, 'CFBundleShortVersionString') if plist.exists() else ''
    cask = find_brew_cask(name, installed_ver)
    if cask:
        entry['brew_cask_available'] = cask['token']
        brew_suggestions.append((name, cask['token']))

    print(f'  + {name}  [{entry["manager"]}]{f"  → brew cask: {cask["token"]}" if cask else ""}')
    registry[name] = entry; changed = True

if changed:
    REGISTRY.write_text(json.dumps(registry, indent=2, sort_keys=True))
    print(f'  Saved → {REGISTRY}')
else:
    print(f'  Up to date')

counts = Counter(e['manager'] for e in registry.values())
print(f'  sparkle: {counts.get("sparkle",0)}  electron: {counts.get("electron",0)}  unmanaged: {counts.get("unmanaged",0)}')

# Standing list of every unmanaged-by-brew/mas app, grouped by how it updates —
# so the user knows at a glance which apps to keep an eye on manually.
def _grouped(predicate):
    return sorted(n[:-4] for n, e in registry.items() if predicate(e))
_sparkle  = _grouped(lambda e: e['manager'] == 'sparkle')
_electron = _grouped(lambda e: e['manager'] == 'electron')
_brewable = _grouped(lambda e: e.get('brew_cask_available'))
_orphan   = _grouped(lambda e: e['manager'] == 'unmanaged' and not e.get('brew_cask_available'))
if _sparkle:
    print(f'\n  Sparkle (self-update on launch):')
    for n in _sparkle: print(f'    • {n}')
if _electron:
    print(f'\n  Electron (self-update on launch):')
    for n in _electron: print(f'    • {n}')
if _brewable:
    print(f'\n  Brew cask available (offered below):')
    for n in _brewable: print(f'    • {n}')
if _orphan:
    print(f'\n  Unmanaged — no auto-update detected (check manually):')
    for n in _orphan: print(f'    • {n}')

# categorize all brew-cask-available apps by version comparison
safe = []       # brew >= installed (safe to install/upgrade)
downgrade = []  # brew < installed (would downgrade, skip)
mismatch = []   # versions look structurally incompatible (wrong cask or scheme)
unknown = []    # missing version info on either side

for n, e in registry.items():
    plist = APPS_DIR / n / 'Contents' / 'Info.plist'
    installed_ver = plist_get(plist, 'CFBundleShortVersionString') if plist.exists() else ''
    # re-resolve every run: catches both stale entries (wrong cask) and
    # apps that previously had no mapping but now match (e.g. after we
    # taught the catalog to read uninstall.delete for pkg-style casks)
    cask_info = find_brew_cask(n, installed_ver) or {}
    new_token = cask_info.get('token')
    cur_token = e.get('brew_cask_available')
    if new_token != cur_token:
        if new_token:
            e['brew_cask_available'] = new_token; changed = True
            verb = 'added' if not cur_token else 'updated'
            print(f'  ⟳ cask mapping {verb}: {n[:-4]} → {new_token}')
        elif cur_token:
            del e['brew_cask_available']; changed = True
            print(f'  ⟳ cask mapping removed: {n[:-4]} (was {cur_token})')
    if not new_token: continue
    token = new_token
    if token in declined_casks: continue   # user previously said No to this cask
    brew_ver = cask_info.get('version', '')
    if not brew_ver or not installed_ver:
        unknown.append((n, token, brew_ver, installed_ver))
    else:
        c = cmp_version(brew_ver, installed_ver)
        if c is None:
            mismatch.append((n, token, brew_ver, installed_ver))
        elif c >= 0:
            safe.append((n, token, brew_ver, installed_ver))
        else:
            downgrade.append((n, token, brew_ver, installed_ver))

if safe:
    print(f'\n  💡 Brew cask available (safe — same or newer):')
    # group by cask token — many apps can map to one cask (microsoft-office
    # covers Excel, Word, OneNote, ...), so show one cask row with sub-bullets
    by_token = {}
    for n, t, bv, iv in sorted(safe):
        by_token.setdefault(t, []).append((n, bv, iv))
    for t in sorted(by_token):
        items = by_token[t]
        if len(items) == 1:
            n, bv, iv = items[0]
            tag = f'{iv}' if bv == iv else f'{iv} → {bv}'
            print(f'     {n[:-4]}  ({tag})  →  brew install --cask --force {t}')
        else:
            print(f'     {t}  (bundle — covers {len(items)} apps)  →  brew install --cask --force {t}')
            for n, bv, iv in items:
                tag = f'{iv}' if bv == iv else f'{iv} → {bv}'
                print(f'        • {n[:-4]}  ({tag})')

if downgrade:
    print(f'\n  ⚠  Brew has older version (would downgrade — skipped):')
    for n, t, bv, iv in sorted(downgrade):
        print(f'     {n[:-4]}: installed {iv}, brew {bv}')

if mismatch:
    print(f'\n  ≠  Version schemes differ — different cask variant or product? (skipped):')
    for n, t, bv, iv in sorted(mismatch):
        print(f'     {n[:-4]}: installed {iv}, brew "{t}" reports {bv}')

if unknown:
    print(f'\n  ?  Brew cask available (version unknown):')
    for n, t, bv, iv in sorted(unknown):
        print(f'     {n[:-4]}  →  brew install --cask --force {t}')

if not (safe or downgrade or mismatch or unknown):
    print(f'\n  ✓ No unmanaged apps have a matching brew cask — nothing to suggest')

# persist any registry changes made during categorization (self-healed tokens)
if changed:
    REGISTRY.write_text(json.dumps(registry, indent=2, sort_keys=True))

# write safe-to-install cask tokens (deduped, order preserved) to tempfile for
# the shell loop. Without dedup, bundles like microsoft-office would be
# installed once per app they cover.
safe_file = os.environ.get('_BREW_SAFE_LIST', '')
if safe_file and safe:
    seen = set()
    with open(safe_file, 'w') as f:
        for n, t, bv, iv in safe:
            if t in seen: continue
            seen.add(t)
            f.write(t + '\n')
PYEOF

# Offer to install the safe brew casks via a multi-select. Anything the user
# UNTICKS (i.e. has visible in the list but excludes from selection) goes
# into the persistent decline file so we don't re-offer it next run. Cancel
# = skip the whole prompt, no persistence, ask again next time.
if [[ -s "$_BREW_SAFE_LIST" ]]; then
  _to_install=()
  _to_decline=()
  # Per-cask Yes/No. AppleScript's `choose from list` was visually ambiguous
  # (no checkbox glyphs; single highlight only) and gave no way to tell
  # selected vs unselected at a glance. ask_yn is unambiguous in both GUI
  # and terminal. "No" persists as a decline so we don't re-ask next run.
  while IFS= read -r _t; do
    [[ -z "$_t" ]] && continue
    if ask_yn "Install $_t? (No = don't offer it again)"; then
      _to_install+=("$_t")
    else
      _to_decline+=("$_t")
    fi
  done < "$_BREW_SAFE_LIST"

  for _cask in "${_to_install[@]}"; do
    echo ""
    echo "  → brew install --cask --force --quiet $_cask"
    # `|| true` keeps `set -uo pipefail` from killing the loop on the very
    # first cask conflict; we recover the real brew exit code below.
    { brew install --cask --force --quiet "$_cask" 2>&1 | _brew_filter; } || true
    [[ ${pipestatus[1]} -eq 0 ]] || echo "    ✗ install failed for $_cask (continuing)"
  done

  if (( ${#_to_decline[@]} > 0 )); then
    _decline_tmp=$(mktemp)
    printf '%s\n' "${_to_decline[@]}" > "$_decline_tmp"
    DECLINE_INPUT="$_decline_tmp" python3 - <<'PYEOF'
import json, os
from pathlib import Path
declined_path = Path(os.environ['_STATE_DIR']) / 'declined-casks.json'
existing = set()
if declined_path.exists():
    try: existing = set(json.loads(declined_path.read_text()))
    except Exception: pass
with open(os.environ['DECLINE_INPUT']) as f:
    new = {ln.strip() for ln in f if ln.strip()}
existing |= new
declined_path.write_text(json.dumps(sorted(existing), indent=2))
print(f"  ↳ Won't re-offer: {', '.join(sorted(new))}")
print(f"     Reset: rm \"{declined_path}\"")
PYEOF
    rm -f "$_decline_tmp"
  fi
fi
rm -f "$_BREW_SAFE_LIST"
unset _BREW_SAFE_LIST

# ══════════════════════════════════════════
#  2. UPDATE MANAGED APPS
#     brew (formulae + casks), mas
# ══════════════════════════════════════════
print_header "Homebrew — formulae"
if ! brew update &>/dev/null; then
  echo "  ⚠ brew update failed (network down or VPN not connected?) — continuing with cached formulae"
fi
run_or_ok "All formulae up to date" brew upgrade --quiet || echo "  ⚠ brew upgrade failed — continuing"

print_header "Homebrew — casks"

# Drift recovery: brew's Caskroom "backup" turns into a symlink back to
# /Applications/<App>.app once an install succeeds — so if a prior run was
# interrupted between `rm /Applications/X.app` and the copy-in (SIGINT,
# crash, network drop), there's no real backup to restore from and brew's
# own metadata still thinks the cask is installed. Fix: for each known cask
# whose /Applications target is missing or has no Contents/MacOS, run
# `brew reinstall --cask --force` so brew re-fetches from upstream.
_restore_drifted_casks() {
  local _casks=$(brew list --cask 2>/dev/null)
  [[ -z "$_casks" ]] && return
  # cask token + every /Applications/*.app it installs (both `app:` and
  # uninstall.delete paths so pkg-style casks like brave-browser, zoom, etc.
  # are covered).
  local _map
  _map=$(echo "$_casks" | xargs brew info --cask --json=v2 2>/dev/null | python3 -c "
import json, sys, os
try:
    d = json.load(sys.stdin)
    for c in d.get('casks', []):
        token = c['token']; seen = set()
        for art in c.get('artifacts', []):
            if not isinstance(art, dict): continue
            for n in art.get('app', []) or []:
                if isinstance(n, str): seen.add(n)
            for u in art.get('uninstall', []) or []:
                if not isinstance(u, dict): continue
                for p in u.get('delete', []) or []:
                    if isinstance(p, str) and p.startswith('/Applications/') \
                       and p.endswith('.app') and '*' not in p:
                        seen.add(os.path.basename(p))
        if seen:
            print(token + '\t' + ','.join(sorted(seen)))
except Exception: pass
") || true
  [[ -z "$_map" ]] && return

  # Classify each cask:
  #   total   — every app it installs is missing → bundle broken (interrupted
  #             install, crash, etc.) → offer reinstall.
  #   partial — some of its apps missing, others present → user clearly
  #             removed specific apps from a bundle cask (e.g. Microsoft
  #             Defender from microsoft-office). Silent skip; reinstalling
  #             the whole bundle would clobber the current versions of the
  #             other apps and resurrect what the user removed — exactly the
  #             surprise we want to avoid.
  local _missing_total=()
  local _partial=()
  while IFS=$'\t' read -r _token _csv; do
    [[ -z "$_token" || -z "$_csv" ]] && continue
    # zsh-native split — `read -A` here was noisily echoing `_apps=(...)`
    # for every iteration. (s:,:) splits on commas without that side effect.
    local _apps=("${(@s:,:)_csv}")
    local _missing_list="" _present_list=""
    for _app in "${_apps[@]}"; do
      if [[ -d "/Applications/$_app/Contents/MacOS" ]]; then
        _present_list+="${_present_list:+, }$_app"
      else
        _missing_list+="${_missing_list:+, }$_app"
      fi
    done
    if [[ -n "$_missing_list" && -z "$_present_list" ]]; then
      _missing_total+=("$_token|$_csv")
    elif [[ -n "$_missing_list" ]]; then
      _partial+=("$_token|$_missing_list|$_present_list")
    fi
  done <<< "$_map"

  if (( ${#_partial[@]} > 0 )); then
    echo "  ℹ Cask bundles with SOME apps removed (treating as deliberate, not reinstalling):"
    for _entry in "${_partial[@]}"; do
      local _t _m _p
      IFS='|' read -r _t _m _p <<< "$_entry"
      echo "     • $_t"
      echo "       missing: $_m"
      echo "       present: $_p"
      echo "       to drop brew's tracking:        brew uninstall --cask $_t"
      echo "       to bring all missing apps back: brew reinstall --cask --force $_t"
    done
  fi

  (( ${#_missing_total[@]} == 0 )) && return

  echo ""
  echo "  ⚠ Cask bundles with ALL apps missing from /Applications:"
  for _entry in "${_missing_total[@]}"; do
    IFS='|' read -r _token _csv <<< "$_entry"
    echo "     • $_token  ($_csv)"
  done
  echo ""
  echo "    Likely an interrupted install. Reinstall re-fetches the bundle from upstream."
  echo "    If removal was deliberate: \`brew uninstall --cask <token>\`"
  if ask_yn "Reinstall the ${#_missing_total[@]} cask(s)?"; then
    for _entry in "${_missing_total[@]}"; do
      IFS='|' read -r _token _csv <<< "$_entry"
      echo "  ↻ brew reinstall --cask $_token"
      brew reinstall --cask --force --quiet "$_token" 2>&1 | _brew_filter || true
    done
  else
    echo "  ⊘ Skipped — brew metadata still references the missing bundle(s)."
  fi
}
_restore_drifted_casks

_cask_log=$(mktemp)
{ brew upgrade --cask --greedy --quiet 2>&1 || true; } | _brew_filter | tee "$_cask_log"
[[ -s "$_cask_log" ]] || echo "  ✓ All casks up to date"

_stuck=()
while IFS= read -r _line; do
  # Two flavours of brew cask "out of sync with disk" errors:
  #  - "It seems there is already an App at ..." — pre-existing app blocks brew
  #  - "It seems the App source ... is not there"   — app missing, brew bumped
  #    its metadata but the .app on disk never updated (silent drift)
  if [[ "$_line" =~ ^'Error: '([^:]+)': It seems (there is already an App|the App source)' ]]; then
    _stuck+=("${match[1]}")
  fi
done < "$_cask_log"
rm -f "$_cask_log"

if [[ ${#_stuck[@]} -gt 0 ]]; then
  echo ""
  echo "  ⚠ Stale install detected: ${_stuck[*]}"
  if ask_yn "Reinstall now?"; then
    for _cask in "${_stuck[@]}"; do
      brew reinstall --cask "$_cask"
    done
  fi
fi

# Strip com.apple.quarantine — brew removed the --no-quarantine flag so we do
# it ourselves to skip the Gatekeeper "verifying X.app" dialog on first launch.
# Fast path: `xattr -p` checks for the attribute (one stat call per .app); only
# the apps that actually have it pay for the recursive `xattr -dr` (which can
# be tens of seconds on bundles with thousands of files). Parallel for speed.
find /Applications -maxdepth 2 -name '*.app' -print0 2>/dev/null \
  | xargs -0 -P 8 -I{} sh -c '
      xattr -p com.apple.quarantine "$1" >/dev/null 2>&1 || exit 0
      xattr -dr com.apple.quarantine "$1" 2>/dev/null
    ' _ {}

# brew cleanup — capture output so we can detect permission errors
_cleanup_log=$(mktemp)
brew cleanup &>"$_cleanup_log" || true

_stuck_kegs=()
_capture=0
while IFS= read -r _line; do
  if [[ "$_line" == "Error: Could not cleanup old kegs! Fix your permissions on:" ]]; then
    _capture=1
    continue
  fi
  if [[ "$_capture" == 1 ]]; then
    if [[ "$_line" =~ ^[[:space:]]+(/.+)$ ]]; then
      _stuck_kegs+=("${match[1]}")
    else
      _capture=0
    fi
  fi
done < "$_cleanup_log"
rm -f "$_cleanup_log"

if [[ ${#_stuck_kegs[@]} -gt 0 ]]; then
  echo ""
  echo "  ⚠ Cleanup blocked by permission errors:"
  for _k in "${_stuck_kegs[@]}"; do echo "    $_k"; done
  if ask_yn "Remove these with sudo?"; then
    for _k in "${_stuck_kegs[@]}"; do
      sudo rm -rf "$_k"
    done
    brew cleanup &>/dev/null || true
  fi
fi

if ! _skip_section "MacPorts"; then
  print_header "MacPorts"
  if command -v port &>/dev/null; then
    sudo port selfupdate &>/dev/null || echo "  ⚠ port selfupdate failed — continuing"
    out=$(sudo port upgrade outdated 2>&1 || true)
    if echo "$out" | grep -q "Nothing to upgrade"; then
      echo "  ✓ All ports up to date"
    else
      echo "$out"
    fi
  else
    echo "  port not installed — skipping"
  fi
fi

if ! _skip_section "Mac App Store"; then
  print_header "Mac App Store"
  if command -v mas &>/dev/null; then
    run_or_ok "All App Store apps up to date" mas upgrade
  else
    echo "  mas not installed — skipping"
  fi
fi

# ══════════════════════════════════════════
#  3. CLI TOOLS
#     npm, gem, rustup, pipx, claude
# ══════════════════════════════════════════
if ! _skip_section "npm"; then
  print_header "npm"
  if command -v npm &>/dev/null; then
    # update npm itself first, then use the new npm to update global packages
    _npm_before=$(npm --version 2>/dev/null)
    npm install -g npm@latest &>/dev/null || true
    _npm_after=$(npm --version 2>/dev/null)
    [[ "$_npm_before" != "$_npm_after" ]] && echo "  npm: $_npm_before → $_npm_after"
    outdated=$( { npm outdated -g --parseable 2>/dev/null || true; } | wc -l | tr -d ' ')
    if [[ "$outdated" -gt 0 ]]; then
      npm update -g
    else
      echo "  ✓ All global packages up to date"
    fi
  else
    echo "  npm not installed — skipping"
  fi
fi

if ! _skip_section "Ruby gems"; then
  print_header "Ruby gems"
  # Apple's system Ruby is frozen at an old version that rejects modern gems
  # → install + use Homebrew Ruby instead (keg-only, invoked by full path so PATH is irrelevant)
  if ! brew list --formula ruby &>/dev/null; then
    echo "  Installing modern Ruby via Homebrew..."
    brew install ruby || echo "  ✗ Failed to install ruby"
  fi
  _gem="$(brew --prefix ruby 2>/dev/null)/bin/gem"
  if [[ -x "$_gem" ]]; then
    "$_gem" update --system &>/dev/null || true
    out=$("$_gem" update 2>&1 \
          | grep -vE 'warning: (already initialized constant|previous definition of)' \
          || true)
    if [[ -z "$out" ]] || echo "$out" | grep -q "Nothing to update"; then
      echo "  ✓ All gems up to date"
    else
      echo "$out"
    fi
  else
    echo "  gem not available — skipping"
  fi
fi

if ! _skip_section "Rust (rustup)"; then
  print_header "Rust (rustup)"
  if command -v rustup &>/dev/null; then
    rustup self update &>/dev/null || true
    rustup update
  else
    echo "  rustup not installed — skipping"
  fi
fi

if ! _skip_section "pipx"; then
  print_header "pipx"
  if command -v pipx &>/dev/null; then
    run_or_ok "All pipx packages up to date" pipx upgrade-all
  else
    echo "  pipx not installed — skipping"
  fi
fi

if ! _skip_section "Claude Code"; then
  print_header "Claude Code"
  if command -v claude &>/dev/null; then
    out=$(claude update 2>&1)
    if echo "$out" | grep -q "up to date"; then
      echo "  ✓ $(echo "$out" | grep -o 'Claude Code is up to date.*')"
    else
      echo "$out"
    fi
  else
    echo "  claude not installed — skipping"
  fi
fi

# ══════════════════════════════════════════
#  4. UNMANAGED APPS — SPARKLE UPDATES
#     Apps not in brew/mas: check feeds,
#     download and install if newer
# ══════════════════════════════════════════
print_header "Sparkle updates (unmanaged apps)"
python3 - << 'PYEOF'
import json, os, subprocess, tempfile
from pathlib import Path
from urllib.request import urlopen, Request
import xml.etree.ElementTree as ET

STATE_DIR  = Path(os.environ['_STATE_DIR'])
REGISTRY   = STATE_DIR / 'apps.json'
APPS_DIR   = Path('/Applications')

def plist_get(plist, key):
    r = subprocess.run(['/usr/libexec/PlistBuddy', '-c', f'Print {key}', str(plist)],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None

def version_gt(a, b):
    if a == b: return False
    r = subprocess.run(['bash', '-c', f'printf "%s\\n%s\\n" "{a}" "{b}" | sort -V | tail -1'],
                       capture_output=True, text=True)
    return r.stdout.strip() == b

def fetch_sparkle(feed_url):
    try:
        with urlopen(Request(feed_url, headers={'User-Agent': 'Sparkle/2.0'}), timeout=10) as r:
            root = ET.fromstring(r.read())
        namespaces = [
            'http://www.andymatuschak.org/xml-namespaces/sparkle',
            'https://www.andymatuschak.org/xml-namespaces/sparkle',
        ]
        best_ver = best_url = None
        for item in root.findall('.//item'):
            enc = item.find('enclosure')
            if enc is None: continue
            ver = None
            for ns in namespaces:
                def el_text(tag, ns=ns):
                    el = item.find(f'{{{ns}}}{tag}')
                    return el.text.strip() if el is not None and el.text else None
                ver = (el_text('shortVersionString') or el_text('version')
                       or enc.get(f'{{{ns}}}shortVersionString') or enc.get(f'{{{ns}}}version'))
                if ver: break
            url = enc.get('url')
            if ver and url and (best_ver is None or version_gt(best_ver, ver)):
                best_ver, best_url = ver, url
        return best_ver, best_url
    except Exception:
        return None, None

def run(*args, **kw):
    return subprocess.run(list(args), **kw)

def install_update(app_path, url, new_ver):
    ext = url.split('?')[0].rsplit('.', 1)[-1].lower()
    with tempfile.TemporaryDirectory() as tmp:
        pkg = os.path.join(tmp, f'update.{ext}')
        print('    Downloading...', flush=True)
        if run('curl', '-L', '--progress-bar', '-o', pkg, url).returncode != 0:
            print('    ✗ download failed'); return False

        if ext == 'dmg':
            r = run('hdiutil', 'attach', pkg, '-nobrowse', '-quiet', capture_output=True, text=True)
            if r.returncode != 0: print('    ✗ mount failed'); return False
            vol = r.stdout.strip().splitlines()[-1].split('\t')[-1]
            try:
                apps = subprocess.run(f'find "{vol}" -maxdepth 2 -name "*.app" | head -1',
                                      shell=True, capture_output=True, text=True).stdout.strip()
                if not apps: print('    ✗ no .app in DMG'); return False
                dest = os.path.join('/Applications', os.path.basename(apps))
                run('rm', '-rf', dest)
                run('cp', '-R', apps, '/Applications/')
                print(f'    ✓ updated to {new_ver}'); return True
            finally:
                run('hdiutil', 'detach', vol, '-quiet', capture_output=True)

        elif ext == 'zip':
            ex = os.path.join(tmp, 'x')
            if run('unzip', '-q', pkg, '-d', ex).returncode != 0:
                print('    ✗ unzip failed'); return False
            apps = subprocess.run(f'find "{ex}" -maxdepth 3 -name "*.app" | head -1',
                                  shell=True, capture_output=True, text=True).stdout.strip()
            if not apps: print('    ✗ no .app in ZIP'); return False
            dest = os.path.join('/Applications', os.path.basename(apps))
            run('rm', '-rf', dest)
            run('cp', '-R', apps, '/Applications/')
            print(f'    ✓ updated to {new_ver}'); return True

        elif ext == 'pkg':
            if run('sudo', 'installer', '-pkg', pkg, '-target', '/').returncode == 0:
                print(f'    ✓ updated to {new_ver} (pkg)'); return True
            return False
        else:
            print(f'    ✗ unknown format: .{ext}'); return False

registry = json.loads(REGISTRY.read_text()) if REGISTRY.exists() else {}

for name, entry in sorted(registry.items()):
    if entry['manager'] != 'sparkle': continue

    app_path      = APPS_DIR / name
    installed_ver = plist_get(app_path / 'Contents' / 'Info.plist', 'CFBundleShortVersionString') or '?'
    feed_url      = entry.get('feed_url', '')
    if not feed_url: print(f'  ? {name}: no feed URL'); continue

    latest_ver, dl_url = fetch_sparkle(feed_url)
    if not latest_ver: print(f'  ✗ {name[:-4]}: feed unreachable'); continue

    if not version_gt(installed_ver, latest_ver):
        print(f'  ✓ {name[:-4]} {installed_ver}')
    else:
        print(f'  ↑ {name[:-4]}: {installed_ver} → {latest_ver}')
        if not dl_url: print('    no download URL — skipping'); continue
        if install_update(app_path, dl_url, latest_ver):
            registry[name]['last_version'] = latest_ver
            REGISTRY.write_text(json.dumps(registry, indent=2, sort_keys=True))

PYEOF

# ══════════════════════════════════════════
#  5. macOS SOFTWARE UPDATE
#     Last so a reboot won't interrupt the rest
# ══════════════════════════════════════════
print_header "macOS Software Update"
_su_log=$(mktemp)
softwareupdate --list &>"$_su_log" || true

_su_count=$(grep -c '^\* Label:' "$_su_log" 2>/dev/null) || _su_count=0

if [[ "$_su_count" -eq 0 ]]; then
  echo "  ✓ No updates available"
else
  # show only the relevant lines (skip "Software Update Tool" preamble)
  grep -E '^\* Label:|^[[:space:]]+Title:' "$_su_log" | sed 's/^/  /'
  echo ""
  # detect if any of the available updates require a restart, BEFORE installing
  _has_restart=$(grep -c 'Action: restart' "$_su_log" 2>/dev/null) || _has_restart=0
  if ask_yn "Install all $_su_count update(s)?"; then
    sudo softwareupdate --install --all

    if [[ "$_has_restart" -gt 0 ]]; then
      echo ""
      echo "  ℹ A macOS update has been staged — it will install on next restart."
      if [[ -n "${UPDATER_GUI:-}" ]] || ! [[ -t 0 ]]; then
        _ru_action=$(osascript \
          -e 'tell application id "com.gunnar.update-all" to activate' \
          -e 'button returned of (display dialog "A macOS update has been staged and will install on next restart." buttons {"Restart to install", "Show in System Settings", "Acknowledged"} default button "Acknowledged" cancel button "Acknowledged" with title "Update All" with icon note)' \
          2>/dev/null || echo "")
        echo "  → ${_ru_action:-cancelled}"
        case "$_ru_action" in
          "Restart to install")
            osascript -e 'tell application "System Events" to restart' ;;
          "Show in System Settings")
            open "x-apple.systempreferences:com.apple.preferences.softwareupdate" ;;
        esac
      fi
    fi
  else
    echo "  ⊘ Skipped"
  fi
fi
rm -f "$_su_log"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ All done."
