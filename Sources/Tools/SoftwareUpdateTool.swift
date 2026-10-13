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
        // The label is what `softwareupdate --install` takes; the title is
        // what a person recognises.
        return .from(ups.map {
            UpdateItem($0.title, token: $0.label,
                       detail: $0.restart ? "needs a restart — via System Settings" : nil)
        })
    }

    var supportsTargetedInstall: Bool { true }

    /// Ticking a row is the consent, so unlike the full run this doesn't ask
    /// again. Restart updates still go to System Settings: the console can't
    /// answer their authorization prompt, so they'd hang at "Password:".
    func install(_ ctx: RunContext, only items: [UpdateItem]) async -> InstallOutcome {
        guard !items.isEmpty else { return .skipped("nothing selected") }
        let byLabel = Dictionary(await list(ctx).map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
        var failed: [String] = [], viaSettings: [String] = []
        for item in items {
            ctx.line("")
            guard let u = byLabel[item.token] else {
                // Installed meanwhile (or withdrawn): nothing left to do.
                ctx.line("✓ \(item.name) — no longer offered")
                ctx.itemFinished(item.token, ok: true)
                continue
            }
            if u.restart {
                ctx.line("ℹ \(u.title) needs System Settings (authorization + restart)")
                viaSettings.append(item.token)
                continue
            }
            ctx.line("==> \(u.title)")
            ctx.itemStarted(item.token)
            let status = await ctx.run(["sudo", "softwareupdate", "--install", "--label", u.label])
            if status != 0 { failed.append(item.token) }
            ctx.itemFinished(item.token, ok: status == 0)
        }
        if !viaSettings.isEmpty,
           await ctx.ask("Open Software Update in System Settings now?") {
            _ = Shell.capture(["open", "x-apple.systempreferences:com.apple.preferences.softwareupdate"])
        }
        // Not attempted here, so neither updated nor failed.
        return InstallOutcome(failed.count == items.count ? .failed : .ok,
                              failed.isEmpty ? nil : "softwareupdate failed for: \(failed.joined(separator: ", "))",
                              failedItems: failed, skippedItems: viaSettings)
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
                    ctx.itemStarted(u.label)
                    let status = await ctx.run(["sudo", "softwareupdate", "--install", "--label", u.label])
                    ctx.itemFinished(u.label, ok: status == 0)
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
