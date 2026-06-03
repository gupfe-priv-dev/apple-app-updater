import Foundation

/// Rust toolchains via rustup. scan: `rustup check`. install: self update + update.
struct RustupTool: Tool {
    let id = "rustup"
    let title = "Rust (rustup)"
    func isAvailable() -> Bool { commandExists("rustup") }

    func scan(_ ctx: RunContext) async -> ScanResult {
        let r = await ctx.capture(["rustup", "check"])
        let updates = r.output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("Update available") }
            .map { UpdateItem($0) }
        return .from(updates)
    }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        _ = await ctx.capture(["rustup", "self", "update"])
        let status = await ctx.run(["rustup", "update"])
        return status == 0 ? .ok : .failed("rustup update exited \(status)")
    }
}
