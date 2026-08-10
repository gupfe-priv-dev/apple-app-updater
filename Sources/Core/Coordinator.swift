import Foundation

/// UI surface the coordinator drives. All calls are made on the main actor.
@MainActor
protocol CoordinatorHost: AnyObject {
    /// Tools in display + execution order.
    var tools: [Tool] { get }
    /// A run is about to start; reset UI for `mode`.
    func runWillStart(_ mode: Coordinator.Mode)
    /// Tool `index` became active.
    func toolDidBegin(_ index: Int)
    /// Append live output to the console.
    func appendConsole(_ text: String)
    /// A scan finished with a structured result.
    func toolDidEndScan(_ index: Int, _ result: ScanResult)
    /// An install finished. `items` is what this tool was asked to update
    /// (empty when it upgraded everything it had) — the host pairs it with
    /// `outcome.failedItems` to update the failure memory.
    func toolDidEndInstall(_ index: Int, _ outcome: InstallOutcome, items: [UpdateItem])
    /// A tool was passed over without running.
    func toolSkipped(_ index: Int, reason: String)
    /// Ask the user a yes/no question via native UI.
    func ask(_ question: String) async -> Bool
    /// The whole run finished.
    func runDidFinish(_ mode: Coordinator.Mode, aborted: Bool)
}

/// Runs the registered tools for a scan or an install, publishing each step to
/// the host. Section boundaries and results are explicit and typed rather than
/// scraped out of a shell script's stdout.
@MainActor
final class Coordinator {
    enum Mode { case scan, install }

    let runner = ProcessRunner()
    weak var host: CoordinatorHost?

    private(set) var isRunning = false
    private var aborted = false
    private var task: Task<Void, Never>?

    init(host: CoordinatorHost) { self.host = host }

    // MARK: scan ─────────────────────────────────────────────────────────

    /// Scan every enabled, available tool.
    func scan() {
        guard !isRunning, let host = host else { return }
        // A scan is the point at which "what's installed" is re-established,
        // so drop the cached availability answers first.
        ToolAvailability.invalidate()
        begin(.scan)
        let tools = host.tools
        task = Task { @MainActor [weak self] in
            guard let self = self, let host = self.host else { return }
            for (i, tool) in tools.enumerated() {
                if self.aborted { break }
                if !Settings.isEnabled(tool.id) { host.toolSkipped(i, reason: "disabled"); continue }
                if !ToolAvailability.check(tool) { host.toolSkipped(i, reason: "not installed"); continue }
                host.toolDidBegin(i)
                let r = await tool.scan(self.context())
                host.toolDidEndScan(i, r)
            }
            self.finish(.scan)
        }
    }

    // MARK: install ──────────────────────────────────────────────────────

    /// Install a specific selection: tool index → the items checked for it.
    /// A tool that can't target a subset (`supportsTargetedInstall == false`)
    /// gets its full bulk install as long as anything of its is selected — the
    /// UI keeps those rows checked as one group so that stays honest.
    func install(selection: [Int: [UpdateItem]]) {
        guard !isRunning, let host = host else { return }
        begin(.install)
        let tools = host.tools
        task = Task { @MainActor [weak self] in
            guard let self = self, let host = self.host else { return }
            for (i, tool) in tools.enumerated() {
                if self.aborted { break }
                guard let items = selection[i], !items.isEmpty else { continue }
                if !Settings.isEnabled(tool.id) { host.toolSkipped(i, reason: "disabled"); continue }
                if !ToolAvailability.check(tool) { host.toolSkipped(i, reason: "not installed"); continue }

                host.toolDidBegin(i)
                let ctx = self.context()
                let outcome: InstallOutcome
                if tool.supportsTargetedInstall {
                    outcome = await tool.install(ctx, only: items)
                } else {
                    outcome = await tool.install(ctx)
                }
                host.toolDidEndInstall(i, outcome, items: items)
            }
            self.finish(.install)
        }
    }

    // MARK: plumbing ─────────────────────────────────────────────────────

    private func begin(_ mode: Mode) {
        isRunning = true
        aborted = false
        host?.runWillStart(mode)
    }

    private func finish(_ mode: Mode) {
        isRunning = false
        host?.runDidFinish(mode, aborted: aborted)
    }

    /// A fresh RunContext wired to the host. Tools emit from off-main work, so
    /// the emit closure hops to the main thread for the UI mutation.
    private func context() -> RunContext {
        RunContext(
            runner: runner,
            emit: { [weak host] s in
                if Thread.isMainThread { host?.appendConsole(s) }
                else { DispatchQueue.main.async { host?.appendConsole(s) } }
            },
            ask: { [weak host] q in await host?.ask(q) ?? false })
    }

    func abort() { aborted = true; runner.interrupt() }
    func forceKill() { runner.terminate() }
    var subprocessRunning: Bool { runner.isRunning }
}
