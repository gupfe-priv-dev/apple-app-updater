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

    /// `gem outdated` prints "name (current < latest)" — split it so the table
    /// gets a bare gem name and a real version delta instead of one blob.
    private func parse(_ line: String) -> UpdateItem {
        let name = String(line.split(separator: " ").first ?? Substring(line))
        guard let open = line.firstIndex(of: "("), line.hasSuffix(")") else {
            return UpdateItem(name)
        }
        let inner = line[line.index(after: open)..<line.index(before: line.endIndex)]
        let pair = inner.components(separatedBy: "<").map { $0.trimmingCharacters(in: .whitespaces) }
        guard pair.count == 2 else { return UpdateItem(name) }
        return UpdateItem(name, current: pair[0], latest: pair[1])
    }

    func scan(_ ctx: RunContext) async -> ScanResult {
        guard let gem = gemPath() else { return .unavailable }
        let r = await ctx.capture([gem, "outdated"])
        return .from(clean(r.output).map(parse))
    }

    var supportsTargetedInstall: Bool { true }

    func install(_ ctx: RunContext, only items: [UpdateItem]) async -> InstallOutcome {
        guard let gem = gemPath() else { return .unavailable }
        guard !items.isEmpty else { return .skipped("nothing selected") }
        // --system is deliberately not run here: a targeted update shouldn't
        // also bump RubyGems itself behind the user's back.
        var failed: [String] = []
        for item in items {
            ctx.line("")
            ctx.line("==> \(item.token)")
            let status = await ctx.run([gem, "update", "--no-document", item.token])
            if status != 0 { failed.append(item.token) }
        }
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
        _ = await ctx.capture([gem, "update", "--system", "--no-document"])
        let r = await ctx.capture([gem, "update", "--no-document"])
        let lines = clean(r.output)
        if lines.isEmpty || lines.contains(where: { $0.contains("Nothing to update") }) {
            ctx.line("✓ All gems up to date")
        } else {
            for l in lines { ctx.emit(l + "\n") }
        }
        return r.status == 0 ? .ok : .failed("gem update exited \(r.status)")
    }
}
