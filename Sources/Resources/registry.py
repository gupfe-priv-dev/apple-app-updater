#!/usr/bin/env python3
# registry.py — app registry maintenance + brew-cask suggestion engine.
#
# Bridge extracted verbatim from update-all.sh's Phase-1 Python heredoc so the
# Swift RegistryTool can drive it while the logic is ported to Swift (Phase 4).
#
# Reads env: _STATE_DIR, _CACHE_DIR, _SCRIPT_DIR (optional), _BREW_SAFE_LIST
# (optional path; receives newline-separated "safe to install" cask tokens).
import json, os, subprocess
from pathlib import Path
from collections import Counter

SCRIPT_DIR = Path(os.environ.get('_SCRIPT_DIR', '/tmp'))
STATE_DIR  = Path(os.environ['_STATE_DIR'])
CACHE_DIR  = Path(os.environ['_CACHE_DIR'])
REGISTRY   = STATE_DIR / 'apps.json'
APPS_DIR   = Path('/Applications')

for _old in (SCRIPT_DIR / 'apps.json', SCRIPT_DIR.parent / 'apps.json'):
    if _old.exists() and not REGISTRY.exists():
        try: _old.rename(REGISTRY); print(f'  migrated apps.json → {REGISTRY}')
        except Exception: pass

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
            for a in art.get('app', []) or []:
                if isinstance(a, str): apps_for_this.add(a)
            for u in art.get('uninstall', []) or []:
                if not isinstance(u, dict): continue
                for path in u.get('delete', []) or []:
                    if not isinstance(path, str): continue
                    if not (path.startswith('/Applications/') and path.endswith('.app')): continue
                    if '*' in path: continue
                    name = os.path.basename(path)
                    if name: apps_for_this.add(name)
        for a in apps_for_this:
            catalog.setdefault(a.lower().removesuffix('.app'), []).append({
                'token': token, 'version': ver,
            })
    catalog_path.write_text(json.dumps(catalog))
    print(f'    ✓ catalog indexed: {len(catalog)} apps from {len(casks)} casks', flush=True)
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
    return max(candidates, key=lambda c: major(c.get('version', '')))

import re as _re
def _first_int(s):
    m = _re.match(r'(\d+)', s or '')
    return int(m.group(1)) if m else None

def _sortv(a, b):
    if a == b: return 0
    r = subprocess.run(['bash', '-c', f'printf "%s\\n%s\\n" "{a}" "{b}" | sort -V | tail -1'],
                       capture_output=True, text=True)
    top = r.stdout.strip()
    return 1 if top == a else (-1 if top == b else 0)

def cmp_version(a, b):
    if not a or not b: return None
    a_clean = a.split(',')[0].split()[0]
    b_clean = b.split(',')[0].split()[0]
    if a_clean == b_clean: return 0
    fa, fb = _first_int(a_clean), _first_int(b_clean)
    pairs = [(a_clean, b_clean)]
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

safe = []; downgrade = []; mismatch = []; unknown = []
for n, e in registry.items():
    plist = APPS_DIR / n / 'Contents' / 'Info.plist'
    installed_ver = plist_get(plist, 'CFBundleShortVersionString') if plist.exists() else ''
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
    if token in declined_casks: continue
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

if changed:
    REGISTRY.write_text(json.dumps(registry, indent=2, sort_keys=True))

safe_file = os.environ.get('_BREW_SAFE_LIST', '')
if safe_file and safe:
    seen = set()
    with open(safe_file, 'w') as f:
        for n, t, bv, iv in safe:
            if t in seen: continue
            seen.add(t)
            f.write(t + '\n')
