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
        let r = await ctx.capture(["brew", "outdated", "--cask", "--greedy", "--quiet"])
        let items = r.output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { UpdateItem($0) }
        return .from(items)
    }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        await restoreDriftedCasks(ctx)

        // Upgrade, filtering brew's download-progress frame lines (they'd pile
        // up after ANSI stripping) and tee'ing to a log we parse for "stuck"
        // cask errors afterward.
        let log = NSTemporaryDirectory() + "ua-cask-\(UUID().uuidString).log"
        let filter = "grep --line-buffered -vE 'Cask [a-zA-Z0-9_-]+ \\([0-9][0-9.]*\\)[[:space:]]+(Downloading|Downloaded|Verifying|Verified)'"
        let cmd = "brew upgrade --cask --greedy --quiet 2>&1 | \(filter) | tee '\(log)'"
        let status = await ctx.run(["/bin/sh", "-c", cmd])

        let logText = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: log)
        if logText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ctx.line("✓ All casks up to date")
        }
        await handleStuckCasks(in: logText, ctx)
        await stripQuarantine(ctx)
        await cleanup(ctx)
        return status == 0 ? .ok : .failed("brew upgrade --cask exited \(status)")
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
