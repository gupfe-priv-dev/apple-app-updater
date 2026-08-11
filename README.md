# mac-update-all

A macOS system updater that runs at login and keeps everything current:
Homebrew formulae & casks, Mac App Store, macOS software updates, CLI tools (npm, gem, rustup, pipx, Claude Code), and unmanaged apps via Sparkle feeds.

Ships as a native macOS app (`UpdateAll.app`).

---

## The window

One table of everything that's pending, across every package manager, over a
single console:

![The updates window](docs/screenshot-updates.png)

- **Check each row individually.** A manager that can target a subset upgrades
  only what's ticked. One that upgrades everything in a single command (macOS
  Software Update, pipx, Claude Code) keeps its rows ticked as a group, so the
  checkbox never promises something the CLI can't honour.
- **Right-click a row** to update just it, clear a failure flag, hide it from
  future scans, disable its manager, or copy its package id.
- **Failure memory.** A package whose update failed comes back pre-flagged and
  unticked — `⚠ failed 3 days ago (exit 1)` — so a known-bad update doesn't
  silently repeat every run. Clearing it, or a success, forgets it.
- **Settings** is a standard preferences window at ⌘, — managers, system
  access, hidden packages, maintenance.

---

## What it updates

| Source | Check | Apply |
|--------|-------|-------|
| Homebrew formulae | `brew outdated --formula` | `brew upgrade --formula [names]` |
| Homebrew casks | `brew outdated --cask --greedy` | `brew upgrade --cask` per token |
| MacPorts | `port outdated` | `sudo port upgrade [names]` |
| Mac App Store | `mas outdated` | `mas upgrade <id>` |
| macOS system | `softwareupdate --list` | `softwareupdate --install --all` |
| npm global packages | `npm outdated -g` | `npm install -g <pkg>@latest` |
| Ruby gems | `gem list` + RubyGems API | `gem update <name>` |
| Rust toolchains | — | `rustup update` |
| pipx packages | — | `pipx upgrade-all` |
| Claude Code CLI | — | `claude update` |
| Unmanaged apps (Sparkle) | appcast feed per app | downloads & installs DMG/ZIP/PKG |

Casks are upgraded one command per token rather than in one batch: brew
prefetches every download first and aborts the whole run if any single one
fails, so one unreachable host used to take down every other cask.

Gems are checked by listing locally and querying the RubyGems API
concurrently. `gem outdated` asks about each gem one at a time — ~60s for 85
gems, nearly all of it idle network wait.

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

After install, launch from Spotlight or `open /Applications/UpdateAll.app`. The app's built-in self-update checker hits the GitHub Releases API once per 24 h and shows a newer release in the window subtitle (and under Settings → Maintenance).

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
| `Sources/Tool.swift` | The `Tool` protocol every manager implements, plus the availability cache |
| `Sources/Models.swift` | `UpdateItem`, `ScanResult`, `InstallOutcome` |
| `Sources/Tools/` | One file per manager (brew, mas, npm, gem, Sparkle, …) |
| `Sources/Core/Coordinator.swift` | Runs the tools for a scan or a selected install |
| `Sources/Core/History.swift` | Failure memory — which package failed last, and when |
| `Sources/UI/` | Window, updates table, console, settings panes |
| `build-app.sh` | Compiles and signs `UpdateAll.app` (`SKIP_INSTALL=1` to skip installing) |
| `features.sh` | Touch ID / sudoers management (bundled into the app) |
| `SOURCES.md` | Documentation of all data sources (APIs, feed formats, etc.) |
| `apps.json` | Registry of unmanaged apps (auto-generated, gitignored) |

---

## Adding a new update source

Add a file to `Sources/Tools/` implementing `Tool` — `id`, `title`,
`isAvailable()`, `scan()`, `install()` — and list it in `buildToolList()` in
`Sources/AppDelegate.swift`. Implement `install(_:only:)` and set
`supportsTargetedInstall` if the manager can upgrade a subset; otherwise the
default runs the bulk install and the UI groups its rows accordingly.

Two rules worth keeping: never let an unparsed result read as "up to date"
(return `.unknown` and say why), and report per-item failures in
`InstallOutcome.failedItems` so the failure memory stays accurate.

See [`SOURCES.md`](SOURCES.md) for details on the data sources.
