import Foundation
import AppKit

/// Homebrew casks — full path: drift recovery for interrupted installs, the
/// greedy upgrade (with download-spinner frames filtered out), stuck-cask
/// detection, quarantine stripping, and cleanup with stuck-keg recovery.
/// Native port of update-all.sh's cask section.
struct BrewCasksTool: Tool {
    let id = "brew-casks"
    let title = "Homebrew — casks"
    func isAvailable() -> Bool { commandExists("brew") }

    func scan(_ ctx: RunContext) async -> ScanResult {
        await BrewTapTrust.ensure(ctx)
        // --verbose adds the version delta: "token (cur) != latest".
        let r = await ctx.capture(["brew", "outdated", "--cask", "--greedy", "--verbose"])
        let parsed = r.output.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .compactMap(parseOutdatedLine)
        // Drop "installer manual" casks (e.g. battle-net): brew lists them as
        // outdated under --greedy but refuses to upgrade them, so they'd show
        // a perpetual "update available" that Apply Updates can never clear.
        let manual = await manualInstallerCasks(parsed.map { $0.token }, ctx)
        let items = parsed.filter { !manual.contains($0.token) }
            .map { UpdateItem($0.token, current: $0.cur, latest: $0.latest) }
        return .from(items)
    }

    /// Parse a `brew outdated --verbose` line: "token (cur) != latest".
    /// Cask versions can carry a ",<hash>" metadata suffix — trimmed for display.
    private func parseOutdatedLine(_ line: String) -> (token: String, cur: String?, latest: String?)? {
        let fields = line.split(separator: " ").map(String.init)
        guard let token = fields.first else { return nil }
        func display(_ v: String) -> String { String(v.split(separator: ",").first ?? Substring(v)) }
        var cur: String?
        if fields.count >= 2, fields[1].hasPrefix("("), fields[1].hasSuffix(")") {
            cur = display(String(fields[1].dropFirst().dropLast()))
        }
        var latest: String?
        if let op = fields.firstIndex(where: { $0 == "!=" || $0 == "<" || $0 == ">" }),
           op + 1 < fields.count {
            latest = display(fields[op + 1])
        }
        return (token, cur, latest)
    }

    /// Of the given cask tokens, which are `installer manual` (brew can't
    /// auto-upgrade them — they're user-driven installs)?
    private func manualInstallerCasks(_ tokens: [String], _ ctx: RunContext) async -> Set<String> {
        guard !tokens.isEmpty else { return [] }
        let r = await ctx.capture(["brew", "info", "--cask", "--json=v2"] + tokens)
        guard let data = r.output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = obj["casks"] as? [[String: Any]] else { return [] }
        var manual = Set<String>()
        for c in casks {
            guard let token = c["token"] as? String else { continue }
            for art in (c["artifacts"] as? [[String: Any]]) ?? [] {
                for inst in (art["installer"] as? [Any]) ?? [] {
                    if let d = inst as? [String: Any], d["manual"] != nil { manual.insert(token) }
                }
            }
        }
        return manual
    }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        await restoreDriftedCasks(ctx)
        // Quit apps that are about to be replaced while open (updating a running
        // app can leave it glitchy until restart). Relaunched after the upgrade.
        let relaunch = await quitRunningApps(ctx)

        // Which casks are actually outdated (greedy), minus manual-installer
        // casks brew won't auto-upgrade anyway.
        let outdated = await ctx.capture(["brew", "outdated", "--cask", "--greedy", "--quiet"])
        var tokens = outdated.output.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let manual = await manualInstallerCasks(tokens, ctx)
        tokens = tokens.filter { !manual.contains($0) }

        // Disabled casks are never "outdated", so we won't try to upgrade them —
        // but still offer to remove the dead ones. A --dry-run surfaces the
        // "disabled" warnings without downloading anything.
        let dry = await ctx.capture(["/bin/sh", "-c",
                                     "brew upgrade --cask --greedy --dry-run 2>&1"])
        await handleDisabledCasks(in: dry.output, ctx)

        if tokens.isEmpty {
            ctx.line("✓ All casks up to date")
            await stripQuarantine(ctx)
            await cleanup(ctx)
            await relaunchApps(relaunch, ctx)
            return .ok
        }

        // Upgrade each cask on its OWN command. brew's batch upgrade prefetches
        // every download first and aborts the whole run if any single one fails
        // (e.g. makemkv's host was unreachable) — so one bad cask took down all
        // the others. Per-cask isolates failures. Sequential downloads
        // (concurrency=1) keep a single \r-updated progress line. tee -a to one
        // log so the stuck-cask detector still sees everything.
        let log = NSTemporaryDirectory() + "ua-cask-\(UUID().uuidString).log"
        var failed: [String] = []
        for token in tokens {
            ctx.line("")
            ctx.line("==> Upgrading \(token)")
            let cmd = "brew upgrade --cask --greedy '\(token)' 2>&1 | tee -a '\(log)'"
            let status = await ctx.run(["/bin/sh", "-c", cmd],
                                       env: ["HOMEBREW_DOWNLOAD_CONCURRENCY": "1"])
            if status != 0 { failed.append(token) }
        }
        let logText = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: log)

        await handleStuckCasks(in: logText, ctx)
        await stripQuarantine(ctx)
        await cleanup(ctx)
        await relaunchApps(relaunch, ctx)

        if !failed.isEmpty {
            ctx.line("")
            ctx.line("⚠ \(failed.count) cask\(failed.count == 1 ? "" : "s") failed — the rest upgraded fine:")
            for t in failed { ctx.line("   • \(t)") }
            ctx.line("  Usually transient (network) or a deprecated cask; will retry next run.")
        }
        // Only a hard failure if EVERY cask failed; a partial failure still
        // applied the others, so don't flag the whole section red.
        if failed.count == tokens.count {
            return .failed("all \(tokens.count) cask upgrade(s) failed: \(failed.joined(separator: ", "))")
        }
        return .ok
    }

    // MARK: running apps ──────────────────────────────────────────────────

    /// Apps a pending cask upgrade would replace while they're open. Updating a
    /// running app — especially a Chromium browser, which loads resources lazily
    /// from its bundle — can break the live instance until it's relaunched. So
    /// we offer to quit them cleanly first; the returned names are relaunched
    /// once the upgrade finishes.
    private func quitRunningApps(_ ctx: RunContext) async -> [String] {
        let outdated = await ctx.capture(["brew", "outdated", "--cask", "--greedy", "--quiet"])
        var tokens = outdated.output.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // manual-installer casks (e.g. battle-net) won't actually be upgraded,
        // so don't bother asking the user to quit them.
        let manual = await manualInstallerCasks(tokens, ctx)
        tokens = tokens.filter { !manual.contains($0) }
        guard !tokens.isEmpty else { return [] }

        let appsByToken = await caskAppArtifacts(tokens, ctx)
        let running = runningAppBundleNames()
        var openApps = Set<String>()                          // "Brave Browser.app"
        for (_, apps) in appsByToken {
            for app in apps where running.contains(app) { openApps.insert(app) }
        }
        let display = openApps.map { $0.removingSuffix(".app") }.sorted()
        guard !display.isEmpty else { return [] }

        ctx.line("")
        ctx.line("⚠ These apps are open and about to be updated:")
        for d in display { ctx.line("   • \(d)") }
        ctx.line("  Updating an app while it's running can leave it glitchy until you")
        ctx.line("  restart it. Best to quit them first — they'll reopen after updating.")
        guard await ctx.ask("Quit \(display.count) running app(s) and relaunch after updating? "
                            + "(\(display.joined(separator: ", ")))") else {
            ctx.line("⊘ Left open — restart any that misbehave after the update.")
            return []
        }

        var quit: [String] = []
        for app in display {
            ctx.line("⏻ Quitting \(app)…")
            _ = await ctx.capture(["osascript", "-e", "tell application \"\(app)\" to quit"])
            if await waitForQuit(app) { quit.append(app) }
            else { ctx.line("   (\(app) didn't quit — updating in place; restart it if needed)") }
        }
        return quit
    }

    /// token → app-bundle names it installs, from the cask's `app` artifacts.
    private func caskAppArtifacts(_ tokens: [String], _ ctx: RunContext) async -> [String: [String]] {
        guard !tokens.isEmpty else { return [:] }
        let r = await ctx.capture(["brew", "info", "--cask", "--json=v2"] + tokens)
        guard let data = r.output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = obj["casks"] as? [[String: Any]] else { return [:] }
        var map: [String: [String]] = [:]
        for c in casks {
            guard let token = c["token"] as? String else { continue }
            var apps: [String] = []
            for art in (c["artifacts"] as? [[String: Any]]) ?? [] {
                // an "app" artifact is a list whose first element is the bundle
                // name (later elements may carry a {target:…} rename dict).
                for entry in (art["app"] as? [Any]) ?? [] {
                    if let name = entry as? String, name.hasSuffix(".app") { apps.append(name) }
                }
            }
            if !apps.isEmpty { map[token] = apps }
        }
        return map
    }

    /// Bundle names ("Brave Browser.app") of every currently-running app.
    private func runningAppBundleNames() -> Set<String> {
        var names = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            if let comp = app.bundleURL?.lastPathComponent { names.insert(comp) }
        }
        return names
    }

    /// Poll until the named app has terminated (or timeout). `name` is the
    /// display name without ".app".
    private func waitForQuit(_ name: String, timeout: Double = 6) async -> Bool {
        let bundle = name + ".app"
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if !runningAppBundleNames().contains(bundle) { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return !runningAppBundleNames().contains(bundle)
    }

    /// Reopen the apps we quit before upgrading.
    private func relaunchApps(_ names: [String], _ ctx: RunContext) async {
        guard !names.isEmpty else { return }
        ctx.line("")
        for name in names {
            ctx.line("↻ Relaunching \(name)…")
            _ = await ctx.capture(["open", "-a", name])
        }
    }

    // MARK: disabled casks ────────────────────────────────────────────────

    /// A cask brew has *disabled* (its upstream source is gone) can never be
    /// upgraded — brew just prints a "Deprecated or disabled package" warning
    /// on every run. The local app still works but is frozen; often a
    /// replacement now lives elsewhere (e.g. the Mac App Store). Detect these
    /// from the upgrade log and offer to remove the dead brew cask.
    private func handleDisabledCasks(in log: String, _ ctx: RunContext) async {
        var disabled = Set<String>()
        for raw in log.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // trailer rows: "send-to-kindle (disabled)"
            if line.hasSuffix("(disabled)") {
                let token = String(line.dropLast("(disabled)".count)).trimmingCharacters(in: .whitespaces)
                if !token.isEmpty && !token.contains(" ") { disabled.insert(token) }
            }
            // warning rows: "Warning: Not upgrading <token>, it is disabled because…"
            else if line.hasPrefix("Warning: Not upgrading "),
                    let cut = line.range(of: ", it is disabled") {
                let start = line.index(line.startIndex, offsetBy: "Warning: Not upgrading ".count)
                disabled.insert(String(line[start..<cut.lowerBound]))
            }
        }
        let tokens = disabled.sorted()
        guard !tokens.isEmpty else { return }
        ctx.line("")
        ctx.line("⚠ Disabled upstream — brew can't upgrade these (the source is gone):")
        for t in tokens { ctx.line("   • \(t)") }
        ctx.line("  The installed copy still works but is frozen. If a replacement exists")
        ctx.line("  elsewhere (e.g. the Mac App Store), you can drop the stale brew cask.")
        if await ctx.ask("Uninstall \(tokens.count) disabled cask(s)? (\(tokens.joined(separator: ", ")))") {
            for t in tokens {
                ctx.line("✗ brew uninstall --cask \(t)")
                _ = await ctx.run(["brew", "uninstall", "--cask", t])
            }
        } else {
            ctx.line("⊘ Kept — brew will keep showing the disabled warning until removed.")
        }
    }

    // MARK: drift recovery ────────────────────────────────────────────────

    /// A cask whose /Applications target(s) vanished (interrupted install /
    /// crash) leaves brew's metadata thinking it's installed but no real
    /// backup to restore. Offer to reinstall those whose apps are ALL missing;
    /// just inform about partials (user likely removed one app from a bundle).
    private func restoreDriftedCasks(_ ctx: RunContext) async {
        var byToken: [String: [String]] = [:]
        for (app, tok) in Registry.brewManagedApps() { byToken[tok, default: []].append(app) }
        guard !byToken.isEmpty else { return }

        var missingTotal: [(token: String, apps: [String])] = []
        var partial: [(token: String, missing: [String], present: [String])] = []
        for (token, apps) in byToken {
            var missing: [String] = [], present: [String] = []
            for app in apps {
                if FileManager.default.fileExists(atPath: "/Applications/\(app)/Contents/MacOS") { present.append(app) }
                else { missing.append(app) }
            }
            if !missing.isEmpty && present.isEmpty { missingTotal.append((token, apps.sorted())) }
            else if !missing.isEmpty { partial.append((token, missing.sorted(), present.sorted())) }
        }

        // Don't re-prompt for casks the user already declined to reinstall —
        // they removed the app on purpose. (If they later `brew uninstall` it,
        // it stops being brew-managed and drops out of this list anyway.)
        let declined = Registry.declinedReinstalls()
        missingTotal = missingTotal.filter { !declined.contains($0.token) }

        if !partial.isEmpty {
            ctx.line("ℹ Cask bundles with SOME apps removed (treating as deliberate, not reinstalling):")
            for p in partial {
                ctx.line("   • \(p.token)")
                ctx.line("     missing: \(p.missing.joined(separator: ", "))")
                ctx.line("     present: \(p.present.joined(separator: ", "))")
                ctx.line("     to drop brew's tracking:        brew uninstall --cask \(p.token)")
                ctx.line("     to bring all missing apps back: brew reinstall --cask --force \(p.token)")
            }
        }
        guard !missingTotal.isEmpty else { return }

        ctx.line("")
        ctx.line("⚠ Cask bundles with ALL apps missing from /Applications:")
        for m in missingTotal { ctx.line("   • \(m.token)  (\(m.apps.joined(separator: ",")))") }
        ctx.line("")
        ctx.line("  Likely an interrupted install. Reinstall re-fetches the bundle from upstream.")
        ctx.line("  If removal was deliberate: `brew uninstall --cask <token>`")
        let names = missingTotal.map { $0.token }.joined(separator: ", ")
        if await ctx.ask("Reinstall \(missingTotal.count) cask(s)? (\(names))") {
            for m in missingTotal {
                ctx.line("↻ brew reinstall --cask \(m.token)")
                _ = await ctx.run(["brew", "reinstall", "--cask", "--force", "--quiet", m.token])
            }
        } else {
            // Remember the decline so these aren't re-offered every run.
            Registry.addDeclinedReinstalls(missingTotal.map { $0.token })
            ctx.line("⊘ Skipped — won't ask again (manage via Declined casks). "
                     + "brew metadata still references the missing bundle(s).")
        }
    }

    // MARK: stuck casks ───────────────────────────────────────────────────

    private func handleStuckCasks(in log: String, _ ctx: RunContext) async {
        var stuck: [String] = []
        for line in log.split(separator: "\n") {
            // "Error: <token>: It seems there is already an App at ..." or
            // "Error: <token>: It seems the App source ... is not there"
            guard line.hasPrefix("Error: "),
                  let range = line.range(of: ": It seems "),
                  line[range.upperBound...].hasPrefix("there is already an App")
                    || line[range.upperBound...].hasPrefix("the App source") else { continue }
            let token = String(line[line.index(line.startIndex, offsetBy: 7)..<range.lowerBound])
            stuck.append(token)
        }
        guard !stuck.isEmpty else { return }
        ctx.line("")
        ctx.line("⚠ Stale install detected: \(stuck.joined(separator: " "))")
        if await ctx.ask("Reinstall now? (\(stuck.joined(separator: ", ")))") {
            for cask in stuck { _ = await ctx.run(["brew", "reinstall", "--cask", cask]) }
        }
    }

    // MARK: quarantine + cleanup ──────────────────────────────────────────

    private func stripQuarantine(_ ctx: RunContext) async {
        _ = await ctx.capture(["/bin/sh", "-c",
            "find /Applications -maxdepth 2 -name '*.app' -print0 2>/dev/null | " +
            "xargs -0 -P 8 -I{} sh -c 'xattr -p com.apple.quarantine \"$1\" >/dev/null 2>&1 && " +
            "xattr -dr com.apple.quarantine \"$1\" 2>/dev/null; true' _ {}"])
    }

    private func cleanup(_ ctx: RunContext) async {
        let r = await ctx.capture(["brew", "cleanup"])
        // detect "Could not cleanup old kegs! Fix your permissions on:" + paths
        var stuckKegs: [String] = []
        var capturing = false
        for raw in r.output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line == "Error: Could not cleanup old kegs! Fix your permissions on:" { capturing = true; continue }
            if capturing {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("/") { stuckKegs.append(t) } else { capturing = false }
            }
        }
        guard !stuckKegs.isEmpty else { return }
        ctx.line("")
        ctx.line("⚠ Cleanup blocked by permission errors:")
        for k in stuckKegs { ctx.line("  \(k)") }
        if await ctx.ask("Remove these with sudo?") {
            for k in stuckKegs { _ = await ctx.run(["sudo", "rm", "-rf", k]) }
            _ = await ctx.capture(["brew", "cleanup"])
        }
    }
}
