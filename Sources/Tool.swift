import Foundation

/// Per-run services a tool uses to do its work, without knowing anything about
/// AppKit. The coordinator constructs one and hands it to each tool.
final class RunContext {
    let runner: ProcessRunner
    private let emitter: (String) -> Void
    private let asker: (String) async -> Bool

    init(runner: ProcessRunner,
         emit: @escaping (String) -> Void,
         ask: @escaping (String) async -> Bool) {
        self.runner = runner
        self.emitter = emit
        self.asker = ask
    }

    /// Append text to the live console (already on/handed to the main queue).
    func emit(_ text: String) { emitter(text) }

    /// Convenience: emit a line with the script-style two-space indent.
    func line(_ text: String = "") { emitter("  \(text)\n") }

    /// Ask the user a yes/no question via native UI. Returns true for yes.
    func ask(_ question: String) async -> Bool { await asker(question) }

    /// Run a command, streaming its output to the console. Returns exit status.
    @discardableResult
    func run(_ argv: [String], pty: Bool = true) async -> Int32 {
        await runner.stream(argv, pty: pty, onChunk: { [emitter] in emitter($0) })
    }

    /// Run a command silently and capture its combined output (for parsing).
    func capture(_ argv: [String]) async -> ProcessRunner.CaptureResult {
        await runner.capture(argv)
    }
}

/// A single updatable subsystem (Homebrew casks, Mac App Store, npm, …).
/// Each concrete tool lives in its own file under Sources/Tools/.
protocol Tool {
    /// Stable identifier used for Settings (enable/disable) and skip lists.
    var id: String { get }
    /// Sidebar / section label. Must be unique.
    var title: String { get }

    /// Whether the underlying CLI / mechanism is present on this machine.
    /// Cheap check (command -v). Tools that are always applicable return true.
    func isAvailable() -> Bool

    /// Check for available updates without installing anything.
    func scan(_ ctx: RunContext) async -> ScanResult

    /// Apply available updates. May prompt via ctx.ask for destructive/ambiguous
    /// steps. Streams progress via ctx.run / ctx.emit.
    func install(_ ctx: RunContext) async -> InstallOutcome
}

extension Tool {
    /// Default availability helper: is `cmd` on PATH?
    func commandExists(_ cmd: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["command", "-v", cmd]
        p.environment = ProcessRunner.baseEnvironment()
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
