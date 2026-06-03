import Foundation

/// Claude Code CLI. No dry-run, so scan just reports the installed version;
/// install runs `claude update`.
struct ClaudeTool: Tool {
    let id = "claude"
    let title = "Claude Code"
    func isAvailable() -> Bool { commandExists("claude") }

    func scan(_ ctx: RunContext) async -> ScanResult {
        let ver = await ctx.capture(["claude", "--version"]).output
            .split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? "(version unknown)"
        return .unknown("installed \(ver) — runs on install")
    }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        let r = await ctx.capture(["claude", "update"])
        if let line = r.output.split(separator: "\n").first(where: { $0.contains("up to date") }) {
            ctx.line("✓ \(line.trimmingCharacters(in: .whitespaces))")
        } else {
            for l in r.output.split(separator: "\n") { ctx.emit(l + "\n") }
        }
        return r.status == 0 ? .ok : .failed("claude update exited \(r.status)")
    }
}
