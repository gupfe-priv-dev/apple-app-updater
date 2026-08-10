import Foundation

/// Global npm packages. scan: `npm outdated -g`. install: bump npm itself, then
/// `npm update -g` (or `npm install -g <pkg>@latest` for a targeted subset).
struct NpmTool: Tool {
    let id = "npm"
    let title = "npm"
    func isAvailable() -> Bool { commandExists("npm") }

    /// Parsed `npm outdated -g --parseable` rows.
    /// Format: path:name@wanted:name@current:name@latest:location
    private func outdated(_ ctx: RunContext) async -> [UpdateItem] {
        // `npm outdated -g` exits 1 when packages are outdated (CI behavior) —
        // we don't care about the status, just the parseable lines.
        let r = await ctx.capture(["npm", "outdated", "-g", "--parseable"])
        return r.output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { line -> UpdateItem? in
                // The leading path may itself contain ':' on odd setups, so
                // work from the end: the last five fields are the stable ones.
                let fields = line.split(separator: ":").map(String.init)
                guard fields.count >= 4 else { return nil }
                // fields[1] = wanted, [2] = current, [3] = latest — each
                // "<name>@<version>"; scoped packages start with '@' so split
                // on the LAST '@'.
                func split(_ spec: String) -> (name: String, version: String)? {
                    guard let at = spec.lastIndex(of: "@"), at != spec.startIndex else { return nil }
                    return (String(spec[spec.startIndex..<at]), String(spec[spec.index(after: at)...]))
                }
                guard let latest = split(fields[3]) else { return nil }
                let current = split(fields[2])?.version
                return UpdateItem(latest.name, current: current, latest: latest.version)
            }
    }

    func scan(_ ctx: RunContext) async -> ScanResult {
        .from(await outdated(ctx))
    }

    var supportsTargetedInstall: Bool { true }

    /// Bump npm itself first — a stale npm is the usual cause of a global
    /// install failing in a way that looks like the package's fault.
    private func bumpNpm(_ ctx: RunContext) async {
        let before = await ctx.capture(["npm", "--version"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = await ctx.capture(["npm", "install", "-g", "npm@latest"])
        let after = await ctx.capture(["npm", "--version"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        if before != after { ctx.line("npm: \(before) → \(after)") }
    }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        await bumpNpm(ctx)
        if (await outdated(ctx)).isEmpty {
            ctx.line("✓ All global packages up to date")
            return .ok
        }
        let status = await ctx.run(["npm", "update", "-g"])
        return status == 0 ? .ok : .failed("npm update exited \(status)")
    }

    func install(_ ctx: RunContext, only items: [UpdateItem]) async -> InstallOutcome {
        guard !items.isEmpty else { return .skipped("nothing selected") }
        await bumpNpm(ctx)
        // One command per package: npm aborts the whole batch on a single
        // failure, and we want the others to land regardless.
        var failed: [String] = []
        for item in items {
            ctx.line("")
            ctx.line("==> \(item.token)@latest")
            let status = await ctx.run(["npm", "install", "-g", "\(item.token)@latest"])
            if status != 0 { failed.append(item.token) }
        }
        if failed.count == items.count {
            return InstallOutcome(.failed, "npm install failed for: \(failed.joined(separator: ", "))",
                                  failedItems: failed)
        }
        return .partial(failed)
    }
}
