import Foundation

/// Global npm packages. scan: `npm outdated -g`. install: bump npm itself, then
/// `npm update -g` if anything is outdated.
struct NpmTool: Tool {
    let id = "npm"
    let title = "npm"
    func isAvailable() -> Bool { commandExists("npm") }

    private func outdatedNames(_ ctx: RunContext) async -> [String] {
        // `npm outdated -g` exits 1 when packages are outdated (CI behavior) —
        // we don't care about the status, just the parseable lines.
        let r = await ctx.capture(["npm", "outdated", "-g", "--parseable"])
        return r.output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            // format: path:current:wanted:latest:location → name is last field
            .map { String($0.split(separator: ":").last ?? "") }
            .filter { !$0.isEmpty }
    }

    func scan(_ ctx: RunContext) async -> ScanResult {
        .from(await outdatedNames(ctx).map { UpdateItem($0) })
    }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        let before = await ctx.capture(["npm", "--version"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = await ctx.capture(["npm", "install", "-g", "npm@latest"])
        let after = await ctx.capture(["npm", "--version"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        if before != after { ctx.line("npm: \(before) → \(after)") }
        if (await outdatedNames(ctx)).isEmpty {
            ctx.line("✓ All global packages up to date")
            return .ok
        }
        let status = await ctx.run(["npm", "update", "-g"])
        return status == 0 ? .ok : .failed("npm update exited \(status)")
    }
}
