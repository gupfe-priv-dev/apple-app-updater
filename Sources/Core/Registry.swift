import Foundation

/// One tracked unmanaged app in apps.json. Property names match the JSON keys
/// (snake_case) so Codable round-trips without custom keys; nil optionals are
/// omitted on encode (synthesized encodeIfPresent).
struct RegistryEntry: Codable {
    var manager: String                 // "sparkle" | "electron" | "unmanaged"
    var feed_url: String?               // sparkle appcast URL
    var brew_cask_available: String?    // matching cask token, if any
    var last_version: String?           // last version we installed via Sparkle
}

/// apps.json maintenance + brew-cask suggestion engine. Native port of
/// registry.py. All methods are synchronous (Process-blocking) and meant to be
/// called from a tool's off-main async context.
enum Registry {
    static func load() -> [String: RegistryEntry] {
        guard let data = FileManager.default.contents(atPath: AppPaths.registry) else { return [:] }
        return (try? JSONDecoder().decode([String: RegistryEntry].self, from: data)) ?? [:]
    }

    static func save(_ r: [String: RegistryEntry]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(r) {
            try? data.write(to: URL(fileURLWithPath: AppPaths.registry))
        }
    }

    static func declinedCasks() -> Set<String> {
        guard let data = FileManager.default.contents(atPath: AppPaths.state + "/declined-casks.json"),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return Set(arr)
    }

    // Drift-reinstall declines: cask tokens whose apps are missing but the user
    // chose NOT to reinstall (deliberate removal). Persisted so we don't nag on
    // every run. Kept separate from declinedCasks (which suppresses cask
    // *suggestions* for unmanaged apps).
    private static var declinedReinstallsPath: String { AppPaths.state + "/declined-reinstalls.json" }

    static func declinedReinstalls() -> Set<String> {
        guard let data = FileManager.default.contents(atPath: declinedReinstallsPath),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return Set(arr)
    }

    /// Remember that the user declined reinstalling these drifted casks.
    static func addDeclinedReinstalls(_ tokens: [String]) {
        var set = declinedReinstalls()
        set.formUnion(tokens)
        if let data = try? JSONSerialization.data(withJSONObject: set.sorted(), options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: declinedReinstallsPath))
        }
    }

    /// /Applications/*.app names → cask token, for every installed cask
    /// (reading both `app:` artifacts and uninstall.delete paths).
    /// pkg receipt id → cask token, for casks that install a package rather
    /// than an app bundle. Populated by `brewManagedApps()`.
    static var brewOwnedPkgIDs: [String: String] = [:]
    /// app bundle id → cask token, harvested from casks' `uninstall: quit:`.
    static var brewOwnedBundleIDs: [String: String] = [:]

    /// /Applications app name → cask token, for everything Homebrew installed.
    ///
    /// Read from the Caskroom on disk rather than by asking `brew info`, which
    /// spawns Ruby and resolves every cask. brew already recorded all of this
    /// when it installed:
    ///
    ///   - an app cask stages a symlink pointing at /Applications/Foo.app, so
    ///     the mapping is a readlink;
    ///   - a pkg cask stages the .pkg instead and has no app to link, but its
    ///     saved cask JSON names the receipt it leaves (`uninstall: pkgutil:`)
    ///     and the bundle ids it has to stop (`uninstall: quit:`) — which is
    ///     where Homebrew's bundle identifiers actually live.
    static func brewManagedApps() -> [String: String] {
        let prefix = Shell.capture(["brew", "--prefix"]).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let caskroom = (prefix.isEmpty ? "/opt/homebrew" : prefix) + "/Caskroom"
        let fm = FileManager.default
        guard let tokens = try? fm.contentsOfDirectory(atPath: caskroom) else { return [:] }

        var result: [String: String] = [:]
        var linked = Set<String>()
        brewOwnedPkgIDs = [:]
        brewOwnedBundleIDs = [:]

        for token in tokens where !token.hasPrefix(".") {
            let tokenDir = "\(caskroom)/\(token)"
            for version in (try? fm.contentsOfDirectory(atPath: tokenDir)) ?? [] {
                let versionDir = "\(tokenDir)/\(version)"
                if version == ".metadata" { continue }
                for entry in (try? fm.contentsOfDirectory(atPath: versionDir)) ?? []
                where entry.hasSuffix(".app") {
                    let staged = "\(versionDir)/\(entry)"
                    let target = (try? fm.destinationOfSymbolicLink(atPath: staged)) ?? staged
                    if target.hasPrefix("/Applications/") {
                        result[(target as NSString).lastPathComponent] = token
                    } else {
                        result[entry] = token          // copied, not linked
                    }
                    linked.insert(token)
                }
            }
        }

        // Casks that stage a .pkg have no app to link, and their saved cask
        // JSON is not dependable — powershell's records the receipt it leaves,
        // zoom's is empty. Ask brew about just those, which is a far shorter
        // list than every installed cask.
        let unlinked = tokens.filter { !$0.hasPrefix(".") && !linked.contains($0) }
        if !unlinked.isEmpty {
            let r = Shell.capture(["brew", "info", "--cask", "--json=v2"] + unlinked.sorted())
            if let data = r.out.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = obj["casks"] as? [[String: Any]] {
                for c in arr {
                    guard let token = c["token"] as? String else { continue }
                    for art in (c["artifacts"] as? [[String: Any]]) ?? [] {
                        for n in (art["app"] as? [Any]) ?? [] {
                            if let s = n as? String { result[s] = token }
                        }
                        for u in (art["uninstall"] as? [[String: Any]]) ?? [] {
                            if let one = u["pkgutil"] as? String { brewOwnedPkgIDs[one] = token }
                            for id in (u["pkgutil"] as? [Any]) ?? [] {
                                if let s = id as? String { brewOwnedPkgIDs[s] = token }
                            }
                            if let one = u["quit"] as? String, !one.contains("*") {
                                brewOwnedBundleIDs[one] = token
                            }
                            for id in (u["quit"] as? [Any]) ?? [] {
                                if let s = id as? String, !s.contains("*") { brewOwnedBundleIDs[s] = token }
                            }
                            for d in (u["delete"] as? [Any]) ?? [] {
                                if let path = d as? String, path.hasPrefix("/Applications/"),
                                   path.hasSuffix(".app"), !path.contains("*") {
                                    result[(path as NSString).lastPathComponent] = token
                                }
                            }
                        }
                    }
                }
            }
        }
        return result
    }

    /// Saved cask definitions under a token's .metadata directory.
    private static func caskJSONs(in metadataDir: String) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for version in (try? fm.contentsOfDirectory(atPath: metadataDir)) ?? [] {
            for stamp in (try? fm.contentsOfDirectory(atPath: "\(metadataDir)/\(version)")) ?? [] {
                let casks = "\(metadataDir)/\(version)/\(stamp)/Casks"
                for f in (try? fm.contentsOfDirectory(atPath: casks)) ?? [] where f.hasSuffix(".json") {
                    out.append("\(casks)/\(f)")
                }
            }
        }
        return out
    }

    /// Pull the receipt ids and bundle ids a cask says it owns.
    private static func harvest(_ path: String, token: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let artifacts = obj["artifacts"] as? [[String: Any]] else { return }
        for art in artifacts {
            for u in (art["uninstall"] as? [[String: Any]]) ?? [] {
                if let one = u["pkgutil"] as? String { brewOwnedPkgIDs[one] = token }
                for id in (u["pkgutil"] as? [Any]) ?? [] {
                    if let s = id as? String { brewOwnedPkgIDs[s] = token }
                }
                if let one = u["quit"] as? String, !one.contains("*") { brewOwnedBundleIDs[one] = token }
                for id in (u["quit"] as? [Any]) ?? [] {
                    if let s = id as? String, !s.contains("*") { brewOwnedBundleIDs[s] = token }
                }
            }
        }
    }


    /// "App Name.app" → MAS id, for every Mac App Store app.
    static func masManagedApps() -> [String: String] {
        let out = Shell.capture(["mas", "list"]).out
        var result: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let firstSpace = trimmed.firstIndex(of: " ") else { continue }
            let rest = trimmed[trimmed.index(after: firstSpace)...].trimmingCharacters(in: .whitespaces)
            // strip trailing " (version)"
            let name: String
            if let paren = rest.range(of: "(", options: .backwards) {
                name = String(rest[..<paren.lowerBound]).trimmingCharacters(in: .whitespaces)
            } else {
                name = rest
            }
            if !name.isEmpty { result["\(name).app"] = String(trimmed[..<firstSpace]) }
        }
        return result
    }

    /// Full registry sync + categorization. Emits the same human output the old
    /// registry.py printed, updates apps.json, and returns the deduped list of
    /// "safe" (same-or-newer) cask tokens to offer for install.
    @discardableResult
    static func sync(catalog: CaskCatalog, emit: (String) -> Void) -> [String] {
        let appsDir = "/Applications"
        let fm = FileManager.default
        let declined = declinedCasks()

        func plist(_ app: String) -> String { "\(appsDir)/\(app)/Contents/Info.plist" }
        func installedVer(_ app: String) -> String { Plist.value(plist(app), "CFBundleShortVersionString") ?? "" }

        let brewManaged = brewManagedApps()
        let masManaged  = masManagedApps()
        let installed = Set((try? fm.contentsOfDirectory(atPath: appsDir))?.filter { $0.hasSuffix(".app") } ?? [])

        // App Store apps are detected by the receipt every MAS download carries
        // (Contents/_MASReceipt/receipt) — NOT by name. `mas list` reports the
        // store's display name (e.g. "Kindle"), which often differs from the
        // bundle on disk (e.g. "Amazon Kindle.app"); name-matching alone would
        // then mis-file such apps as "unmanaged". The receipt is authoritative.
        let appStore = installed.filter {
            // A Mac App Store download carries this receipt...
            fm.fileExists(atPath: "\(appsDir)/\($0)/Contents/_MASReceipt/receipt")
            // ...and an iPhone/iPad app running on Apple Silicon carries none:
            // it is a wrapper around the iOS bundle, with the store's metadata
            // beside it. `mas` doesn't list these either, so without this they
            // look like unmanaged apps nobody is updating — when in fact the
            // App Store updates them and we have nothing to offer.
            || fm.fileExists(atPath: "\(appsDir)/\($0)/Wrapper/iTunesMetadata.plist")
        }
        var managed = Set(brewManaged.keys).union(masManaged.keys).union(appStore)
        // brewManaged only knows apps a cask installs as an .app artifact. A
        // pkg-based cask is found through the receipt it declares instead.
        // Asked only of what is still unaccounted for — pkgutil is a process
        // spawn each time.
        for name in installed.subtracting(managed) {
            if let id = Plist.value("\(appsDir)/\(name)/Contents/Info.plist", "CFBundleIdentifier"),
               Self.brewOwnedBundleIDs[id] != nil {
                managed.insert(name); continue
            }
            if let receipt = Self.packageReceipt(name), Self.brewOwnedPkgIDs[receipt] != nil {
                managed.insert(name)
            }
        }
        let unmanaged = installed.subtracting(managed)

        emit("  \(installed.count) apps in /Applications\n")
        emit("  brew: \(brewManaged.count)  mas: \(appStore.count)  unmanaged: \(unmanaged.count)\n")

        var registry = load()
        var changed = false

        // prune entries now managed or removed
        for name in registry.keys where managed.contains(name) || !installed.contains(name) {
            emit("  - \(name) (now managed or removed)\n")
            registry[name] = nil; changed = true
        }

        // classify newly-seen unmanaged apps
        for name in unmanaged.subtracting(registry.keys).sorted() {
            let p = plist(name)
            let hasPlist = fm.fileExists(atPath: p)
            var entry: RegistryEntry
            if hasPlist, let feed = Plist.value(p, "SUFeedURL") {
                entry = RegistryEntry(manager: "sparkle", feed_url: feed)
            } else if fm.fileExists(atPath: "\(appsDir)/\(name)/Contents/Frameworks/Electron Framework.framework") {
                entry = RegistryEntry(manager: "electron")
            } else if Plist.value(p, "CFBundleIdentifier") == Bundle.main.bundleIdentifier {
                // Ourselves. Settings → Maintenance checks GitHub Releases and
                // can install it; listing it as unattended would be silly.
                entry = RegistryEntry(manager: "self")
            } else if (Plist.value(p, "CFBundleIdentifier") ?? "").hasPrefix("com.apple.") {
                // Shipped with macOS. Software Update owns it; it is not an
                // unmanaged app anyone needs to act on.
                entry = RegistryEntry(manager: "system")
            } else if Self.packageReceipt(name) != nil {
                entry = RegistryEntry(manager: "installer")
            } else {
                entry = RegistryEntry(manager: "unmanaged")
            }
            // Only apps nothing else looks after get a cask suggestion. Adopting
            // one that a vendor installer or the App Store owns replaces a copy
            // something else is updating — Microsoft Office is the same bundle
            // whether it came from the Store, Microsoft's own installer, or a
            // cask, and only the last of those may be handed to brew.
            let eligible = entry.manager == "unmanaged"
            let cask = eligible ? catalog.find(name, installedVersion: hasPlist ? installedVer(name) : nil) : nil
            if let cask = cask { entry.brew_cask_available = cask.token }
            emit("  + \(name)  [\(entry.manager)]\(cask.map { "  → brew cask: \($0.token)" } ?? "")\n")
            registry[name] = entry; changed = true
        }

        if changed { save(registry); emit("  Saved → \(AppPaths.registry)\n") }
        else { emit("  Up to date\n") }

        let mgrCount = { (m: String) in registry.values.filter { $0.manager == m }.count }
        emit("  sparkle: \(mgrCount("sparkle"))  electron: \(mgrCount("electron"))  unmanaged: \(mgrCount("unmanaged"))\n")

        func grouped(_ pred: (RegistryEntry) -> Bool) -> [String] {
            registry.filter { pred($0.value) }.keys.map { $0.removingSuffix(".app") }.sorted()
        }
        let sparkle  = grouped { $0.manager == "sparkle" }
        let electron = grouped { $0.manager == "electron" }
        let installer = grouped { $0.manager == "installer" }
        let system    = grouped { $0.manager == "system" }
        let selfMgd   = grouped { $0.manager == "self" }
        let brewable = grouped { $0.brew_cask_available != nil }
        let orphan   = grouped { $0.manager == "unmanaged" && $0.brew_cask_available == nil }
        func list(_ title: String, _ names: [String]) {
            guard !names.isEmpty else { return }
            emit("\n  \(title)\n"); for n in names { emit("    • \(n)\n") }
        }
        list("Sparkle (self-update on launch):", sparkle)
        list("Electron (self-update on launch):", electron)
        list("Installed by a package — its own installer updates it:", installer)
        list("Shipped with macOS (Software Update owns it):", system)
        list("UpdateAll itself (Settings → Maintenance):", selfMgd)
        list("Brew cask available (offered below):", brewable)
        list("Unmanaged — no auto-update detected (check manually):", orphan)

        // categorize cask matches by version comparison
        typealias Row = (name: String, token: String, brewVer: String, instVer: String)
        var safe: [Row] = [], downgrade: [Row] = [], mismatch: [Row] = [], unknown: [Row] = []
        for (name, var entry) in registry {
            let iv = installedVer(name)
            let cask = catalog.find(name, installedVersion: iv)
            let newToken = cask?.token
            if newToken != entry.brew_cask_available {
                if let t = newToken {
                    let verb = entry.brew_cask_available == nil ? "added" : "updated"
                    entry.brew_cask_available = t; registry[name] = entry; changed = true
                    emit("  ⟳ cask mapping \(verb): \(name.removingSuffix(".app")) → \(t)\n")
                } else if let old = entry.brew_cask_available {
                    entry.brew_cask_available = nil; registry[name] = entry; changed = true
                    emit("  ⟳ cask mapping removed: \(name.removingSuffix(".app")) (was \(old))\n")
                }
            }
            guard let token = newToken else { continue }
            if declined.contains(token) { continue }
            let bv = cask?.version ?? ""
            if bv.isEmpty || iv.isEmpty { unknown.append((name, token, bv, iv)); continue }
            switch Version.compare(bv, iv) {
            case .none:           mismatch.append((name, token, bv, iv))
            case .some(let c) where c >= 0: safe.append((name, token, bv, iv))
            default:              downgrade.append((name, token, bv, iv))
            }
        }

        if !safe.isEmpty {
            emit("\n  💡 Brew cask available (safe — same or newer):\n")
            var byToken: [String: [Row]] = [:]
            for r in safe.sorted(by: { $0.name < $1.name }) { byToken[r.token, default: []].append(r) }
            for t in byToken.keys.sorted() {
                let items = byToken[t]!
                if items.count == 1 {
                    let r = items[0]
                    let tag = r.brewVer == r.instVer ? r.instVer : "\(r.instVer) → \(r.brewVer)"
                    emit("     \(r.name.removingSuffix(".app"))  (\(tag))  →  brew install --cask --force \(t)\n")
                } else {
                    emit("     \(t)  (bundle — covers \(items.count) apps)  →  brew install --cask --force \(t)\n")
                    for r in items {
                        let tag = r.brewVer == r.instVer ? r.instVer : "\(r.instVer) → \(r.brewVer)"
                        emit("        • \(r.name.removingSuffix(".app"))  (\(tag))\n")
                    }
                }
            }
        }
        if !downgrade.isEmpty {
            emit("\n  ⚠  Brew has older version (would downgrade — skipped):\n")
            for r in downgrade.sorted(by: { $0.name < $1.name }) {
                emit("     \(r.name.removingSuffix(".app")): installed \(r.instVer), brew \(r.brewVer)\n")
            }
        }
        if !mismatch.isEmpty {
            emit("\n  ≠  Version schemes differ — different cask variant or product? (skipped):\n")
            for r in mismatch.sorted(by: { $0.name < $1.name }) {
                emit("     \(r.name.removingSuffix(".app")): installed \(r.instVer), brew \"\(r.token)\" reports \(r.brewVer)\n")
            }
        }
        if !unknown.isEmpty {
            emit("\n  ?  Brew cask available (version unknown):\n")
            for r in unknown.sorted(by: { $0.name < $1.name }) {
                emit("     \(r.name.removingSuffix(".app"))  →  brew install --cask --force \(r.token)\n")
            }
        }
        if safe.isEmpty && downgrade.isEmpty && mismatch.isEmpty && unknown.isEmpty {
            emit("\n  ✓ No unmanaged apps have a matching brew cask — nothing to suggest\n")
        }

        if changed { save(registry) }

        // deduped safe tokens, order preserved
        var seen = Set<String>(), tokens: [String] = []
        for r in safe where !seen.contains(r.token) { seen.insert(r.token); tokens.append(r.token) }
        return tokens
    }

    /// Append declined cask tokens so they aren't re-offered.
    static func addDeclines(_ tokens: [String]) {
        var set = declinedCasks()
        set.formUnion(tokens)
        setDeclines(set)
    }

    /// Overwrite the entire declined-casks file. Use this from the management
    /// UI when the user removes one or more entries to re-allow them.
    static func setDeclines(_ set: Set<String>) {
        let path = AppPaths.state + "/declined-casks.json"
        if set.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        if let data = try? JSONSerialization.data(withJSONObject: set.sorted(), options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Did an installer package put this app here?
    ///
    /// `pkgutil` knows which receipt owns a path, and a vendor installer (Office
    /// via Microsoft AutoUpdate, say) leaves one. Such an app is already looked
    /// after, and replacing it with a cask would fight whatever installed it.
    ///
    /// Spawning pkgutil per app is not free, so this is only asked where the
    /// answer changes the outcome — an app that is neither brew's, the App
    /// Store's, Sparkle's nor Electron's.
    static func packageReceipt(_ appName: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        task.arguments = ["--file-info", "/Applications/\(appName)"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.split(separator: "\n") where line.hasPrefix("pkgid:") {
            return line.dropFirst("pkgid:".count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
