import Foundation

/// pipx packages.
///
/// pipx has no "outdated" command, which used to mean a permanent
/// can't-tell row in the table. It does have `pipx list --json`, and PyPI
/// publishes the current version of everything, so the two can be compared the
/// same way the gem scan works.
///
/// Anything unexpected — no json, an unreadable entry, an unreachable PyPI —
/// falls back to reporting "unknown" rather than guessing "up to date".
struct PipxTool: Tool {
    let id = "pipx"
    let title = "pipx"
    func isAvailable() -> Bool { commandExists("pipx") }

    /// Installed packages and their versions from `pipx list --json`.
    /// Shape: { "venvs": { "<name>": { "metadata": { "main_package":
    ///          { "package": "x", "package_version": "1.2.3" } } } } }
    private func installedPackages(_ ctx: RunContext) async -> [(name: String, version: String)]? {
        let r = await ctx.capture(["pipx", "list", "--json"])
        guard let data = r.output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let venvs = obj["venvs"] as? [String: Any] else { return nil }
        var out: [(String, String)] = []
        for (_, v) in venvs {
            guard let venv = v as? [String: Any],
                  let meta = venv["metadata"] as? [String: Any],
                  let main = meta["main_package"] as? [String: Any],
                  let name = main["package"] as? String,
                  let version = main["package_version"] as? String else { continue }
            out.append((name, version))
        }
        return out
    }

    private func latestVersion(of package: String) async -> String? {
        guard let escaped = package.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://pypi.org/pypi/\(escaped)/json") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("UpdateAll", forHTTPHeaderField: "User-Agent")
        let data: Data? = await withCheckedContinuation { cont in
            URLSession.shared.dataTask(with: req) { d, _, _ in cont.resume(returning: d) }.resume()
        }
        guard let data = data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = obj["info"] as? [String: Any],
              let version = info["version"] as? String else { return nil }
        return version
    }

    func scan(_ ctx: RunContext) async -> ScanResult {
        guard let packages = await installedPackages(ctx) else {
            return .unknown("pipx list --json wasn't readable — runs on install")
        }
        guard !packages.isEmpty else { return .upToDate }

        var items: [UpdateItem] = []
        var failures = 0
        await withTaskGroup(of: (String, String, String?).self) { group in
            for p in packages {
                group.addTask { (p.name, p.version, await latestVersion(of: p.name)) }
            }
            for await (name, current, latest) in group {
                guard let latest = latest else { failures += 1; continue }
                if Version.sortV(latest, current) == 1 {
                    items.append(UpdateItem(name, current: current, latest: latest))
                }
            }
        }
        if failures > 0 {
            ctx.line("! couldn't check \(failures) of \(packages.count) packages (network?)")
        }
        if items.isEmpty && failures == packages.count {
            return .unknown("couldn't reach PyPI")
        }
        return .from(items.sorted { $0.name < $1.name })
    }

    var supportsTargetedInstall: Bool { true }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        let status = await ctx.run(["pipx", "upgrade-all"])
        return status == 0 ? .ok : .failed("pipx upgrade-all exited \(status)")
    }

    func install(_ ctx: RunContext, only items: [UpdateItem]) async -> InstallOutcome {
        guard !items.isEmpty else { return .skipped("nothing selected") }
        var failed: [String] = []
        for item in items {
            ctx.line("")
            ctx.line("==> \(item.token)")
            if await ctx.run(["pipx", "upgrade", item.token]) != 0 { failed.append(item.token) }
        }
        if failed.count == items.count {
            return InstallOutcome(.failed, "pipx upgrade failed for: \(failed.joined(separator: ", "))",
                                  failedItems: failed)
        }
        return .partial(failed)
    }
}
