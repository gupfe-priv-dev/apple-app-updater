import Foundation

/// Homebrew casks — full path: drift recovery for interrupted installs, the
/// greedy upgrade (with download-spinner frames filtered out), stuck-cask
/// detection, quarantine stripping, and cleanup with stuck-keg recovery.
/// Native port of update-all.sh's cask section.
struct BrewCasksTool: Tool {
    let id = "brew-casks"
    let title = "Homebrew — casks"
    func isAvailable() -> Bool { commandExists("brew") }

    func scan(_ ctx: RunContext) async -> ScanResult {
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

        // Upgrade with live download progress. We force SEQUENTIAL downloads
        // (concurrency=1) so brew renders a single \r-updated progress line
        // (which the console handles in place) instead of the concurrent
        // multi-bar UI that used ANSI cursor moves and piled up after stripping.
        // tee to a log we parse for "stuck" cask errors afterward.
        let log = NSTemporaryDirectory() + "ua-cask-\(UUID().uuidString).log"
        let cmd = "brew upgrade --cask --greedy 2>&1 | tee '\(log)'"
        let status = await ctx.run(["/bin/sh", "-c", cmd],
                                   env: ["HOMEBREW_DOWNLOAD_CONCURRENCY": "1"])

        let logText = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: log)
        if logText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ctx.line("✓ All casks up to date")
        }
        await handleStuckCasks(in: logText, ctx)
        await handleDisabledCasks(in: logText, ctx)
        await stripQuarantine(ctx)
        await cleanup(ctx)
        return status == 0 ? .ok : .failed("brew upgrade --cask exited \(status)")
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
            ctx.line("⊘ Skipped — brew metadata still references the missing bundle(s).")
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
