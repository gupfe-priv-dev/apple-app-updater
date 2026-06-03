import Foundation

/// pipx packages. pipx has no structured "outdated" mode, so scan is
/// indeterminate; `upgrade-all` is cheap and idempotent, so install just runs it.
struct PipxTool: Tool {
    let id = "pipx"
    let title = "pipx"
    func isAvailable() -> Bool { commandExists("pipx") }

    func scan(_ ctx: RunContext) async -> ScanResult {
        .unknown("pipx has no scan-only mode — runs on install")
    }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        let status = await ctx.run(["pipx", "upgrade-all"])
        return status == 0 ? .ok : .failed("pipx upgrade-all exited \(status)")
    }
}
