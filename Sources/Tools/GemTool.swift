import Foundation

/// Ruby gems via Homebrew's Ruby (Apple's system Ruby is too old). Invoked by
/// full path so PATH ordering is irrelevant.
struct GemTool: Tool {
    let id = "gem"
    let title = "Ruby gems"

    /// Path to Homebrew Ruby's gem, or nil if not installed.
    private func gemPath() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["brew", "--prefix", "ruby"]
        p.environment = ProcessRunner.baseEnvironment()
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        let prefix = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return nil }
        let gem = prefix + "/bin/gem"
        return FileManager.default.isExecutableFile(atPath: gem) ? gem : nil
    }

    func isAvailable() -> Bool { gemPath() != nil }

    // gem prints noisy "already initialized constant" warnings — filter them.
    private func clean(_ s: String) -> [String] {
        s.split(separator: "\n").map(String.init).filter {
            !$0.isEmpty &&
            !$0.contains("already initialized constant") &&
            !$0.contains("previous definition of")
        }
    }

    /// Installed gems and their newest local version, from `gem list`.
    /// Format: "name (1.2.3, 1.2.2, default: 1.0.0)".
    private func installedGems(_ ctx: RunContext, _ gem: String) async -> [(name: String, version: String)] {
        let r = await ctx.capture([gem, "list", "--local", "--no-details"])
        return clean(r.output).compactMap { line -> (String, String)? in
            guard let open = line.firstIndex(of: "("), line.hasSuffix(")") else { return nil }
            let name = String(line[line.startIndex..<open]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { return nil }
            let inner = line[line.index(after: open)..<line.index(before: line.endIndex)]
            // Newest first; "default: x" entries are Ruby's bundled copies and
            // are always older than a real install, so they're skipped.
            let versions = inner.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("default:") }
            guard let newest = versions.first, !newest.isEmpty else { return nil }
            return (name, newest)
        }
    }

    /// Latest published version of one gem, from the RubyGems API.
    private func latestVersion(of name: String) async -> String? {
        guard let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://rubygems.org/api/v1/versions/\(escaped)/latest.json")
        else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("UpdateAll", forHTTPHeaderField: "User-Agent")
        let data: Data? = await withCheckedContinuation { cont in
            URLSession.shared.dataTask(with: req) { d, _, _ in cont.resume(returning: d) }.resume()
        }
        guard let data = data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["version"] as? String,
              version != "unknown" else { return nil }
        return version
    }

    /// `gem outdated` asks rubygems.org about each installed gem one at a time,
    /// which took ~60s for 85 gems here — nearly all of it waiting on the
    /// network. Listing locally is instant, so we do that and then look the
    /// versions up concurrently, which turns a minute into a couple of seconds.

    // MARK: ─ RubyGems itself ────────────────────────────────────────────────

    /// Token for the row that updates the `gem` command rather than a gem.
    /// Not a real gem name — `rubygems-update` is, and `gem update <that>`
    /// installs the package without applying it, which is not what this does.
    static let systemToken = "__rubygems__"

    /// RubyGems ships as the `rubygems-update` gem, so its registry answers
    /// "is the manager itself behind?" exactly the way it answers for any
    /// package. Reading it from the nag line `gem` prints during unrelated
    /// commands would depend on wording that is not ours.
    private func rubygemsVersions(_ ctx: RunContext, _ gem: String) async -> (current: String, latest: String)? {
        let r = await ctx.capture([gem, "--version"])
        let current = clean(r.output).first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !current.isEmpty,
              let latest = await latestVersion(of: "rubygems-update"),
              Version.sortV(latest, current) == 1 else { return nil }
        return (current, latest)
    }


    // MARK: ─ the read-only plugin collision ─────────────────────────────────

    /// Plugin files in the shared gems directory that are symlinks onto
    /// Homebrew's read-only Cellar.
    ///
    /// `gem update <name>` installs the gem, then writes its plugin file. When
    /// Homebrew's ruby formula has symlinked that path into the Cellar — whose
    /// files are all r--r--r-- — the write fails and RubyGems reports
    /// Gem::FilePermissionError, saying it lacks write permission "for the
    /// … directory". It is not a directory, and the directories involved are
    /// writable; the permissions that matter are on the symlink's target, which
    /// is why this looks impossible from the paths in the message.
    private func unwritablePluginLinks() -> [String] {
        let fm = FileManager.default
        guard let gemDirs = try? fm.contentsOfDirectory(atPath: "/opt/homebrew/lib/ruby/gems")
        else { return [] }
        var out: [String] = []
        for v in gemDirs {
            let plugins = "/opt/homebrew/lib/ruby/gems/\(v)/plugins"
            for f in (try? fm.contentsOfDirectory(atPath: plugins)) ?? [] {
                let path = "\(plugins)/\(f)"
                guard let dest = try? fm.destinationOfSymbolicLink(atPath: path),
                      dest.contains("/Cellar/"), !fm.isWritableFile(atPath: path) else { continue }
                out.append(path)
            }
        }
        return out
    }

    /// Say what actually went wrong, and what clears it.
    private func explainIfPluginCollision(_ ctx: RunContext) {
        let links = unwritablePluginLinks()
        guard !links.isEmpty else { return }
        ctx.line("")
        ctx.line("ℹ A plugin file in the shared gems directory is a symlink onto Homebrew's")
        ctx.line("  Cellar, which is read-only — so RubyGems can install the gem but cannot")
        ctx.line("  write its plugin, and reports a permission error naming a path you can write:")
        for l in links { ctx.line("     \(l)") }
        ctx.line("  Clears it: rm the stale link and update again, or `brew reinstall ruby`.")
        ctx.line("  Works around it: gem install <name> --user-install")
    }

    func scan(_ ctx: RunContext) async -> ScanResult {
        guard let gem = gemPath() else { return .unavailable }
        let installed = await installedGems(ctx, gem)

        var items: [UpdateItem] = []
        var failures = 0
        if let v = await rubygemsVersions(ctx, gem) {
            items.append(UpdateItem("RubyGems (the gem command)", token: Self.systemToken,
                                    current: v.current, latest: v.latest,
                                    detail: "gem update --system"))
        }
        // Bounded concurrency: enough to hide the latency, not so much that we
        // hammer rubygems.org from one machine.
        let batchSize = 12
        for batch in stride(from: 0, to: installed.count, by: batchSize).map({
            Array(installed[$0..<min($0 + batchSize, installed.count)])
        }) {
            await withTaskGroup(of: (String, String, String?).self) { group in
                for g in batch {
                    group.addTask { (g.name, g.version, await latestVersion(of: g.name)) }
                }
                for await (name, current, latest) in group {
                    guard let latest = latest else { failures += 1; continue }
                    if Version.sortV(latest, current) == 1 {
                        items.append(UpdateItem(name, current: current, latest: latest))
                    }
                }
            }
        }

        // Never let a batch of failed lookups read as "everything is current".
        if failures > 0 {
            ctx.line("! couldn't check \(failures) of \(installed.count) gems (network?)")
        }
        // `failures == installed.count` is only evidence of a network problem
        // when something was actually looked up. With no gems installed at all
        // it is 0 == 0, which would report a reachable registry as unreachable.
        if items.isEmpty && !installed.isEmpty && failures == installed.count {
            return .unknown("couldn't reach rubygems.org")
        }
        return .from(items.sorted { $0.name < $1.name })
    }

    var supportsTargetedInstall: Bool { true }

    func install(_ ctx: RunContext, only items: [UpdateItem]) async -> InstallOutcome {
        guard let gem = gemPath() else { return .unavailable }
        guard !items.isEmpty else { return .skipped("nothing selected") }
        // --system is deliberately not run here: a targeted update shouldn't
        // also bump RubyGems itself behind the user's back.
        var failed: [String] = []
        // RubyGems first when it was picked: it is the thing that performs the
        // other updates, so updating it afterwards would mean the gems were
        // installed by the version being replaced.
        let picked = items.sorted { a, _ in a.token == Self.systemToken }
        for item in picked {
            ctx.line("")
            if item.token == Self.systemToken {
                ctx.line("==> RubyGems itself")
                let status = await ctx.run([gem, "update", "--system", "--no-document"])
                if status != 0 { failed.append(item.token) }
                continue
            }
            ctx.line("==> \(item.token)")
            let status = await ctx.run([gem, "update", "--no-document", item.token])
            if status != 0 { failed.append(item.token) }
        }
        if !failed.isEmpty { explainIfPluginCollision(ctx) }
        if failed.count == items.count {
            return InstallOutcome(.failed, "gem update failed for: \(failed.joined(separator: ", "))",
                                  failedItems: failed)
        }
        return .partial(failed)
    }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        guard let gem = gemPath() else { return .unavailable }
        // --no-document: RubyGems runs its RDoc hook in-process, so a newer rdoc
        // gem loaded next to Ruby's older default rdoc raises ArgumentError and
        // aborts the whole update mid-list — gems after the failure never get
        // updated, even though the one being built installed fine. We don't want
        // ri/rdoc output anyway.
        // RubyGems itself is its own row now, so it is updated only when the
        // user ticked it. It used to be bumped here on every full run with its
        // output swallowed, which meant a targeted run never updated it and a
        // full run never showed that it had.
        _ = ctx
        let r = await ctx.capture([gem, "update", "--no-document"])
        let lines = clean(r.output)
        if lines.isEmpty || lines.contains(where: { $0.contains("Nothing to update") }) {
            ctx.line("✓ All gems up to date")
        } else {
            for l in lines { ctx.emit(l + "\n") }
        }
        if r.status != 0 { explainIfPluginCollision(ctx) }
        return r.status == 0 ? .ok : .failed("gem update exited \(r.status)")
    }
}
