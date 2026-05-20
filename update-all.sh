#!/usr/bin/env zsh
set -euo pipefail

export _SCRIPT_DIR="${0:A:h}"

print_header() {
  local cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
  echo ""
  printf '━%.0s' {1..$cols}
  printf '\n  %s\n' "$1"
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

# ══════════════════════════════════════════
#  1. UPDATE APP REGISTRY
#     Scan /Applications vs brew/mas lists,
#     detect update method for new apps,
#     save to apps.json
# ══════════════════════════════════════════
print_header "App registry"
python3 - << 'PYEOF'
import json, os, subprocess
from pathlib import Path
from collections import Counter

SCRIPT_DIR = Path(os.environ['_SCRIPT_DIR'])
REGISTRY   = SCRIPT_DIR / 'apps.json'
APPS_DIR   = Path('/Applications')

def plist_get(plist, key):
    r = subprocess.run(['/usr/libexec/PlistBuddy', '-c', f'Print {key}', str(plist)],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None

def get_brew_apps():
    casks = subprocess.run(['brew', 'list', '--cask'], capture_output=True, text=True).stdout.split()
    if not casks: return {}
    r = subprocess.run(['brew', 'info', '--cask', '--json=v2'] + casks, capture_output=True, text=True)
    result = {}
    try:
        for c in json.loads(r.stdout).get('casks', []):
            for a in c.get('artifacts', []):
                if isinstance(a, dict) and 'app' in a:
                    for name in a['app']:
                        if isinstance(name, str):
                            result[name] = c['token']
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
    """Download (or reuse cached) full Homebrew cask catalog. Returns app_name→token dict."""
    catalog_path = REGISTRY.parent / 'brew_cask_catalog.json'
    import time
    # refresh if older than 24h
    if catalog_path.exists() and time.time() - catalog_path.stat().st_mtime < 86400:
        catalog = json.loads(catalog_path.read_text())
    else:
        r = subprocess.run(['curl', '-sf', 'https://formulae.brew.sh/api/cask.json'],
                           capture_output=True, text=True)
        if r.returncode != 0: return {}
        casks = json.loads(r.stdout)
        catalog = {}
        for c in casks:
            for art in c.get('artifacts', []):
                if isinstance(art, dict) and 'app' in art:
                    for app in art['app']:
                        if isinstance(app, str):
                            catalog[app.lower().removesuffix('.app')] = c['token']
        catalog_path.write_text(json.dumps(catalog))
    return catalog

_cask_catalog = None
def find_brew_cask(app_name):
    """Find a brew cask that actually installs this app. Returns cask token or None."""
    global _cask_catalog
    if _cask_catalog is None:
        _cask_catalog = load_cask_catalog()
    return _cask_catalog.get(app_name.lower().removesuffix('.app'))

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

    # check if a brew cask exists for this app
    cask = find_brew_cask(name)
    if cask:
        entry['brew_cask_available'] = cask
        brew_suggestions.append((name, cask))

    print(f'  + {name}  [{entry["manager"]}]{f"  → brew cask: {cask}" if cask else ""}')
    registry[name] = entry; changed = True

if changed:
    REGISTRY.write_text(json.dumps(registry, indent=2, sort_keys=True))
    print(f'  Saved → {REGISTRY}')
else:
    print(f'  Up to date')

counts = Counter(e['manager'] for e in registry.values())
print(f'  sparkle: {counts.get("sparkle",0)}  electron: {counts.get("electron",0)}  unmanaged: {counts.get("unmanaged",0)}')

# show all known brew cask suggestions (new + previously detected)
all_suggestions = [(n, e['brew_cask_available']) for n, e in registry.items()
                   if e.get('brew_cask_available') and n not in {s[0] for s in brew_suggestions}]
brew_suggestions += all_suggestions
if brew_suggestions:
    print(f'\n  💡 Brew cask available for unmanaged apps:')
    for app, cask in sorted(brew_suggestions):
        print(f'     {app[:-4]}  →  brew install --cask {cask}')
PYEOF

# ══════════════════════════════════════════
#  2. UPDATE MANAGED APPS
#     brew (formulae + casks), mas, macOS
# ══════════════════════════════════════════
print_header "Homebrew — formulae"
brew update &>/dev/null
run_or_ok "All formulae up to date" brew upgrade

print_header "Homebrew — casks"
_cask_log=$(mktemp)
{ brew upgrade --cask --greedy 2>&1 || true; } | tee "$_cask_log"
[[ -s "$_cask_log" ]] || echo "  ✓ All casks up to date"

_stuck=()
while IFS= read -r _line; do
  if [[ "$_line" =~ ^'Error: '([^:]+)': It seems there is already an App' ]]; then
    _stuck+=("${match[1]}")
  fi
done < "$_cask_log"
rm -f "$_cask_log"

if [[ ${#_stuck[@]} -gt 0 ]]; then
  echo ""
  echo "  ⚠ Stale install detected: ${_stuck[*]}"
  echo -n "  Reinstall now? [y/N] "
  read -k1 _ans; echo ""
  if [[ "$_ans" == [yY] ]]; then
    for _cask in "${_stuck[@]}"; do
      brew reinstall --cask "$_cask"
    done
  fi
fi

brew cleanup &>/dev/null

print_header "Mac App Store"
if command -v mas &>/dev/null; then
  run_or_ok "All App Store apps up to date" mas upgrade
else
  echo "  mas not installed — skipping"
fi

print_header "macOS Software Update"
run_or_ok "No updates available" sudo softwareupdate --install --all

# ══════════════════════════════════════════
#  3. CLI TOOLS
#     npm, gem, rustup, pipx, claude
# ══════════════════════════════════════════
print_header "npm"
if command -v npm &>/dev/null; then
  outdated=$(npm outdated -g --parseable 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$outdated" -gt 0 ]]; then
    npm update -g
    npm install -g npm@latest
  else
    echo "  ✓ All global packages up to date"
  fi
else
  echo "  npm not installed — skipping"
fi

print_header "Ruby gems"
if command -v gem &>/dev/null; then
  gem update --system &>/dev/null
  out=$(gem update 2>&1)
  if echo "$out" | grep -q "Nothing to update"; then
    echo "  ✓ All gems up to date"
  else
    echo "$out"
  fi
else
  echo "  gem not installed — skipping"
fi

print_header "Rust (rustup)"
if command -v rustup &>/dev/null; then
  rustup update
else
  echo "  rustup not installed — skipping"
fi

print_header "pipx"
if command -v pipx &>/dev/null; then
  run_or_ok "All pipx packages up to date" pipx upgrade-all
else
  echo "  pipx not installed — skipping"
fi

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

SCRIPT_DIR = Path(os.environ['_SCRIPT_DIR'])
REGISTRY   = SCRIPT_DIR / 'apps.json'
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

electron_unmanaged = []
for name, entry in sorted(registry.items()):
    if entry['manager'] == 'electron':
        electron_unmanaged.append(name); continue
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

if electron_unmanaged:
    print('\n  Electron apps (self-update on launch):')
    for e in electron_unmanaged:
        print(f'    • {e}')
PYEOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  All done."
