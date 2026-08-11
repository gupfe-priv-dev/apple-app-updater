import Foundation

/// Claude Code CLI.
///
/// `claude update` has no dry-run, so this used to report "can't tell" and earn
/// a permanent row in the table — which read as "an update is waiting" even when
/// the CLI was current. It isn't unknowable, though: the installed version is
/// one command away and the published version is in the npm registry, so this
/// compares the two like every other manager and only produces a row when
/// there's really something to install.
struct ClaudeTool: Tool {
    let id = "claude"
    let title = "Claude Code"
    func isAvailable() -> Bool { commandExists("claude") }

    /// Published version from the npm registry. Claude Code is distributed as
    /// @anthropic-ai/claude-code, and the registry is the same source whichever
    /// installer put it there.
    private static let registryURL =
        "https://registry.npmjs.org/@anthropic-ai/claude-code/latest"

    /// "2.1.227 (Claude Code)" → "2.1.227"
    private func installedVersion(_ ctx: RunContext) async -> String? {
        let out = await ctx.capture(["claude", "--version"]).output
        guard let first = out.split(separator: "\n").first else { return nil }
        let token = first.split(separator: " ").first.map(String.init)
        // Only accept something that actually looks like a version, so a future
        // change of wording surfaces as "couldn't tell" rather than nonsense.
        guard let t = token, t.first?.isNumber == true else { return nil }
        return t
    }

    private func latestVersion() async -> String? {
        guard let url = URL(string: Self.registryURL) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("UpdateAll", forHTTPHeaderField: "User-Agent")
        let data: Data? = await withCheckedContinuation { cont in
            URLSession.shared.dataTask(with: req) { d, _, _ in cont.resume(returning: d) }.resume()
        }
        guard let data = data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["version"] as? String else { return nil }
        return version
    }

    func scan(_ ctx: RunContext) async -> ScanResult {
        guard let current = await installedVersion(ctx) else {
            return .unknown("couldn't read the installed version")
        }
        guard let latest = await latestVersion() else {
            // Never report "up to date" on the strength of a failed lookup.
            return .unknown("installed \(current) — couldn't reach the npm registry")
        }
        guard Version.sortV(latest, current) == 1 else { return .upToDate }
        return .from([UpdateItem(title, token: id, current: current, latest: latest)])
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
