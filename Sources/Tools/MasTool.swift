import Foundation

/// Mac App Store via `mas`. scan: `mas outdated`. install: `mas upgrade`.
struct MasTool: Tool {
    let id = "mas"
    let title = "Mac App Store"
    func isAvailable() -> Bool { commandExists("mas") }

    func scan(_ ctx: RunContext) async -> ScanResult {
        let r = await ctx.capture(["mas", "outdated"])
        let items = r.output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line -> UpdateItem in
                // format: "<id> <App Name> (<old> -> <new>)"
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                let name = parts.count == 2 ? parts[1] : line
                return UpdateItem(name)
            }
        return .from(items)
    }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        let status = await ctx.run(["mas", "upgrade"])
        return status == 0 ? .ok : .failed("mas upgrade exited \(status)")
    }
}
