import Foundation
import AppKit

/// macOS system updates via `softwareupdate`. Last in the run order so a
/// pending restart doesn't interrupt the other tools.
///
/// Major OS upgrades (Action: restart) require their own interactive
/// authorization + a reboot, which a read-only console can't satisfy — so we
/// never CLI-install those (it would hang at "Password:"). They're routed to
/// System Settings instead. Smaller updates (Safari, security, command-line
/// tools) install non-interactively under the passwordless-sudo rule.
struct SoftwareUpdateTool: Tool {
    let id = "macos"
    let title = "macOS Software Update"
    func isAvailable() -> Bool { true }

    private struct Update { let label: String; let title: String; let restart: Bool }

    /// Parse `softwareupdate --list` into labelled updates with restart flags.
    private func list(_ ctx: RunContext) async -> [Update] {
        let out = await ctx.capture(["softwareupdate", "--list"]).output
        var updates: [Update] = []
        var pendingLabel: String?
        for raw in out.split(separator: "\n") {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("* Label:") {
                pendingLabel = String(trimmed.dropFirst("* Label:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Title:"), let label = pendingLabel {
                let title = trimmed
                    .components(separatedBy: ",").first?
                    .replacingOccurrences(of: "Title:", with: "")
                    .trimmingCharacters(in: .whitespaces) ?? label
                updates.append(Update(label: label, title: title, restart: trimmed.contains("Action: restart")))
                pendingLabel = nil
            }
        }
        return updates
    }

    func scan(_ ctx: RunContext) async -> ScanResult {
        let ups = await list(ctx)
        return .from(ups.map { UpdateItem($0.title) })
    }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        let ups = await list(ctx)
        if ups.isEmpty {
            ctx.line("✓ No updates available")
            return .ok
        }
        let installable = ups.filter { !$0.restart }   // safe to install non-interactively
        let majorUpgrades = ups.filter { $0.restart }  // need System Settings + reboot

        for u in ups { ctx.line("• \(u.title)\(u.restart ? "  (restart — via System Settings)" : "")") }

        // Install the non-restart updates via labels (covered by the passwordless
        // sudoers rule → no interactive prompt).
        if !installable.isEmpty {
            if await ctx.ask("Install \(installable.count) update(s)?") {
                for u in installable {
                    ctx.line("→ \(u.title)")
                    _ = await ctx.run(["sudo", "softwareupdate", "--install", "--label", u.label])
                }
            } else {
                ctx.line("⊘ Skipped non-restart updates")
            }
        }

        // Route major OS upgrades to System Settings (interactive auth + reboot).
        if !majorUpgrades.isEmpty {
            ctx.line("")
            ctx.line("ℹ The following require System Settings → General → Software Update")
            ctx.line("  (interactive authorization + a restart — not done here):")
            for u in majorUpgrades { ctx.line("    • \(u.title)") }
            if await ctx.ask("Open Software Update in System Settings now?") {
                _ = Shell.capture(["open", "x-apple.systempreferences:com.apple.preferences.softwareupdate"])
            }
        }
        return .ok
    }
}
