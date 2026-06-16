import Foundation
import AppKit

/// Runs subprocesses for tools, two ways:
///   • capture()  — clean pipe, returns full combined output. For scans we parse.
///   • stream()   — PTY-backed (via /usr/bin/script), chunks streamed live to a
///                  callback. For install steps shown in the console. The PTY
///                  also makes CLI tools line-buffer their output and lets
///                  `sudo` present a Touch ID prompt when passwordless sudo
///                  isn't configured.
///
/// Commands are launched through /usr/bin/env so argv[0] is PATH-resolved
/// (tools pass ["brew", "outdated"], not absolute paths).
/// @unchecked Sendable: only one subprocess runs at a time and `current` is
/// touched on the single background queue we dispatch to, so the cross-actor
/// captures the compiler flags are safe in practice.
final class ProcessRunner: @unchecked Sendable {

    /// The process currently running (only one at a time). Exposed so the
    /// coordinator can wire the Abort button to interrupt()/terminate().
    private(set) var current: Process?

    /// Shared environment: a PATH that includes Homebrew + ~/.local/bin, plus
    /// the brew-quieting vars the old shell scripts exported.
    static func baseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_ENV_HINTS"]       = "1"
        env["HOMEBREW_NO_EMOJI"]           = "1"
        env["HOMEBREW_NO_AUTO_UPDATE"]     = "1"
        env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        // brew 4.6+ made --ask the default; skip the "Do you want to proceed?" prompt.
        env["HOMEBREW_NO_ASK"]             = "1"
        return env
    }

    struct CaptureResult { let status: Int32; let output: String }

    /// Run argv with a clean pipe; return exit status + combined stdout/stderr.
    func capture(_ argv: [String], env: [String: String]? = nil) async -> CaptureResult {
        await withCheckedContinuation { (cont: CheckedContinuation<CaptureResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = argv
                p.environment = env ?? Self.baseEnvironment()
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() }
                catch {
                    cont.resume(returning: CaptureResult(status: -1, output: "\(error)"))
                    return
                }
                self.current = p
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                self.current = nil
                cont.resume(returning: CaptureResult(
                    status: p.terminationStatus,
                    output: String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }

    /// Run argv, streaming raw output chunks to `onChunk` (always on the main
    /// queue). Returns the exit status. PTY-backed by default.
    @discardableResult
    func stream(_ argv: [String], env: [String: String]? = nil, pty: Bool = true,
                onChunk: @escaping (String) -> Void) async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                var e = env ?? Self.baseEnvironment()
                if pty {
                    // script(1): -F flush, -q quiet, file=/dev/null, then command.
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
                    p.arguments = ["-F", "-q", "/dev/null", "/usr/bin/env"] + argv
                    e["TERM"] = "xterm-256color"; e["COLUMNS"] = "110"; e["LINES"] = "40"
                } else {
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    p.arguments = argv
                }
                p.environment = e
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
                    DispatchQueue.main.async { onChunk(s) }
                }
                p.terminationHandler = { proc in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    self.current = nil
                    cont.resume(returning: proc.terminationStatus)
                }
                do { try p.run(); self.current = p }
                catch { cont.resume(returning: -1) }
            }
        }
    }

    func interrupt() { current?.interrupt() }   // SIGINT
    func terminate() { current?.terminate() }   // SIGTERM
    var isRunning: Bool { current?.isRunning == true }
}
