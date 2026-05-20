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

## Setup

### 1. Prerequisites

```bash
brew install mas
```

### 2. Build the app

```bash
./build-app.sh
```

This compiles `UpdateAll.swift` → `UpdateAll.app` and ad-hoc code-signs it.

### 3. Run at login (LaunchAgent)

```bash
cp com.gunnar.update-all.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.gunnar.update-all.plist
```

Or double-click `UpdateAll.app` to run manually.

### 4. Touch ID for sudo (recommended)

Some updates (cask installs, `softwareupdate`) need root.
Enable Touch ID for sudo so the app can authenticate without a password prompt:

```bash
printf '# sudo_local: local config file which survives system update and is included by /etc/pam.d/sudo\nauth       sufficient     pam_tid.so\n' \
  | /usr/libexec/authopen -w /etc/pam.d/sudo_local
```

> **Why `authopen`?** `/etc/pam.d/sudo_local` is root-owned and SIP-adjacent.
> `authopen` uses the macOS Authorization framework (GUI password dialog) to write the file,
> bypassing the need for a working `sudo`. This is also safe to run even if `sudo` is broken.

After this, `sudo` prompts with Touch ID instead of a password in any terminal or app.
The file survives macOS updates (it's included by `/etc/pam.d/sudo` via `include sudo_local`).

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
