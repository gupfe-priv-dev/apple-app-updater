import Foundation

/// Homebrew formulae. scan: `brew outdated --formula`. install: `brew upgrade`.
struct BrewFormulaeTool: Tool {
    let id = "brew-formulae"
    let title = "Homebrew — formulae"
    func isAvailable() -> Bool { commandExists("brew") }

    func scan(_ ctx: RunContext) async -> ScanResult {
        // Refresh formulae metadata first so `outdated` is accurate. Silent.
        _ = await ctx.capture(["brew", "update"])
        let r = await ctx.capture(["brew", "outdated", "--formula", "--quiet"])
        let items = r.output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { UpdateItem($0) }
        return .from(items)
    }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        _ = await ctx.capture(["brew", "update"])
        let status = await ctx.run(["brew", "upgrade", "--formula", "--quiet"])
        return status == 0 ? .ok : .failed("brew upgrade exited \(status)")
    }
}
