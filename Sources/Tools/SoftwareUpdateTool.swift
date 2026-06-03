import Foundation
import AppKit

/// macOS system updates via `softwareupdate`. Last in the run order so a
/// pending restart doesn't interrupt the other tools.
struct SoftwareUpdateTool: Tool {
    let id = "macos"
    let title = "macOS Software Update"
    func isAvailable() -> Bool { true }   // always present on macOS

    /// Parse `softwareupdate --list` into label/title/restart info.
    private struct Listing { var labels: [String]; var titles: [String]; var needsRestart: Bool }
    private func list(_ ctx: RunContext) async -> Listing {
        let out = await ctx.capture(["softwareupdate", "--list"]).output
        var labels: [String] = [], titles: [String] = []
        for line in out.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("* Label:") { labels.append(String(s.dropFirst("* Label:".count)).trimmingCharacters(in: .whitespaces)) }
            else if s.hasPrefix("Title:") { titles.append(s) }
        }
        return Listing(labels: labels, titles: titles, needsRestart: out.contains("Action: restart"))
    }

    func scan(_ ctx: RunContext) async -> ScanResult {
        let l = await list(ctx)
        return .from(l.labels.map { UpdateItem($0) })
    }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        let l = await list(ctx)
        if l.labels.isEmpty {
            ctx.line("✓ No updates available")
            return .ok
        }
        for t in l.titles { ctx.line(t) }
        guard await ctx.ask("Install all \(l.labels.count) macOS update(s)?") else {
            ctx.line("⊘ Skipped")
            return .skipped()
        }
        let status = await ctx.run(["sudo", "softwareupdate", "--install", "--all"])
        if l.needsRestart {
            ctx.line("")
            ctx.line("ℹ A macOS update has been staged — it will install on next restart.")
        }
        return status == 0 ? .ok : .failed("softwareupdate exited \(status)")
    }
}
