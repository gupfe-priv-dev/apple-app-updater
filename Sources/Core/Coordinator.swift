import Foundation

/// UI surface the coordinator drives. AppDelegate conforms to it. All calls are
/// made on the main actor.
@MainActor
protocol CoordinatorHost: AnyObject {
    /// Tools in display order — also defines the sidebar rows.
    var tools: [Tool] { get }
    /// A run is about to start; reset UI for `mode`.
    func runWillStart(_ mode: Coordinator.Mode)
    /// Section `index` became active.
    func sectionDidBegin(_ index: Int)
    /// Append live output to the active section's console.
    func appendConsole(_ text: String)
    /// Section finished a scan with a structured result.
    func sectionDidEndScan(_ index: Int, _ result: ScanResult)
    /// Section finished an install.
    func sectionDidEndInstall(_ index: Int, _ outcome: InstallOutcome)
    /// Section was skipped without running (disabled / unavailable / up-to-date).
    func sectionSkipped(_ index: Int, reason: String)
    /// Ask the user a yes/no question via native UI.
    func ask(_ question: String) async -> Bool
    /// The whole run finished.
    func runDidFinish(_ mode: Coordinator.Mode, aborted: Bool)

    /// A single-section run is starting (don't reset the other rows).
    func singleRunWillStart(_ index: Int, _ mode: Coordinator.Mode)
    /// A single-section run finished.
    func singleRunDidFinish(_ index: Int, _ mode: Coordinator.Mode, aborted: Bool)
}

/// Runs the registered tools in order for a scan or install, publishing each
/// step to the host. Replaces the old "one big shell script + parse its
/// stdout" engine: section boundaries and results are now explicit and typed.
@MainActor
final class Coordinator {
    enum Mode { case scan, install }

    let runner = ProcessRunner()
    weak var host: CoordinatorHost?

    private(set) var isRunning = false
    private var aborted = false
    private var task: Task<Void, Never>?
    /// Most recent scan result per tool id — drives install-skipping so an
    /// install run only touches tools that actually have updates (or whose
    /// state is indeterminate, e.g. pipx/claude).
    private var lastScan: [String: ScanResult] = [:]

    init(host: CoordinatorHost) { self.host = host }

    func run(_ mode: Mode) {
        guard !isRunning, let host = host else { return }
        isRunning = true
        aborted = false
        host.runWillStart(mode)
        let tools = host.tools
        task = Task { @MainActor [weak self] in
            guard let self = self else { return }
            for (i, tool) in tools.enumerated() {
                if self.aborted { break }

                if !Settings.isEnabled(tool.id) {
                    host.sectionSkipped(i, reason: "disabled")
                    continue
                }
                if !tool.isAvailable() {
                    host.sectionSkipped(i, reason: "not installed")
                    continue
                }
                // On install, skip tools the last scan found up to date.
                if mode == .install, let prev = self.lastScan[tool.id], prev.state == .upToDate {
                    host.sectionSkipped(i, reason: "up to date")
                    continue
                }

                host.sectionDidBegin(i)
                let ctx = RunContext(
                    runner: self.runner,
                    // Tools call emit synchronously from off-main work; hop to
                    // the main thread for the UI mutation.
                    emit: { [weak host] s in
                        if Thread.isMainThread { host?.appendConsole(s) }
                        else { DispatchQueue.main.async { host?.appendConsole(s) } }
                    },
                    ask:  { [weak host] q in await host?.ask(q) ?? false })

                switch mode {
                case .scan:
                    let r = await tool.scan(ctx)
                    self.lastScan[tool.id] = r
                    host.sectionDidEndScan(i, r)
                case .install:
                    let o = await tool.install(ctx)
                    host.sectionDidEndInstall(i, o)
                }
            }
            self.isRunning = false
            host.runDidFinish(mode, aborted: self.aborted)
        }
    }

    /// Run just one tool (from the section context menu). Doesn't reset the
    /// other rows. Forces the run even if the last scan said up-to-date — the
    /// user explicitly asked for this section.
    func runSingle(_ index: Int, _ mode: Mode) {
        guard !isRunning, let host = host else { return }
        let tools = host.tools
        guard index >= 0, index < tools.count else { return }
        isRunning = true
        aborted = false
        host.singleRunWillStart(index, mode)
        let tool = tools[index]
        task = Task { @MainActor [weak self] in
            guard let self = self else { return }
            if !tool.isAvailable() {
                host.sectionSkipped(index, reason: "not installed")
            } else {
                host.sectionDidBegin(index)
                let ctx = RunContext(
                    runner: self.runner,
                    emit: { [weak host] s in
                        if Thread.isMainThread { host?.appendConsole(s) }
                        else { DispatchQueue.main.async { host?.appendConsole(s) } }
                    },
                    ask: { [weak host] q in await host?.ask(q) ?? false })
                switch mode {
                case .scan:
                    let r = await tool.scan(ctx)
                    self.lastScan[tool.id] = r
                    host.sectionDidEndScan(index, r)
                case .install:
                    let o = await tool.install(ctx)
                    host.sectionDidEndInstall(index, o)
                }
            }
            self.isRunning = false
            host.singleRunDidFinish(index, mode, aborted: self.aborted)
        }
    }

    func abort() { aborted = true; runner.interrupt() }
    func forceKill() { runner.terminate() }
    var subprocessRunning: Bool { runner.isRunning }
}
