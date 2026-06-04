import Foundation

/// Mac App Store via `mas`. scan: `mas outdated`. install: `mas upgrade`.
struct MasTool: Tool {
    let id = "mas"
    let title = "Mac App Store"
    func isAvailable() -> Bool { commandExists("mas") }

    // mas otherwise spams stderr with "Found a likely App Store app not indexed
    // in Spotlight…" warnings; this env disables that auto-indexing chatter.
    private let env = ["MAS_NO_AUTO_INDEX": "1"]

    func scan(_ ctx: RunContext) async -> ScanResult {
        let r = await ctx.capture(["mas", "outdated"], env: env)
        let items = r.output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // a real outdated line starts with the numeric App Store id; the
            // Spotlight-index warnings don't, so this drops them.
            .filter { line in
                guard let first = line.split(separator: " ").first else { return false }
                return !first.isEmpty && first.allSatisfy { $0.isNumber }
            }
            .map { line -> UpdateItem in
                // format: "<id> <App Name> (<old> -> <new>)"
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                return UpdateItem(parts.count == 2 ? parts[1] : line)
            }
        return .from(items)
    }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        let status = await ctx.run(["mas", "upgrade"], env: env)
        return status == 0 ? .ok : .failed("mas upgrade exited \(status)")
    }
}
