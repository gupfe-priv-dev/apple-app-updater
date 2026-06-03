import Foundation

/// MacPorts. scan: `port outdated`. install: `sudo port selfupdate` then
/// `sudo port upgrade outdated` (sudo covered by the NOPASSWD sudoers rule).
struct MacPortsTool: Tool {
    let id = "macports"
    let title = "MacPorts"
    func isAvailable() -> Bool { commandExists("port") }

    func scan(_ ctx: RunContext) async -> ScanResult {
        let r = await ctx.capture(["port", "outdated"])
        let items = r.output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("No installed ports are outdated") }
            .map { UpdateItem($0) }
        return .from(items)
    }

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
}
