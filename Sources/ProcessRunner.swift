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
/// @unchecked Sendable: `live` is the only shared state and every touch of it
/// is under `lock`.
///
/// Tools *do* run captures concurrently — the Mac App Store scan asks about
/// every purchased app at once — so this must be safe for several processes at
/// a time. It was not: `capture` used to block a worker thread in
/// `waitUntilExit()`, and with more than one Process alive Foundation
/// intermittently loses the termination message, leaving that thread parked in
/// its run loop forever. The scan then sat at "Checking Mac App Store…" with
/// no child process left to kill, so Stop and Force Quit had nothing to act
/// on. Now nothing waits: the pipe is drained as it fills and the result is
/// delivered from the termination handler.
final class ProcessRunner: @unchecked Sendable {

    /// Every process this runner has started and not yet reaped. Stop and
    /// Force Quit act on all of them, which matters when a scan has several
    /// in flight.
    private var live: [Process] = []
    private let lock = NSLock()

    private func remember(_ p: Process) {
        lock.lock(); live.append(p); lock.unlock()
    }
    private func forget(_ p: Process) {
        lock.lock(); live.removeAll { $0 === p }; lock.unlock()
    }
    private var liveProcesses: [Process] {
        lock.lock(); defer { lock.unlock() }; return live
    }

    /// Output collected off two queues (the read handler and the termination
    /// handler), so it needs a lock of its own.
    private final class Collected: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

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
    ///
    /// Safe to call concurrently: no thread is blocked waiting, so a lost
    /// termination message can't wedge one, and the pipe is drained as output
    /// arrives rather than after the fact — a child that outgrows the pipe
    /// buffer would otherwise block on write while we waited for it to exit.
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

                let collected = Collected()
                let reader = pipe.fileHandleForReading
                reader.readabilityHandler = { h in
                    let d = h.availableData
                    guard !d.isEmpty else { return }
                    collected.append(d)
                }
                p.terminationHandler = { proc in
                    reader.readabilityHandler = nil
                    // Whatever arrived between the last read and exit.
                    if let rest = try? reader.readToEnd(), !rest.isEmpty {
                        collected.append(rest)
                    }
                    try? reader.close()
                    self.forget(proc)
                    cont.resume(returning: CaptureResult(status: proc.terminationStatus,
                                                         output: collected.text))
                }

                // Registered before run(), so a process that exits immediately
                // is already known to the handler that removes it.
                self.remember(p)
                do { try p.run() }
                catch {
                    self.forget(p)
                    p.terminationHandler = nil
                    reader.readabilityHandler = nil
                    cont.resume(returning: CaptureResult(status: -1, output: "\(error)"))
                }
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
                    self.forget(proc)
                    cont.resume(returning: proc.terminationStatus)
                }
                self.remember(p)
                do { try p.run() }
                catch { self.forget(p); cont.resume(returning: -1) }
            }
        }
    }

    // Both act on every live child: a scan can have several going at once,
    // and signalling only the newest would leave the others running.
    func interrupt() { liveProcesses.forEach { $0.interrupt() } }   // SIGINT
    func terminate() { liveProcesses.forEach { $0.terminate() } }   // SIGTERM
    var isRunning: Bool { liveProcesses.contains { $0.isRunning } }
}
