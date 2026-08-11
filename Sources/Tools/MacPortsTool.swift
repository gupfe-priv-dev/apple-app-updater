import Foundation

/// MacPorts. scan: `port outdated`. install: `sudo port selfupdate` then
/// `sudo port upgrade outdated` (sudo covered by the NOPASSWD sudoers rule).
struct MacPortsTool: Tool {
    let id = "macports"
    let title = "MacPorts"
    func isAvailable() -> Bool { commandExists("port") }

    /// `port outdated` prints "name  current < latest" (with optional build-rev
    /// suffixes). Split it so the table gets a name and a version delta.
    private func parse(_ line: String) -> UpdateItem {
        let fields = line.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard let name = fields.first else { return UpdateItem(line) }
        guard let op = fields.firstIndex(where: { $0 == "<" || $0 == ">" || $0 == "!=" }),
              op > 1, op + 1 < fields.count else {
            return UpdateItem(name)
        }
        return UpdateItem(name, current: fields[1], latest: fields[op + 1])
    }

    func scan(_ ctx: RunContext) async -> ScanResult {
        let r = await ctx.capture(["port", "outdated"])
        let items = r.output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("No installed ports are outdated")
                      && !$0.hasPrefix("The following installed ports are outdated") }
            .map(parse)
        return .from(items)
    }

    var supportsTargetedInstall: Bool { true }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        _ = await ctx.capture(["sudo", "port", "selfupdate"])
        let r = await ctx.capture(["sudo", "port", "upgrade", "outdated"])
        if r.output.contains("Nothing to upgrade") {
            ctx.line("✓ All ports up to date")
        } else {
            for l in r.output.split(separator: "\n") { ctx.emit(l + "\n") }
        }
        return r.status == 0 ? .ok : .failed("port upgrade exited \(r.status)")
    }

    func install(_ ctx: RunContext, only items: [UpdateItem]) async -> InstallOutcome {
        guard !items.isEmpty else { return .skipped("nothing selected") }
        _ = await ctx.capture(["sudo", "port", "selfupdate"])
        var failed: [String] = []
        for item in items {
            ctx.line("")
            ctx.line("==> \(item.token)")
            let status = await ctx.run(["sudo", "port", "upgrade", item.token])
            if status != 0 { failed.append(item.token) }
        }
        if failed.count == items.count {
            return InstallOutcome(.failed, "port upgrade failed for: \(failed.joined(separator: ", "))",
                                  failedItems: failed)
        }
        return .partial(failed)
    }
}
