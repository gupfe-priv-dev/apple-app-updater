#!/usr/bin/env python3
# sparkle.py — check Sparkle appcast feeds for registry apps and install newer
# versions (DMG/ZIP/PKG). Bridge extracted verbatim from update-all.sh; ported
# to Swift in Phase 4.
#
# Reads env: _STATE_DIR. Reads apps.json there; updates last_version on success.
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
checked = 0
for name, entry in sorted(registry.items()):
    if entry.get('manager') != 'sparkle': continue
    checked += 1
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
if checked == 0:
    print('  ✓ No Sparkle apps tracked')
