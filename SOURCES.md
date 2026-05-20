# Update Sources

Data sources used by `update-all.sh` to detect and install updates.

---

## Managed by package managers

### Homebrew — formulae & casks
- **List installed:** `brew list --cask`
- **App name mapping:** `brew info --cask --json=v2 <casks>`
- **Full cask catalog:** `https://formulae.brew.sh/api/cask.json`
  - Cached locally in `brew_cask_catalog.json` (refreshed every 24h)
  - Used for instant app-name → cask-token lookups without per-app API calls
  - Structure: array of cask objects with `token`, `artifacts[].app[]`, `version`, `bundle_short_version`

### Mac App Store — mas
- **List installed:** `mas list`
- **Upgrade all:** `mas upgrade`
- No external API needed — mas handles everything

### macOS System Updates
- **CLI:** `softwareupdate --install --all`

---

## Unmanaged apps (apps.json registry)

Apps in `/Applications` not covered by brew or mas are tracked in `apps.json`.
The registry is updated on every script run: new apps are detected and classified,
removed apps are pruned. Detection happens once per app and is cached.

**File:** `apps.json`
**Structure:**
```json
{
  "AppName.app": {
    "manager": "sparkle | electron | unmanaged",
    "feed_url": "https://...",
    "brew_cask_available": "cask-token",
    "last_version": "1.2.3"
  }
}
```

### Sparkle
Apps that embed a `SUFeedURL` in their `Info.plist` use the
[Sparkle framework](https://sparkle-project.org/) for updates.

- **Detection:** `PlistBuddy -c "Print SUFeedURL" Info.plist`
- **Feed format:** RSS/Atom XML (appcast), fetched directly from the app's declared URL
- **Namespaces used:**
  - `http://www.andymatuschak.org/xml-namespaces/sparkle` (common)
  - `https://www.andymatuschak.org/xml-namespaces/sparkle` (some older apps)
- **Version fields:** `sparkle:shortVersionString` or `sparkle:version`
  — may be child elements of `<item>` OR attributes on `<enclosure>`, depending on the app
- **Download URL:** `<enclosure url="...">` — supports `.dmg`, `.zip`, `.pkg`

### Electron
Apps containing `Contents/Frameworks/Electron Framework.framework` are Electron-based.
They self-update on launch via `https://update.electronjs.org/` or a custom endpoint.
No CLI update path — just listed as a reminder to launch them occasionally.

### GitHub Releases (future)
Many unmanaged apps (especially open-source) publish releases on GitHub.
Could be added by:
1. Reading `CFBundleURLTypes` or homepage URL from `Info.plist` to find the repo
2. Querying `https://api.github.com/repos/<owner>/<repo>/releases/latest`
3. Comparing `tag_name` against installed version

Updatest uses this via `https://api.github.com/repos/` with ETags cached in
`~/Library/Caches/Updatest/github_etag_cache.json` to stay within API rate limits.

---

## CLI tools

| Tool | Update command | Notes |
|------|---------------|-------|
| npm | `npm update -g && npm install -g npm@latest` | Updates global packages + npm itself |
| Ruby gems | `gem update --system && gem update` | `--system` updates RubyGems itself |
| Rust | `rustup update` | Updates all installed toolchains |
| pipx | `pipx upgrade-all` | Updates all pipx-installed tools |
| Claude Code | `claude update` | Anthropic CLI |

---

## Adding a new source

1. **New package manager** (e.g. `cargo install-update`):
   Add a section in phase 3 of `update-all.sh` following the `command -v` guard pattern.

2. **New app update mechanism** (e.g. GitHub Releases):
   - Add detection logic in the `for name in sorted(unmanaged - set(registry))` block in phase 1
   - Add a new `manager` type (e.g. `"github"`) with the relevant metadata (repo URL, etc.)
   - Add an update loop for that type alongside the Sparkle loop in phase 4

3. **Override a specific app's source:**
   Edit `apps.json` directly and set the `manager` and relevant fields.
   The registry sync will not overwrite existing entries for known apps.
