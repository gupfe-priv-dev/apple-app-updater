import Foundation

/// Homebrew formulae. scan: `brew outdated --formula`. install: `brew upgrade`.
struct BrewFormulaeTool: Tool {
    let id = "brew-formulae"
    let title = "Homebrew — formulae"
    func isAvailable() -> Bool { commandExists("brew") }

    func scan(_ ctx: RunContext) async -> ScanResult {
        await BrewTapTrust.ensure(ctx)
        // Refresh formulae metadata first so `outdated` is accurate. Silent.
        _ = await ctx.capture(["brew", "update"])
        // --verbose adds the version delta: "name (cur) < latest".
        let r = await ctx.capture(["brew", "outdated", "--formula", "--verbose"])
        let items = r.output.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line -> UpdateItem in
                let fields = line.split(separator: " ").map(String.init)
                let name = fields.first ?? line
                var cur: String?
                if fields.count >= 2, fields[1].hasPrefix("("), fields[1].hasSuffix(")") {
                    cur = String(fields[1].dropFirst().dropLast())
                }
                var latest: String?
                if let op = fields.firstIndex(where: { $0 == "<" || $0 == "!=" || $0 == ">" }),
                   op + 1 < fields.count {
                    latest = fields[op + 1]
                }
                return UpdateItem(name, current: cur, latest: latest)
            }
        // Hide Tier 3 / no-bottle formulae (e.g. xcodes) — they need an
        // explicit `--build-from-source`, not a routine upgrade. They'd
        // otherwise show as "outdated" forever, since brew upgrade silently
        // skips them.
        let noBottle = await tier3NoBottle(items.map { $0.name }, ctx: ctx)
        let visible = items.filter { !noBottle.contains($0.name) }
        return .from(visible)
    }

    var supportsTargetedInstall: Bool { true }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        await upgrade(ctx, names: [])
    }

    func install(_ ctx: RunContext, only items: [UpdateItem]) async -> InstallOutcome {
        await upgrade(ctx, names: items.map { $0.token })
    }

    /// `names` empty → upgrade every outdated formula; otherwise just those.
    private func upgrade(_ ctx: RunContext, names: [String]) async -> InstallOutcome {
        await BrewTapTrust.ensure(ctx)
        _ = await ctx.capture(["brew", "update"])
        // tee the upgrade output so we can detect post-upgrade link conflicts
        // (e.g. yt-dlp's /usr/local/bin/<name> already exists from another
        // package manager) and auto-repair them with `brew link --overwrite`.
        let log = NSTemporaryDirectory() + "ua-formulae-\(UUID().uuidString).log"
        let targets = names.map { "'\($0)'" }.joined(separator: " ")
        let cmd = "brew upgrade --formula \(targets) 2>&1 | tee '\(log)'"
        let status = await ctx.run(["/bin/sh", "-c", cmd],
                                   env: ["HOMEBREW_DOWNLOAD_CONCURRENCY": "1"])
        let logText = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: log)
        await handleLinkConflicts(in: logText, ctx)

        // brew exits 1 on non-fatal warnings (deprecations, PATH shadowing)
        // even when every package upgraded fine. Verify by re-querying:
        // if nothing's outdated anymore, the upgrade did its job.
        if status == 0 { return .ok }
        let after = await ctx.capture(["brew", "outdated", "--formula", "--quiet"])
        var stillOutdated: [String] = after.output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // On a targeted run, formulae we deliberately left alone are still
        // outdated by design — they're not failures of this run.
        if !names.isEmpty {
            let asked = Set(names)
            stillOutdated = stillOutdated.filter { asked.contains($0) }
        }
        if stillOutdated.isEmpty { return .ok }
        // Drop Tier 3 / no-bottle formulae from the failure list — those
        // require `--build-from-source` and are not an upgrade failure.
        let noBottle = await tier3NoBottle(stillOutdated, ctx: ctx)
        if !noBottle.isEmpty {
            ctx.line("⊘ Skipped (no bottle — needs --build-from-source): "
                     + noBottle.sorted().joined(separator: ", "))
        }
        let real = stillOutdated.filter { !noBottle.contains($0) }
        if real.isEmpty { return .ok }
        return .failed("brew upgrade exited \(status); still outdated: \(real.joined(separator: ", "))")
    }

    // MARK: ─ Tier 3 no-bottle detection ─────────────────────────────────────

    /// Return the subset of `names` whose formula has no bottle — those are
    /// build-from-source-only and can't be upgraded by a routine `brew upgrade`.
    private func tier3NoBottle(_ names: [String], ctx: RunContext) async -> Set<String> {
        guard !names.isEmpty else { return [] }
        let r = await ctx.capture(["brew", "info", "--formula", "--json=v2"] + names)
        guard let data = r.output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formulae = obj["formulae"] as? [[String: Any]] else { return [] }
        var noBottle = Set<String>()
        for f in formulae {
            guard let name = f["name"] as? String else { continue }
            let versions = (f["versions"] as? [String: Any]) ?? [:]
            if let b = versions["bottle"] as? Bool, b == false {
                noBottle.insert(name)
            }
        }
        return noBottle
    }

    // MARK: ─ link conflict recovery ─────────────────────────────────────────

    /// Parse the upgrade log for "The `brew link` step did not complete
    /// successfully" failures (e.g. a non-brew `/usr/local/bin/<name>` shadowing
    /// the link target) and re-run `brew link --overwrite` on each.
    private func handleLinkConflicts(in log: String, _ ctx: RunContext) async {
        var broken = Set<String>()
        var pending: String? = nil
        for raw in log.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("==> Upgrading ") {
                pending = String(line.dropFirst("==> Upgrading ".count))
                    .split(separator: " ").first.map(String.init)
            } else if line.hasPrefix("==> Pouring ") {
                let rest = String(line.dropFirst("==> Pouring ".count))
                if let dash = rest.range(of: "--") { pending = String(rest[..<dash.lowerBound]) }
            } else if line.contains("The `brew link` step did not complete successfully"),
                      let name = pending {
                broken.insert(name)
            }
        }
        guard !broken.isEmpty else { return }
        let names = broken.sorted()
        ctx.line("")
        ctx.line("↻ Re-linking after conflict: \(names.joined(separator: ", "))")
        for name in names {
            let s = await ctx.run(["brew", "link", "--overwrite", "--quiet", name])
            if s != 0 {
                ctx.line("   (couldn't auto-link \(name) — inspect manually)")
            }
        }
    }
}
