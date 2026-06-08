# mac-update-all

A macOS system updater that runs at login and keeps everything current:
Homebrew formulae & casks, Mac App Store, macOS software updates, CLI tools (npm, gem, rustup, pipx, Claude Code), and unmanaged apps via Sparkle feeds.

Ships as a native macOS app (`UpdateAll.app`) with a dark terminal-style output window.

---

## What it updates

| Source | Method |
|--------|--------|
| Homebrew formulae | `brew upgrade` |
| Homebrew casks | `brew upgrade --cask --greedy` |
| Mac App Store | `mas upgrade` |
| macOS system | `softwareupdate --install --all` |
| npm global packages | `npm update -g` |
| Ruby gems | `gem update --system && gem update` |
| Rust toolchains | `rustup update` |
| pipx packages | `pipx upgrade-all` |
| Claude Code CLI | `claude update` |
| Unmanaged apps (Sparkle) | Fetches appcast feed, downloads & installs DMG/ZIP/PKG |

---

## App registry (`apps.json`)

On every run, `/Applications` is scanned against the brew/mas lists.
New unmanaged apps are classified automatically:

- **sparkle** — has `SUFeedURL` in `Info.plist` → auto-updated via appcast feed
- **electron** — contains `Electron Framework.framework` → self-updates on launch
- **unmanaged** — everything else (listed for awareness)

If a brew cask exists for an unmanaged app, it's suggested in the output.

The registry is cached in `apps.json` next to the script. Only unmanaged apps are stored — brew/mas lists are re-fetched fresh every run.

---

## Install

One-liner — downloads the latest release, strips the macOS quarantine xattr, and installs to `/Applications`:

```bash
/bin/bash -c "$(curl -fsSL https://cdn.jsdelivr.net/gh/gupfe-priv-dev/apple-app-updater@main/install.sh)"
```

> The URL uses **jsDelivr** instead of `raw.githubusercontent.com` because some corporate proxies aggressively cache the GitHub raw URL and return stale content. jsDelivr's CDN invalidates per commit. The script itself is open — read it before you pipe it.

After install, launch from Spotlight or `open /Applications/UpdateAll.app`. The app's built-in self-update checker hits the GitHub Releases API once per 24 h and surfaces newer releases in its SETTINGS sidebar.

### Prerequisites

```bash
brew install mas
```

`mas` is the Mac App Store CLI; if it's missing the MAS section is skipped silently.

### Source / development install

If you've cloned the repo and want to build + register a LaunchAgent locally:

```bash
./setup.sh
```

`setup.sh` does everything in one shot — two macOS password dialogs will appear (for writing system files):

| Step | What it does |
|------|-------------|
| Build | Compiles `Sources/**/*.swift` → universal `UpdateAll.app`, ad-hoc code-signs it |
| LaunchAgent | Registers the app to open automatically at login |
| Touch ID for sudo | Writes `/etc/pam.d/sudo_local` so `sudo` prompts with Touch ID instead of a password |
| NOPASSWD sudoers | Writes `/etc/sudoers.d/update-all` so `installer` and `softwareupdate` need no prompt at all |

After setup, `UpdateAll.app` opens at every login with no sudo prompts.
Run manually anytime: `open /Applications/UpdateAll.app`.

---

### How the sudo setup works

**Touch ID (`/etc/pam.d/sudo_local`):**
Enables Touch ID as an authentication method for all `sudo` commands.
The file is included by `/etc/pam.d/sudo` and survives macOS updates.
Written via `authopen` (macOS Authorization framework) which works even if `sudo` is broken.

**NOPASSWD (`/etc/sudoers.d/update-all`):**
Allows `installer` and `softwareupdate` to run as root without any prompt.
These are the only two commands in the script that need root — cask pkg installs and macOS system updates.
Everything else (brew formulae, mas, npm, gem, etc.) never needs root.

---

## Files

| File | Purpose |
|------|---------|
| `update-all.sh` | Main update script (zsh) |
| `UpdateAll.swift` | Native app wrapper — streams script output in a dark window |
| `build-app.sh` | Compiles and signs `UpdateAll.app` |
| `update-all.command` | Fallback: double-click to run in Terminal.app |
| `SOURCES.md` | Documentation of all data sources (APIs, feed formats, etc.) |
| `apps.json` | Registry of unmanaged apps (auto-generated, gitignored) |
| `brew_cask_catalog.json` | Cached Homebrew cask catalog (auto-generated, gitignored) |

---

## Adding a new update source

See [`SOURCES.md`](SOURCES.md) for details on the data sources and how to extend the script.
