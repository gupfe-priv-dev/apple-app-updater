import Foundation

/// Unmanaged apps that ship a Sparkle appcast (SUFeedURL). Feeds are checked
/// during install (no cheap dry-run), so scan is indeterminate. Currently
/// bridges to the bundled sparkle.py; ported to Swift in Phase 4.
struct SparkleTool: Tool {
    let id = "sparkle"
    let title = "Sparkle updates (unmanaged apps)"
    func isAvailable() -> Bool { true }

    private var scriptPath: String? { Bundle.main.path(forResource: "sparkle", ofType: "py") }

    func scan(_ ctx: RunContext) async -> ScanResult {
        .unknown("feeds checked on install")
    }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        guard let script = scriptPath else { ctx.line("✗ sparkle.py missing"); return .unavailable }
        AppPaths.ensure()
        let status = await ctx.run(["python3", script], env: AppPaths.bridgeEnv())
        return status == 0 ? .ok : .failed("sparkle.py exited \(status)")
    }
}
