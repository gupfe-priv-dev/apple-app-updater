import Foundation

/// Homebrew formulae. scan: `brew outdated --formula`. install: `brew upgrade`.
struct BrewFormulaeTool: Tool {
    let id = "brew-formulae"
    let title = "Homebrew — formulae"
    func isAvailable() -> Bool { commandExists("brew") }

    func scan(_ ctx: RunContext) async -> ScanResult {
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
        return .from(items)
    }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        _ = await ctx.capture(["brew", "update"])
        // Drop --quiet + force sequential downloads so each bottle shows a
        // single live \r-updated progress line (same as the cask section).
        let status = await ctx.run(["brew", "upgrade", "--formula"],
                                   env: ["HOMEBREW_DOWNLOAD_CONCURRENCY": "1"])
        // brew exits 1 on non-fatal warnings (deprecations, PATH shadowing)
        // even when every package upgraded fine. Verify by re-querying:
        // if nothing's outdated anymore, the upgrade did its job.
        if status == 0 { return .ok }
        let after = await ctx.capture(["brew", "outdated", "--formula", "--quiet"])
        let stillOutdated = after.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if stillOutdated.isEmpty { return .ok }
        return .failed("brew upgrade exited \(status); still outdated: \(stillOutdated.joined(separator: ", "))")
    }
}
