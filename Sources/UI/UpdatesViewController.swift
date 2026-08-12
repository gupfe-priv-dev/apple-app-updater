import AppKit

/// The Updates tab: one table of every pending update across every manager,
/// one console below it, one status bar under that.
///
/// The table is the whole point of the redesign — previously the only way to
/// see what was available was to read twelve separate console buffers. Now a
/// scan produces rows you can sort, select, and act on individually.
@MainActor
final class UpdatesViewController: NSViewController, CoordinatorHost {

    // MARK: state ────────────────────────────────────────────────────────

    let toolList: [Tool]
    var coordinator: Coordinator!
    /// Owner, for the things only the app delegate can do (modal permission
    /// gating, feature scripts).
    weak var appDelegate: AppDelegate?

    private var rows: [UpdateRow] = []
    /// Rows hidden by the exclude list, kept so a scan doesn't have to re-run
    /// when the user un-excludes something.
    private var excludedRows: [UpdateRow] = []
    private var currentMode: Coordinator.Mode = .scan
    private var activeToolIndex: Int?
    /// Tool indexes whose scan came back `.unknown` — managers that can't
    /// report what's pending (pipx, claude) and only reveal it by running.
    private var opaqueTools: [Int] = []

    // MARK: views ────────────────────────────────────────────────────────

    private let table = NSTableView()
    private let tableScroll = NSScrollView()
    private let console = ConsoleView()
    private let split = NSSplitView()
    private let statusLabel = NSTextField(labelWithString: "Ready.")
    private let countLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let emptyLabel = NSTextField(labelWithString: "")
    /// Every control that acts on the table lives in one strip directly beneath
    /// it, above the console — the long-standing macOS pattern of an action bar
    /// attached to a list (the +/−/⚙︎ bars under the tables in System Settings),
    /// and what the HIG means by controls that affect the window's contents.
    /// The window has no toolbar as a result; an empty one would just look
    /// broken.
    private var checkButton: NSButton!
    private var selectAllButton: NSButton!
    private var deselectAllButton: NSButton!
    private var updateButton: NSButton!
    private var stopButton: NSButton!
    private var actionBar: NSView!

    /// Elapsed-time heartbeat. Silent installers (a cask downloading, a
    /// `softwareupdate` that prints nothing for minutes) would otherwise look
    /// identical to a hang, so the status line counts up. Real streamed output
    /// wins — the heartbeat only fills actual silence.
    private var heartbeat: Timer?
    private var heartbeatLabel = ""
    private var heartbeatStart = Date()
    private var lastOutput = Date.distantPast

    init(tools: [Tool]) {
        self.toolList = tools
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: layout ───────────────────────────────────────────────────────

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        buildTable()
        buildStatusBar()

        // The action bar travels with the table, so it goes inside the split's
        // first pane rather than being a sibling — drag the divider and the
        // buttons stay glued to the rows they act on.
        actionBar = buildActionBar()
        let tablePane = NSView()
        tablePane.translatesAutoresizingMaskIntoConstraints = false
        tablePane.addSubview(tableScroll)
        tablePane.addSubview(actionBar)
        NSLayoutConstraint.activate([
            tableScroll.topAnchor.constraint(equalTo: tablePane.topAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: tablePane.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: tablePane.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: actionBar.topAnchor),
            actionBar.leadingAnchor.constraint(equalTo: tablePane.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: tablePane.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: tablePane.bottomAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: 44),
        ])

        split.translatesAutoresizingMaskIntoConstraints = false
        split.isVertical = false          // stacked: table on top, console below
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(tablePane)
        split.addArrangedSubview(console)
        // The table takes new space when the window grows; the console keeps
        // the height the user gave it.
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)

        let statusBar = buildStatusBarView()
        view.addSubview(split)
        view.addSubview(statusBar)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: view.topAnchor),
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    /// Set once the saved console height has been applied. Until then the
    /// split's resize callbacks are AppKit's own initial layout, not the user
    /// dragging — saving those would overwrite the stored height with whatever
    /// the first pass happened to produce (typically half the window).
    private var didRestoreSplit = false

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(exclusionsChanged),
            name: .excludedItemsChanged, object: nil)
    }

    /// Re-partition the scanned rows against the current hidden list, so
    /// hiding and unhiding both take effect without waiting for a re-scan.
    @objc private func exclusionsChanged() {
        let all = rows + excludedRows
        rows = all.filter { !Settings.isExcluded($0.toolID, $0.token) }
        excludedRows = all.filter { Settings.isExcluded($0.toolID, $0.token) }
        sortRows()
        table.reloadData()
        refreshCounts()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didRestoreSplit else { return }
        let total = split.bounds.height
        guard total > 200 else { return }
        let console = min(Settings.consoleHeight, total - 120)
        split.setPosition(total - console, ofDividerAt: 0)
        didRestoreSplit = true
    }

    /// Installed and Available used to be separate columns with a third,
    /// title-less column holding the arrow between them. That drew its own
    /// header dividers and read as a mistake. They're one Version column now —
    /// "2.0.0 → 2.7.0" in a single cell, which is how the eye reads it anyway.
    private enum Column: String, CaseIterable {
        case check, manager, package, version, status

        var title: String {
            switch self {
            case .check:   return ""
            case .manager: return "Manager"
            case .package: return "Package"
            case .version: return "Version"
            case .status:  return "Status"
            }
        }
        var width: CGFloat {
            switch self {
            case .check:   return 22
            case .manager: return 150
            case .package: return 220
            // Wide enough for a Chrome-length pair ("151.0.7922.109 → …138").
            // At 200 the target version — the thing you actually want to read —
            // was the part that got truncated away.
            case .version: return 260
            case .status:  return 190
            }
        }
    }

    private func buildTable() {
        table.usesAlternatingRowBackgroundColors = true
        // .fullWidth, not .inset: the inset style rounds and insets each row,
        // which is right for a sidebar but turns a mostly-empty data table into
        // a column of floating pills. Full width gives the classic stripes.
        table.style = .fullWidth
        table.rowHeight = 22
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(updateDoubleClickedRow)
        table.menu = rowMenu()
        table.usesAutomaticRowHeights = false

        for col in Column.allCases {
            let c = NSTableColumn(identifier: .init(col.rawValue))
            c.title = col.title
            c.width = col.width
            c.minWidth = col == .check ? 22 : 60
            // Package absorbs any extra window width; the rest hold their size,
            // so a wide window doesn't leave a dead gap mid-row.
            c.resizingMask = col == .package ? .autoresizingMask : .userResizingMask
            if col != .check {
                c.sortDescriptorPrototype = NSSortDescriptor(key: col.rawValue, ascending: true)
            }
            table.addTableColumn(c)
        }

        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .noBorder
        tableScroll.documentView = table

        // Shown over the table when there's nothing in it — an empty grid with
        // no explanation reads as broken.
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.stringValue = "Scanning…"
        tableScroll.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: tableScroll.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: tableScroll.topAnchor, constant: 60),
        ])
    }

    private func buildStatusBar() {
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right

    }

    private func barButton(_ title: String, _ symbol: String?, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .regular
        b.font = .systemFont(ofSize: 12)
        if let symbol = symbol {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            b.imagePosition = .imageLeading
        }
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func buildActionBar() -> NSView {
        checkButton       = barButton("Check for Updates", "arrow.clockwise", #selector(checkAction))
        selectAllButton   = barButton("Select All", nil, #selector(selectAllAction))
        deselectAllButton = barButton("Deselect All", nil, #selector(deselectAllAction))
        updateButton      = barButton("Update Selected", "arrow.down.circle.fill", #selector(updateAction))
        stopButton        = barButton("Stop", "stop.circle.fill", #selector(stopAction))
        stopButton.contentTintColor = .systemRed
        stopButton.isHidden = true        // only while a run is going

        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        // Hairline above, so the strip reads as attached to the table.
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [checkButton, selectAllButton, deselectAllButton,
                                        NSView(), stopButton, updateButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.setCustomSpacing(16, after: checkButton)
        stack.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(rule)
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: bar.topAnchor),
            rule.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    /// Paint the primary action: accent fill with white text when it can be
    /// pressed, plain when it can't. It's the only colour in the window's
    /// chrome, which is what makes it read as *the* action.
    private func styleUpdateButton(title: String, enabled: Bool) {
        updateButton.isEnabled = enabled
        updateButton.bezelColor = enabled ? .controlAccentColor : nil
        updateButton.contentTintColor = enabled ? .white : .disabledControlTextColor
        updateButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: enabled ? NSColor.white : NSColor.disabledControlTextColor,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ])
    }

    @objc private func checkAction() { scan() }
    @objc private func selectAllAction() { selectAll() }
    @objc private func deselectAllAction() { deselectAll() }
    @objc private func updateAction() { updateSelected() }

    @objc private func stopAction() {
        if stopArmed {
            forceKill()
            stopButton.isEnabled = false
        } else {
            abort()
            stopArmed = true
            stopButton.title = "Force Quit"
        }
    }
    private var stopArmed = false

    /// One place decides what's clickable, so a half-updated bar can't happen.
    private func refreshActionBar() {
        let busy = isBusy
        let selected = selectedCount
        checkButton.isEnabled = !busy
        // Only rows that are still pending can be selected, so that's what
        // decides whether Select All has anything left to do.
        let selectable = rows.filter { !$0.didSucceed }.count
        selectAllButton.isEnabled = !busy && selected < selectable
        deselectAllButton.isEnabled = !busy && selected > 0
        styleUpdateButton(title: selected > 0 ? "Update Selected (\(selected))" : "Update Selected",
                          enabled: !busy && selected > 0)
        stopButton.isHidden = !busy
        if !busy {
            stopArmed = false
            stopButton.title = "Stop"
            stopButton.isEnabled = true
        }
    }

    private func buildStatusBarView() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true

        let stack = NSStackView(views: [spinner, statusLabel, NSView(), countLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // hairline separator above the bar
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(rule)
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: bar.topAnchor),
            rule.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: rule.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        return bar
    }

    // MARK: actions (driven by the window toolbar) ───────────────────────

    var isBusy: Bool { coordinator?.isRunning ?? false }

    /// Number of rows currently checked — the toolbar's Update button label.
    var selectedCount: Int { rows.filter { $0.isSelected }.count }

    func scan() {
        guard !isBusy else { return }
        rows.removeAll()
        excludedRows.removeAll()
        opaqueTools.removeAll()
        table.reloadData()
        coordinator.scan()
    }

    func updateSelected() {
        guard !isBusy else { return }
        let chosen = rows.filter { $0.isSelected }
        guard !chosen.isEmpty else {
            NSSound.beep()
            setStatus("Nothing selected.")
            return
        }
        var selection: [Int: [UpdateItem]] = [:]
        for row in chosen { selection[row.toolIndex, default: []].append(row.item) }
        confirmAndInstall(selection, count: chosen.count)
    }

    /// No "are you sure?" here. The user has already said what they want twice —
    /// by checking rows and by pressing a button that names the count — and
    /// updating is neither destructive nor irreversible. Apple's guidance is to
    /// avoid alerts for common actions even when they *are* destructive, so a
    /// third confirmation would be pure friction. The genuinely consequential
    /// steps inside a run (quitting an app, removing a disabled cask) still ask.
    private func confirmAndInstall(_ selection: [Int: [UpdateItem]], count: Int) {
        // Cask installs write to /Applications, which macOS gates behind App
        // Management — check before we start rather than failing halfway.
        appDelegate?.requireAppManagement { [weak self] in
            self?.coordinator.install(selection: selection)
        }
    }

    func selectAll() { setAllSelected(true) }
    func deselectAll() { setAllSelected(false) }

    private func setAllSelected(_ on: Bool) {
        // Skip rows that already updated in this run — Select All shouldn't
        // resurrect finished work.
        for row in rows where !row.didSucceed { row.isSelected = on }
        table.reloadData()
        refreshCounts()
    }

    func abort() {
        guard isBusy else { return }
        coordinator.abort()
        console.writeNote("⚠ Sent SIGINT — waiting for the current task to clean up…")
        setStatus("Stopping…")
    }

    func forceKill() {
        coordinator?.forceKill()
        console.writeNote("⚠ Sent SIGTERM")
    }

    // MARK: row context menu ─────────────────────────────────────────────

    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    /// The row the context menu applies to — the clicked row, not the
    /// selection, matching Finder's behaviour.
    private var menuRow: UpdateRow? {
        let idx = table.clickedRow
        guard idx >= 0, idx < rows.count else { return nil }
        return rows[idx]
    }

    @objc private func updateJustThisRow() {
        guard let row = menuRow, !isBusy else { return }
        confirmAndInstall([row.toolIndex: [row.item]], count: 1)
    }

    @objc private func updateDoubleClickedRow() {
        guard table.clickedRow >= 0 else { return }
        updateJustThisRow()
    }

    @objc private func excludeRow() {
        guard let row = menuRow else { return }
        // Settings.exclude posts .excludedItemsChanged, which re-partitions the
        // rows — no need to move this one by hand.
        Settings.exclude(row.toolID, row.token)
        setStatus("Hiding \(row.name). Undo in Settings → Hidden.")
    }

    @objc private func clearRowFlag() {
        guard let row = menuRow else { return }
        History.clear(tool: row.toolID, token: row.token)
        row.status = ""
        row.isSelected = true
        table.reloadData()
        refreshCounts()
    }

    @objc private func copyRowToken() {
        guard let row = menuRow else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.token, forType: .string)
    }

    @objc private func disableRowsManager() {
        guard let row = menuRow else { return }
        Settings.setEnabled(row.toolID, false)
        rows.removeAll { $0.toolID == row.toolID }
        table.reloadData()
        refreshCounts()
        setStatus("\(row.managerLabel) disabled — re-enable in Settings.")
    }

    // MARK: CoordinatorHost ──────────────────────────────────────────────

    var tools: [Tool] { toolList }

    func runWillStart(_ mode: Coordinator.Mode) {
        currentMode = mode
        console.clear()
        console.startLogging()
        setBusy(true)
        if mode == .scan {
            rows.removeAll()
            excludedRows.removeAll()
            opaqueTools.removeAll()
            table.reloadData()
            emptyLabel.stringValue = "Scanning…"
        }
        refreshCounts()
    }

    func toolDidBegin(_ index: Int) {
        activeToolIndex = index
        console.writeHeader(toolList[index].title)
        setHeartbeat(currentMode == .scan
                     ? "Checking \(toolList[index].title)…"
                     : "Updating \(toolList[index].title)…")
    }

    func appendConsole(_ text: String) {
        lastOutput = Date()
        console.append(text)
    }

    func toolDidEndScan(_ index: Int, _ result: ScanResult) {
        let tool = toolList[index]
        switch result.state {
        case .hasUpdates:
            var hidden = 0
            for item in result.items {
                let row = UpdateRow(toolIndex: index, toolID: tool.id,
                                    managerLabel: tool.title, item: item,
                                    targetable: tool.supportsTargetedInstall)
                if Settings.isExcluded(tool.id, item.token) {
                    excludedRows.append(row)
                    hidden += 1
                } else {
                    rows.append(row)
                }
            }
            var note = "   \(result.items.count) update\(result.items.count == 1 ? "" : "s") available"
            if hidden > 0 { note += " (\(hidden) hidden)" }
            console.writeNote(note)
        case .upToDate:
            console.writeNote("   ✓ up to date")
        case .unknown:
            // Managers that can't answer "what's pending" without doing the
            // work (pipx, claude). They get a row of their own rather than
            // being folded into every run invisibly — an unparsed result must
            // never look like "nothing to do", and the checkbox count has to
            // match what actually runs.
            opaqueTools.append(index)
            // Package reads "(whole manager)" rather than repeating the manager
            // name — this row stands for everything the tool handles, and the
            // Status column carries the explanation.
            let row = UpdateRow(toolIndex: index, toolID: tool.id,
                                managerLabel: tool.title,
                                item: UpdateItem("(whole manager)", token: tool.id),
                                targetable: false)
            row.status = "⚠ " + (result.note ?? "couldn't check")
            row.isUnknown = true
            row.isSelected = false      // not known work — never ticked by default
            rows.append(row)
            console.writeNote("   ? \(result.note ?? "can't determine — will report when run")")
        case .unavailable:
            console.writeNote("   – not installed")
        }
        sortRows()
        table.reloadData()
        refreshCounts()
    }

    func toolDidEndInstall(_ index: Int, _ outcome: InstallOutcome, items: [UpdateItem]) {
        let failed = Set(outcome.failedItems)
        let toolID = toolList[index].id
        // Record the per-item verdict so the next scan can pre-flag whatever
        // failed. A section-level failure with no per-item detail taints every
        // item it was asked to update — better a false flag the user can clear
        // than a silent repeat next run.
        for item in items {
            let ok: Bool
            switch outcome.state {
            case .ok:                       ok = !failed.contains(item.token)
            case .failed:                   ok = false
            case .skipped, .unavailable:    continue   // nothing was attempted
            }
            History.record(tool: toolID, token: item.token, ok: ok, exitCode: ok ? 0 : 1)
            if let row = rows.first(where: { $0.toolID == toolID && $0.token == item.token }) {
                row.didSucceed = ok
                row.status = ok ? "✓ updated" : "⚠ failed"
                row.isSelected = false
            }
        }

        switch outcome.state {
        case .ok:
            console.writeNote(failed.isEmpty ? "   ✓ done"
                                             : "   ✓ done, \(failed.count) failed")
        case .failed:
            console.writeNote("   ✗ \(outcome.message ?? "failed")")
        case .skipped:
            console.writeNote("   ⊘ \(outcome.message ?? "skipped")")
        case .unavailable:
            console.writeNote("   – not installed")
        }
        table.reloadData()
        refreshCounts()
    }

    func toolSkipped(_ index: Int, reason: String) {
        // Not worth a console header of its own — one muted line keeps the
        // ordering visible without burying the tools that actually ran.
        console.writeNote("– \(toolList[index].title): \(reason)")
    }

    func ask(_ question: String) async -> Bool {
        await withCheckedContinuation { cont in
            let alert = NSAlert()
            alert.messageText = "Update All"
            alert.informativeText = question
            alert.addButton(withTitle: "Yes")
            alert.addButton(withTitle: "No")
            NSApp.activate(ignoringOtherApps: true)
            let answer = alert.runModal() == .alertFirstButtonReturn
            console.writeNote("   ? \(question) → \(answer ? "yes" : "no")")
            cont.resume(returning: answer)
        }
    }

    func runDidFinish(_ mode: Coordinator.Mode, aborted: Bool) {
        activeToolIndex = nil
        setBusy(false)
        sortRows()
        table.reloadData()
        refreshCounts()

        if aborted {
            setStatus("Stopped.")
            emptyLabel.stringValue = "Stopped before finding anything."
        } else if mode == .scan {
            // A manager that couldn't be checked isn't an available update, and
            // counting it as one is how "everything is current" ends up
            // reported as "1 update available".
            let n = rows.filter { !$0.isUnknown }.count
            let unknown = rows.filter { $0.isUnknown }.count
            let flagged = rows.filter { $0.flaggedFailure }.count
            var text: String
            if n == 0 {
                text = "Everything is up to date."
            } else if flagged > 0 {
                text = "\(n) available — \(flagged) flagged from a previous failure, left unchecked."
            } else {
                text = "\(n) update\(n == 1 ? "" : "s") available."
            }
            if unknown > 0 {
                text += "  \(unknown) manager\(unknown == 1 ? "" : "s") couldn't be checked."
            }
            setStatus(text)
            emptyLabel.stringValue = "Everything is up to date."
        } else {
            // Rows that updated are no longer pending work, so they leave the
            // table — it lists what's outstanding, not a history. They stayed
            // visible with their ✓ for the duration of the run, and the console
            // and log keep the record.
            let done = rows.filter { $0.didSucceed }.count
            rows.removeAll { $0.didSucceed }
            let stillPending = rows.count
            // Reload *after* the removal — the reload above ran before it, so
            // without this the table keeps showing the rows that just left.
            table.reloadData()
            refreshCounts()
            switch (done, stillPending) {
            case (0, _):
                setStatus("Nothing was updated.")
            case (_, 0):
                setStatus("Updated \(done) package\(done == 1 ? "" : "s").")
            default:
                setStatus("Updated \(done) — \(stillPending) still pending.")
            }
            emptyLabel.stringValue = "Everything is up to date."
        }
        emptyLabel.isHidden = !rows.isEmpty
        NotificationCenter.default.post(name: .updatesStateChanged, object: nil)
    }

    // MARK: status / busy ────────────────────────────────────────────────

    private func setBusy(_ busy: Bool) {
        if busy {
            spinner.startAnimation(nil)
            startHeartbeat()
        } else {
            spinner.stopAnimation(nil)
            stopHeartbeat()
        }
        emptyLabel.isHidden = !rows.isEmpty || busy
        refreshActionBar()
        NotificationCenter.default.post(name: .updatesStateChanged, object: nil)
    }

    private func setStatus(_ s: String) { statusLabel.stringValue = s }

    private func refreshCounts() {
        let sel = selectedCount
        countLabel.stringValue = rows.isEmpty ? ""
            : "\(sel) of \(rows.count) selected"
        refreshActionBar()
        NotificationCenter.default.post(name: .updatesStateChanged, object: nil)
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickHeartbeat() }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
        heartbeatLabel = ""
    }

    private func setHeartbeat(_ label: String) {
        heartbeatLabel = label
        heartbeatStart = Date()
        setStatus(label)
    }

    private func tickHeartbeat() {
        guard !heartbeatLabel.isEmpty else { return }
        // Real streamed output wins; only fill actual silence.
        guard Date().timeIntervalSince(lastOutput) > 2 else { return }
        let t = Int(Date().timeIntervalSince(heartbeatStart))
        setStatus(t >= 60 ? "\(heartbeatLabel) — \(t / 60)m \(t % 60)s"
                          : "\(heartbeatLabel) — \(t)s")
    }

    // MARK: sorting ──────────────────────────────────────────────────────

    /// Default order groups by manager (in tool order) then by name, so rows
    /// from the same manager stay together the way the run will execute them.
    private func sortRows() {
        if let d = table.sortDescriptors.first, let key = d.key,
           let col = Column(rawValue: key) {
            sortRows(by: col, ascending: d.ascending)
        } else {
            rows.sort {
                $0.toolIndex != $1.toolIndex ? $0.toolIndex < $1.toolIndex
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    private func sortRows(by col: Column, ascending: Bool) {
        func cmp(_ a: String, _ b: String) -> Bool {
            let r = a.localizedStandardCompare(b)
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }
        switch col {
        case .manager: rows.sort { $0.toolIndex == $1.toolIndex
                                      ? cmp($0.name, $1.name)
                                      : (ascending ? $0.toolIndex < $1.toolIndex
                                                   : $0.toolIndex > $1.toolIndex) }
        case .package: rows.sort { cmp($0.name, $1.name) }
        case .version: rows.sort { cmp($0.current, $1.current) }
        case .status:  rows.sort { cmp($0.status, $1.status) }
        case .check:   rows.sort { $0.isSelected == $1.isSelected
                                      ? cmp($0.name, $1.name)
                                      : (ascending ? !$0.isSelected : $0.isSelected) }
        }
    }

    /// "2.0.0 → 2.7.0" as one run of text: the old version muted, the arrow
    /// fainter still, the new version green — so the eye lands on what you're
    /// moving to. Monospaced digits keep the numbers from jittering row to row.
    private func versionText(_ row: UpdateRow) -> NSAttributedString {
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let monoBold = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let s = NSMutableAttributedString()
        // Nothing to show for a row that has no version information at all
        // (an opaque manager, or a package the CLI doesn't version).
        guard row.current != "—" || row.available != "—" else {
            return NSAttributedString(string: "—", attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor, .font: mono])
        }
        s.append(NSAttributedString(string: row.current, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor, .font: mono]))
        s.append(NSAttributedString(string: "  →  ", attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor, .font: mono]))
        s.append(NSAttributedString(string: row.available, attributes: [
            .foregroundColor: NSColor.systemGreen, .font: monoBold]))
        return s
    }

    // MARK: checkbox ─────────────────────────────────────────────────────

    @objc private func checkboxToggled(_ sender: NSButton) {
        let idx = sender.tag
        guard idx >= 0, idx < rows.count else { return }
        let row = rows[idx]
        row.isSelected = sender.state == .on

        // A manager that upgrades everything in one command can't spare an
        // unchecked row, so its rows move together — the checkbox tells the
        // truth about what will happen.
        if !row.targetable {
            for other in rows where other.toolID == row.toolID {
                other.isSelected = row.isSelected
            }
            table.reloadData()
        }
        refreshCounts()
    }
}

// MARK: - table data source / delegate ───────────────────────────────────

extension UpdatesViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView,
                   sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortRows()
        tableView.reloadData()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let colName = tableColumn?.identifier.rawValue,
              let col = Column(rawValue: colName), row < rows.count else { return nil }
        let item = rows[row]

        if col == .check {
            let cellID = NSUserInterfaceItemIdentifier("checkCell")
            let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSButton
                ?? { let b = NSButton(checkboxWithTitle: "", target: self,
                                      action: #selector(checkboxToggled(_:)))
                     b.identifier = cellID
                     return b }()
            cell.target = self
            cell.action = #selector(checkboxToggled(_:))
            cell.tag = row
            cell.state = item.isSelected ? .on : .off
            // A row that already updated in this run is a receipt, not pending
            // work — leave it visible but not re-checkable, so it can't be
            // queued again for something that's already done.
            cell.isEnabled = !isBusy && !item.didSucceed
            cell.toolTip = item.didSucceed
                ? "Already updated in this run — press Check for Updates to rescan."
                : (item.targetable ? nil
                   : "\(item.managerLabel) updates everything at once — these rows toggle together.")
            return cell
        }

        let cellID = NSUserInterfaceItemIdentifier("textCell")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTextField
            ?? { let f = NSTextField(labelWithString: "")
                 f.identifier = cellID
                 f.lineBreakMode = .byTruncatingTail
                 f.font = .systemFont(ofSize: 12)
                 return f }()

        cell.alignment = .natural
        cell.textColor = .labelColor
        cell.font = .systemFont(ofSize: 12)
        cell.toolTip = nil

        switch col {
        case .manager:
            cell.stringValue = item.managerLabel
            cell.textColor = .secondaryLabelColor
        case .package:
            cell.stringValue = item.name
            // The token is what the CLI takes; surface it when it isn't the
            // name (App Store numeric ids) rather than making the user guess.
            cell.toolTip = item.token == item.name ? item.name : "\(item.name)  (\(item.token))"
        case .version:
            cell.attributedStringValue = versionText(item)
            cell.toolTip = item.current == "—" ? nil : "\(item.current) → \(item.available)"
        case .status:
            cell.stringValue = item.status
            cell.textColor = item.statusColor
            cell.toolTip = item.status.isEmpty ? nil : item.status
        case .check:
            break
        }
        return cell
    }
}

// MARK: - context menu ───────────────────────────────────────────────────

extension UpdatesViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        guard let row = menuRow else { return }

        let update = NSMenuItem(title: "Update “\(row.name)” now",
                                action: #selector(updateJustThisRow), keyEquivalent: "")
        update.target = self
        update.isEnabled = !isBusy
        // Honest labelling: a non-targetable manager will upgrade its whole set.
        if !row.targetable {
            update.title = "Update all \(row.managerLabel) now"
        }
        menu.addItem(update)

        if !row.status.isEmpty && !row.didSucceed {
            let clear = NSMenuItem(title: "Clear failure flag",
                                   action: #selector(clearRowFlag), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }

        menu.addItem(.separator())

        let hide = NSMenuItem(title: "Hide “\(row.name)” from future scans",
                              action: #selector(excludeRow), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)

        let disable = NSMenuItem(title: "Disable \(row.managerLabel)",
                                 action: #selector(disableRowsManager), keyEquivalent: "")
        disable.target = self
        disable.isEnabled = !isBusy
        menu.addItem(disable)

        menu.addItem(.separator())
        let copy = NSMenuItem(title: "Copy package id",
                              action: #selector(copyRowToken), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
    }
}

// MARK: - split view ─────────────────────────────────────────────────────

extension UpdatesViewController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { 120 }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.bounds.height - 80
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Only once the restore has happened — see didRestoreSplit.
        guard didRestoreSplit, split.bounds.height > 0, console.bounds.height > 0 else { return }
        Settings.consoleHeight = console.bounds.height
    }
}

extension Notification.Name {
    /// Posted whenever the run state or the selection changes, so the window
    /// toolbar can re-evaluate its buttons without polling.
    static let updatesStateChanged = Notification.Name("UpdateAll.updatesStateChanged")
}
