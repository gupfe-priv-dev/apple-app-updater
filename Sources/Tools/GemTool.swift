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

    func scan(_ ctx: RunContext) async -> ScanResult {
        guard let gem = gemPath() else { return .unavailable }
        let r = await ctx.capture([gem, "outdated"])
        return .from(clean(r.output).map { UpdateItem($0) })
    }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        guard let gem = gemPath() else { return .unavailable }
        _ = await ctx.capture([gem, "update", "--system"])
        let r = await ctx.capture([gem, "update"])
        let lines = clean(r.output)
        if lines.isEmpty || lines.contains(where: { $0.contains("Nothing to update") }) {
            ctx.line("✓ All gems up to date")
        } else {
            for l in lines { ctx.emit(l + "\n") }
        }
        return .ok
    }
}
