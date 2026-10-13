import Foundation

/// Rust toolchains via rustup. scan: `rustup check`. install: per toolchain
/// `rustup update <name>`, and `rustup self update` for rustup's own row.
struct RustupTool: Tool {
    let id = "rustup"
    let title = "Rust (rustup)"
    func isAvailable() -> Bool { commandExists("rustup") }

    /// `rustup check` prints one line per thing it manages:
    ///   stable-aarch64-apple-darwin - Update available : 1.79.0 (129f3b996 2024-06-10) -> 1.80.0 (051478957 2024-07-21)
    ///   rustup - Update available : 1.27.0 -> 1.27.1
    /// The part before " - " is what `rustup update` takes; "rustup" is rustup.
    func scan(_ ctx: RunContext) async -> ScanResult {
        let r = await ctx.capture(["rustup", "check"])
        let updates = r.output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("Update available") }
            .map { line -> UpdateItem in
                guard let dash = line.range(of: " - ") else { return UpdateItem(line) }
                let name = String(line[..<dash.lowerBound])
                var current: String?, latest: String?
                if let colon = line.range(of: ": ") {
                    let pair = line[colon.upperBound...].components(separatedBy: " -> ")
                    if pair.count == 2 {
                        current = pair[0].split(separator: " ").first.map(String.init)
                        latest = pair[1].split(separator: " ").first.map(String.init)
                    }
                }
                return UpdateItem(name, current: current, latest: latest)
            }
        return .from(updates)
    }

    var supportsTargetedInstall: Bool { true }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        _ = await ctx.capture(["rustup", "self", "update"])
        let status = await ctx.run(["rustup", "update"])
        return status == 0 ? .ok : .failed("rustup update exited \(status)")
    }

    func install(_ ctx: RunContext, only items: [UpdateItem]) async -> InstallOutcome {
        guard !items.isEmpty else { return .skipped("nothing selected") }
        var failed: [String] = []
        // rustup itself first, so the toolchains are updated by the new one.
        for item in items.sorted(by: { a, _ in a.token == "rustup" }) {
            ctx.line("")
            ctx.line("==> \(item.token)")
            ctx.itemStarted(item.token)
            let argv = item.token == "rustup"
                ? ["rustup", "self", "update"]
                : ["rustup", "update", "--no-self-update", item.token]
            let status = await ctx.run(argv)
            if status != 0 { failed.append(item.token) }
            ctx.itemFinished(item.token, ok: status == 0)
        }
        if failed.count == items.count {
            return InstallOutcome(.failed, "rustup update failed for: \(failed.joined(separator: ", "))",
                                  failedItems: failed)
        }
        return .partial(failed)
    }
}
