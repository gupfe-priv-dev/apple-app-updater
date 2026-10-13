import Foundation

/// Ruby gems, in whichever Ruby the user runs: rbenv's global version when
/// rbenv manages one, otherwise Homebrew's (Apple's system Ruby is too old).
/// See RubyEnv. Under rbenv, Ruby itself is a row too.
struct GemTool: Tool {
    let id = "gem"
    let title = "Ruby gems"

    private func gemPath() -> String? { RubyEnv.current()?.gem }

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


    // MARK: ─ Ruby itself (rbenv) ──────────────────────────────────────────

    /// Token for the row that moves rbenv's global Ruby to a newer release.
    static let rubyToken = "__ruby__"

    /// Build the new Ruby, carry the old one's gems over, then make it global.
    ///
    /// Gems belong to one Ruby, so a bare `rbenv global` would leave every
    /// command the user had installed — fastlane, cocoapods — behind in the old
    /// version, and the new one starts with only what Ruby bundles. They are
    /// installed fresh (their latest), which is also why the gem rows scanned
    /// against the old Ruby need nothing more once this has run.
    ///
    /// Global is switched last, so a failed build or install leaves the user
    /// on the Ruby that worked.
    private func upgradeRuby(_ ctx: RunContext, from old: String, to new: String) async -> Bool {
        ctx.line("==> Ruby \(old) → \(new) (rbenv) — building from source takes a few minutes")
        guard await ctx.run(["rbenv", "install", "--skip-existing", new]) == 0,
              let oldGem = RubyEnv.rbenvGem(old), let newGem = RubyEnv.rbenvGem(new)
        else { return false }

        let have = Set(await ctx.capture([newGem, "list", "--no-versions"]).output
            .split(separator: "\n").map(String.init))
        let missing = clean(await ctx.capture([oldGem, "list", "--no-versions"]).output)
            .filter { !$0.contains(" ") && !have.contains($0) }
        if !missing.isEmpty {
            ctx.line("")
            ctx.line("==> Reinstalling \(missing.count) gem\(missing.count == 1 ? "" : "s") from Ruby \(old)")
            // One gem that won't build on the new Ruby shouldn't hold the rest
            // hostage, but it isn't this tool's call to strand it either.
            if await ctx.run([newGem, "install", "--no-document"] + missing) != 0,
               !(await ctx.ask("Some gems didn't install into Ruby \(new) (see the console). Switch to it anyway?")) {
                ctx.line("Ruby \(old) stays the global version; \(new) is installed alongside")
                return false
            }
        }

        guard await ctx.run(["rbenv", "global", new]) == 0 else { return false }
        await ctx.run(["rbenv", "rehash"])
        ctx.line("✓ Ruby \(new) is now rbenv's global version")

        // The old version still works and costs nothing to keep; removing it is
        // the user's call, and a project's .ruby-version may still name it.
        if await ctx.ask("Remove the previous Ruby \(old)? A project whose .ruby-version names it would need it reinstalled.") {
            await ctx.run(["rbenv", "uninstall", "--force", old])
        }
        return true
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
    /// Only Homebrew's ruby has this layout; an rbenv Ruby owns all its files.
    private func unwritablePluginLinks() -> [String] {
        guard let env = RubyEnv.current(), env.kind == .homebrew else { return [] }
        let fm = FileManager.default
        // <brew prefix>/opt/ruby/bin/gem → <brew prefix>/lib/ruby/gems. Not a
        // fixed /opt/homebrew: an Intel Mac's prefix is /usr/local.
        let brewPrefix = ((env.gem as NSString).deletingLastPathComponent as NSString)
            .deletingLastPathComponent.replacingOccurrences(of: "/opt/ruby", with: "")
        let gemsRoot = "\(brewPrefix)/lib/ruby/gems"
        guard let gemDirs = try? fm.contentsOfDirectory(atPath: gemsRoot)
        else { return [] }
        var out: [String] = []
        for v in gemDirs {
            let plugins = "\(gemsRoot)/\(v)/plugins"
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
        guard let env = RubyEnv.current() else { return .unavailable }
        let gem = env.gem
        let installed = await installedGems(ctx, gem)

        var items: [UpdateItem] = []
        var failures = 0
        if case .rbenv(let current) = env.kind,
           let latest = RubyEnv.latestStableRuby(),
           Version.sortV(latest, current) == 1 {
            items.append(UpdateItem("Ruby (rbenv global)", token: Self.rubyToken,
                                    current: current, latest: latest,
                                    detail: "rbenv install, move gems, rbenv global"))
        }
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
        guard var gem = gemPath() else { return .unavailable }
        guard !items.isEmpty else { return .skipped("nothing selected") }
        // --system is deliberately not run here: a targeted update shouldn't
        // also bump RubyGems itself behind the user's back.
        var failed: [String] = []
        var rest = items
        // Ruby before everything: the rows after it should land in the Ruby the
        // user ends up on, not the one being replaced.
        if let ruby = items.first(where: { $0.token == Self.rubyToken }) {
            rest.removeAll { $0.token == Self.rubyToken }
            ctx.itemStarted(ruby.token)
            if let old = ruby.current, let new = ruby.latest,
               await upgradeRuby(ctx, from: old, to: new) {
                gem = gemPath() ?? gem
                ctx.itemFinished(ruby.token, ok: true)
            } else {
                failed.append(ruby.token)
                ctx.itemFinished(ruby.token, ok: false)
            }
        }
        // RubyGems next when it was picked: it is the thing that performs the
        // other updates, so updating it afterwards would mean the gems were
        // installed by the version being replaced.
        let picked = rest.sorted { a, _ in a.token == Self.systemToken }
        for item in picked {
            ctx.line("")
            ctx.itemStarted(item.token)
            let status: Int32
            if item.token == Self.systemToken {
                ctx.line("==> RubyGems itself")
                status = await ctx.run([gem, "update", "--system", "--no-document"])
            } else {
                ctx.line("==> \(item.token)")
                status = await ctx.run([gem, "update", "--no-document", item.token])
            }
            if status != 0 { failed.append(item.token) }
            ctx.itemFinished(item.token, ok: status == 0)
        }
        if !failed.isEmpty { explainIfPluginCollision(ctx) }
        // Updated gems may bring new executables; under rbenv they are only on
        // PATH once a shim exists for them.
        if case .rbenv? = RubyEnv.current()?.kind { _ = await ctx.capture(["rbenv", "rehash"]) }
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
        if case .rbenv? = RubyEnv.current()?.kind { _ = await ctx.capture(["rbenv", "rehash"]) }
        return r.status == 0 ? .ok : .failed("gem update exited \(r.status)")
    }
}
