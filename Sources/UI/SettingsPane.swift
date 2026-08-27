import AppKit

/// One pane of the Settings window. Each pane owns a single section and builds
/// only its own controls, so switching panes costs one section's layout rather
/// than all of them.
///
/// Layout follows the standard macOS preferences form: a right-aligned label
/// column, controls in a left-aligned column beside it, and indented "↳"
/// sub-notes under a control that needs a caveat. NSGridView does the column
/// alignment, which is what keeps the labels lined up across groups.
@MainActor
final class SettingsPane: NSViewController {

    /// The sections, in toolbar order.
    enum Section: String, CaseIterable {
        case general, managers, system, hidden, maintenance

        var title: String {
            switch self {
            case .general:     return "General"
            case .managers:    return "Managers"
            case .system:      return "System Access"
            case .hidden:      return "Hidden"
            case .maintenance: return "Maintenance"
            }
        }
        /// SF Symbol for the toolbar item.
        var symbol: String {
            switch self {
            case .general:     return "gearshape"
            case .managers:    return "shippingbox"
            case .system:      return "lock.shield"
            case .hidden:      return "eye.slash"
            case .maintenance: return "wrench.and.screwdriver"
            }
        }
        /// Starting height, used before the pane has laid out. The real height
        /// is measured from the content once it exists (see rebuild) — a
        /// hand-maintained number here goes stale the moment a row is added,
        /// which is exactly how System Access ended up clipping its last row.
        var preferredHeight: CGFloat {
            switch self {
            case .general:     return 190
            case .managers:    return 400
            case .system:      return 250
            case .hidden:      return 150
            case .maintenance: return 230
            }
        }
    }

    /// One width for every pane, so only the height changes between them.
    static let paneWidth: CGFloat = 620
    /// Width of the right-aligned label column, shared by all panes.
    static let labelColumnWidth: CGFloat = 170

    let section: Section
    let toolList: [Tool]
    weak var appDelegate: AppDelegate?

    /// Flipped so the scroll view's origin is top-left — an unflipped document
    /// view opens scrolled to the *bottom*, which reads as an empty pane.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private let content = NSStackView()
    private var hiddenList: NSStackView!
    /// The small system spinner, shown while availability is being re-checked.
    private let spinner: NSProgressIndicator = {
        let s = NSProgressIndicator()
        s.style = .spinning
        s.controlSize = .small
        // isHidden, not just isDisplayedWhenStopped: an invisible-but-present
        // spinner still occupies its width in the stack, which pushed the
        // Managers label 21pt left of every other pane's label column.
        // NSStackView reclaims the space of a genuinely hidden view.
        s.isDisplayedWhenStopped = false
        s.isHidden = true
        s.translatesAutoresizingMaskIntoConstraints = false
        s.widthAnchor.constraint(equalToConstant: 14).isActive = true
        s.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return s
    }()

    init(section: Section, tools: [Tool]) {
        self.section = section
        self.toolList = tools
        super.init(nibName: nil, bundle: nil)
        title = section.title
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 20
        content.edgeInsets = NSEdgeInsets(top: 22, left: 20, bottom: 28, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = container

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])

        // Every pane asks for the SAME width, so switching panes changes only
        // the height. Without this each pane's width followed its own content —
        // Managers is wide because of its long labels, System Access isn't — and
        // the window resized sideways as you moved between them.
        //
        // Weak (500) so it's a preference, not a rule: the window still wins
        // when you resize it. What used to drag the window back to this number
        // was the preferredContentSize assignment on every rebuild, not this
        // constraint — that's gone, so the two coexist.
        let w = scroll.widthAnchor.constraint(equalToConstant: Self.paneWidth)
        let h = scroll.heightAnchor.constraint(equalToConstant: section.preferredHeight)
        w.priority = NSLayoutConstraint.Priority(500)
        h.priority = NSLayoutConstraint.Priority(500)
        NSLayoutConstraint.activate([w, h])

        view = scroll
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        rebuild()
        // Only when we've genuinely never checked — normally the launch scan
        // has already filled the cache, so opening this pane is instant.
        if section == .managers, toolList.contains(where: { ToolAvailability.cached($0) == nil }) {
            refreshAvailability()
        }
    }

    /// Rebuilt on every appearance — feature state (Touch ID, sudoers) can
    /// change outside the app, and the lists change from the updates table.
    func rebuild() {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let grid: NSGridView
        switch section {
        case .general:     grid = generalGrid()
        case .managers:    grid = managersGrid()
        case .system:      grid = systemGrid()
        case .hidden:      grid = hiddenGrid()
        case .maintenance: grid = maintenanceGrid()
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        // One fixed label column across every pane. Sized to content, each pane
        // was only as wide as its own longest label, so the controls started at
        // a different x in each — "Package Managers:" is shorter than
        // "Remembered Failures:", so Managers sat noticeably further left. A
        // shared width puts the label/control boundary in the same place
        // everywhere, which is what makes the panes look like one window.
        grid.column(at: 0).width = Self.labelColumnWidth
        grid.rowSpacing = 16
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(grid)
    }

    /// How tall this pane's content actually is, so no row is clipped and every
    /// pane keeps the same breathing space under its last control.
    ///
    /// Deliberately a *question*, not an action. Assigning preferredContentSize
    /// here made AppKit resize the window on every rebuild — so toggling a
    /// checkbox snapped the window back to its fitted size, which looked like the
    /// pane jumping, and a manually resized Settings window sprang back the
    /// moment you clicked anything. The window controller asks for this when it
    /// switches panes; nothing else moves the window.
    var fittedHeight: CGFloat {
        // Measure at the width the pane will actually be shown at. Measured at
        // whatever width it happens to have, fittingSize under-reports and the
        // last row gets clipped — which is how the Downloads row ended up half
        // outside the window.
        content.setFrameSize(NSSize(width: Self.paneWidth, height: content.frame.height))
        content.layoutSubtreeIfNeeded()
        return max(content.fittingSize.height, section.preferredHeight)
    }

    // MARK: sections ─────────────────────────────────────────────────────

    /// Pairs of (floor, window) rather than two free-form number fields: the
    /// two values only mean anything together, and a field would happily accept
    /// "0", which disables the guard while looking like it's on.
    private static let stallPresets: [(kbps: Int, seconds: Int, title: String)] = [
        (50, 30,  "after 30 seconds below 50 KB/s"),
        (50, 60,  "after 1 minute below 50 KB/s"),
        (50, 180, "after 3 minutes below 50 KB/s"),
        (10, 300, "after 5 minutes below 10 KB/s"),
    ]

    /// Held so the checkbox can grey it out; the window owns the actual view.
    private weak var stallPreset: NSPopUpButton?

    private func stallPopup() -> NSPopUpButton {
        let pop = NSPopUpButton(frame: .zero, pullsDown: false)
        pop.addItems(withTitles: Self.stallPresets.map(\.title))
        let current = (Settings.downloadSpeedFloorKBps, Settings.downloadStallSeconds)
        pop.selectItem(at: Self.stallPresets.firstIndex { ($0.kbps, $0.seconds) == current } ?? 1)
        pop.target = self
        pop.action = #selector(stallPresetChanged(_:))
        pop.isEnabled = Settings.downloadGuardEnabled
        stallPreset = pop
        return pop
    }

    private func generalGrid() -> NSGridView {
        NSGridView(views: [
            row("Launch Behavior:", [
                check("Check for updates when UpdateAll opens",
                      on: Settings.scanOnLaunch, action: #selector(scanOnLaunchToggled(_:))),
                note("Off leaves the table empty until you press Check for Updates"),
            ]),
            row("Downloads:", [
                check("Give up on a download that stalls",
                      on: Settings.downloadGuardEnabled,
                      action: #selector(downloadGuardToggled(_:))),
                stallPopup(),
                note("A dead download host has no alternate mirror to fall back to"),
                note("Without a limit it holds up every package queued behind it"),
            ]),
        ])
    }

    private func managersGrid() -> NSGridView {
        // Availability is *read*, never computed, here: `cached` returns nil
        // rather than shelling out, so opening this pane costs nothing. The
        // refresh happens in the background (see refreshAvailability).
        var controls: [NSView] = []
        for tool in toolList {
            let box = check(tool.title, on: Settings.isEnabled(tool.id),
                            action: #selector(managerToggled(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(tool.id)
            controls.append(box)
            // A checkbox for a missing tool still works — it just won't do
            // anything until the tool exists — so this is a note, not a
            // disabled control.
            if ToolAvailability.cached(tool) == false {
                controls.append(note("Not installed on this Mac"))
            }
        }

        let label = NSTextField(labelWithString: "Package Managers:")
        label.font = .systemFont(ofSize: 13)
        label.alignment = .right
        let heading = NSStackView(views: [label, spinner])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 6

        let column = NSStackView(views: controls)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6

        return NSGridView(views: [
            [heading, column],
            row("", [note("A disabled manager is skipped entirely — not scanned, not updated.")]),
        ])
    }

    /// Re-check what's installed, in the background, with the spinner running.
    /// Deliberately not called on every appearance — it's a dozen subprocess
    /// spawns, and the answer only changes when something is installed or
    /// removed. It runs when the list has never been checked, and after a
    /// manager is toggled.
    private func refreshAvailability() {
        guard section == .managers else { return }
        spinner.isHidden = false
        spinner.startAnimation(nil)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            await ToolAvailability.refresh(self.toolList)
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            self.rebuild()
        }
    }

    private func systemGrid() -> NSGridView {
        let touchID = appDelegate?.featureCheck("touchid") == "current"
        let sudoers = appDelegate?.featureCheck("sudoers") ?? ""
        let appMgmt = appDelegate?.appMgmtAcknowledged ?? false
        let signing = appDelegate?.featureCheck("codesign") ?? ""

        return NSGridView(views: [
            row("Touch ID for sudo:", [
                statusLine(touchID ? .good : .warn,
                           touchID ? "Enabled" : "Off — sudo asks for your password",
                           button: touchID ? "Disable" : "Enable",
                           action: #selector(toggleTouchID)),
            ]),
            row("Passwordless sudo:", [
                statusLine(sudoers == "current" ? .good : (sudoers == "outdated" ? .stale : .warn),
                           sudoers == "current" ? "Rule installed and current"
                         : sudoers == "outdated" ? "Rule is out of date"
                                                 : "Not installed — runs will prompt",
                           button: sudoers == "current" ? "Remove" : "Install",
                           action: #selector(toggleSudoers)),
                note("Covers /usr/sbin/installer and /usr/sbin/softwareupdate only"),
            ]),
            row("Code Signing:", [
                statusLine(signing == "current" ? .good : .warn,
                           signing == "current" ? "Stable identity — grants survive rebuilds"
                                                : "Ad-hoc — every rebuild needs App Management again",
                           button: signing == "current" ? "Remove" : "Set Up",
                           action: #selector(toggleCodesign)),
                note(signing == "current"
                     ? "Back it up: ./signing-identity.sh export identity.b64"
                     : "Creates a self-signed certificate so macOS sees each build as the same app"),
            ]),
            row("App Management:", [
                statusLine(appMgmt ? .good : .warn,
                           appMgmt ? "Granted for this build"
                                   : "Required before casks can be upgraded",
                           button: "Open Settings",
                           action: #selector(openAppManagement)),
                note("macOS ties this to the app's signature — a rebuild needs it re-granted"),
            ]),
        ])
    }

    private func hiddenGrid() -> NSGridView {
        hiddenList = NSStackView()
        hiddenList.orientation = .vertical
        hiddenList.alignment = .leading
        hiddenList.spacing = 4
        rebuildHiddenList()

        return NSGridView(views: [
            row("Hidden Packages:", [
                hiddenList,
                note("Right-click a row in the updates table to hide it"),
            ]),
        ])
    }

    private func rebuildHiddenList() {
        hiddenList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let entries = Settings.excludedItems.sorted()
        if entries.isEmpty {
            // Plain, not a "↳" note — that prefix marks a caveat *under* a
            // control, and here this is the content itself.
            let empty = NSTextField(labelWithString: "Nothing hidden")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            hiddenList.addArrangedSubview(empty)
            return
        }
        for entry in entries {
            let label = NSTextField(labelWithString: entry)
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

            let remove = NSButton(title: "Unhide", target: self, action: #selector(unhide(_:)))
            remove.bezelStyle = .rounded
            remove.controlSize = .small
            remove.identifier = NSUserInterfaceItemIdentifier(entry)

            let row = NSStackView(views: [remove, label])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            hiddenList.addArrangedSubview(row)
        }
    }

    private func maintenanceGrid() -> NSGridView {
        let failures = History.failureCount
        let declined = Registry.declinedCasks().count

        return NSGridView(views: [
            row("Remembered Failures:", [
                statusLine(failures == 0 ? .good : .stale,
                           failures == 0 ? "No package is currently flagged"
                                         : "\(failures) package\(failures == 1 ? "" : "s") flagged",
                           button: "Clear All", action: #selector(clearHistory),
                           enabled: failures > 0),
                note("A flagged package arrives unchecked after its update failed"),
            ]),
            row("Declined Casks:", [
                statusLine(.neutral,
                           declined == 0 ? "None"
                                         : "\(declined) cask\(declined == 1 ? "" : "s") won't be re-offered",
                           button: "Manage…", action: #selector(openDeclinedCasks),
                           enabled: declined > 0),
            ]),
            row("Run Log:", [
                statusLine(.neutral, "The last four runs",
                           button: "Open", action: #selector(openLog)),
                note("~/Library/Logs/update-all.log"),
            ]),
            row("UpdateAll Itself:", updateSelfControls()),
        ])
    }

    /// Two lines: what's running, then whether anything newer exists. Cramming
    /// both onto one line made a long string that had to be read to the end
    /// before you learned the answer.
    private func updateSelfControls() -> [NSView] {
        let current = NSTextField(labelWithString: appDelegate?.versionSummary ?? "")
        current.font = .systemFont(ofSize: 12)

        if let problem = lastCheckProblem {
            return [current,
                    statusLine(.warn, "Couldn't check",
                               button: "Try Again", action: #selector(checkAppUpdate)),
                    note(problem)]
        }
        guard let tag = appDelegate?.updateAvailableTag else {
            return [current,
                    statusLine(.good, "Up to date",
                               button: "Check for Updates", action: #selector(checkAppUpdate))]
        }
        return [current,
                statusLine(.stale, "\(tag) available",
                           button: "Update and Restart", action: #selector(installAppUpdate))]
    }

    // MARK: building blocks ──────────────────────────────────────────────

    /// One form row: right-aligned label, then a stacked column of controls.
    private func row(_ label: String, _ controls: [NSView]) -> [NSView] {
        let name = NSTextField(labelWithString: label)
        name.font = .systemFont(ofSize: 13)
        name.alignment = .right
        name.setContentHuggingPriority(.required, for: .horizontal)

        let column = NSStackView(views: controls)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        return [name, column]
    }

    private func check(_ title: String, on: Bool, action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.state = on ? .on : .off
        return b
    }

    /// The indented "↳ caveat" line the system settings panes use.
    private func note(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: "↳ " + text)
        f.font = .systemFont(ofSize: 11)
        f.textColor = .secondaryLabelColor
        return f
    }

    private enum FeatureState { case good, warn, stale, neutral
        var symbol: String {
            switch self {
            case .good:    return "checkmark.circle.fill"
            case .warn:    return "exclamationmark.triangle.fill"
            case .stale:   return "arrow.triangle.2.circlepath"
            case .neutral: return "info.circle"
            }
        }
        var tint: NSColor {
            switch self {
            case .good:    return .systemGreen
            case .warn:    return .systemOrange
            case .stale:   return .systemYellow
            case .neutral: return .tertiaryLabelColor
            }
        }
    }

    /// Status dot + text + action button, on one line.
    ///
    /// `.neutral` rows get no icon at all: a grey glyph next to a row carries
    /// no information and reads as a button that doesn't respond. An icon here
    /// means there is actually something to report.
    private func statusLine(_ state: FeatureState, _ text: String,
                            button: String, action: Selector,
                            enabled: Bool = true) -> NSView {
        var views: [NSView] = []
        if state != .neutral {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
            icon.contentTintColor = state.tint
            views.append(icon)
        }

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail

        let btn = NSButton(title: button, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.isEnabled = enabled
        btn.setContentHuggingPriority(.required, for: .horizontal)

        views.append(label)
        views.append(btn)
        let line = NSStackView(views: views)
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 6
        return line
    }

    // MARK: actions ──────────────────────────────────────────────────────

    @objc private func scanOnLaunchToggled(_ sender: NSButton) {
        Settings.scanOnLaunch = sender.state == .on
    }

    @objc private func downloadGuardToggled(_ sender: NSButton) {
        Settings.downloadGuardEnabled = sender.state == .on
        stallPreset?.isEnabled = sender.state == .on
    }

    @objc private func stallPresetChanged(_ sender: NSPopUpButton) {
        let preset = Self.stallPresets[sender.indexOfSelectedItem]
        Settings.downloadSpeedFloorKBps = preset.kbps
        Settings.downloadStallSeconds   = preset.seconds
    }

    @objc private func managerToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        Settings.setEnabled(id, sender.state == .on)
        // Enabling a manager is the moment its "is it installed" note matters,
        // so re-check here — in the background, where it costs nothing visible.
        refreshAvailability()
    }

    @objc private func toggleTouchID() {
        appDelegate?.toggleTouchID()
        rebuild()
    }

    @objc private func toggleCodesign() {
        appDelegate?.toggleCodesign()
        rebuild()
    }

    @objc private func toggleSudoers() {
        appDelegate?.toggleSudoers()
        rebuild()
    }

    @objc private func openAppManagement() {
        appDelegate?.openAppManagementSettings()
    }

    @objc private func unhide(_ sender: NSButton) {
        guard let entry = sender.identifier?.rawValue else { return }
        Settings.unexclude(entry)
        rebuildHiddenList()
    }

    @objc private func clearHistory() {
        History.clearAll()
        rebuild()
    }

    @objc private func openDeclinedCasks() {
        appDelegate?.openDeclinedCasksSheet()
    }

    @objc private func openLog() {
        ConsoleView.revealLogInFinder()
    }

    @objc private func checkAppUpdate() {
        appDelegate?.checkForAppUpdate { [weak self] problem in
            // Keep the reason: discarding it made a failed check redraw as
            // "Up to date", which is the same lie the package scans are careful
            // not to tell. GitHub's unauthenticated API allows 60 requests an
            // hour, so "couldn't check" is a real state, not a hypothetical.
            self?.lastCheckProblem = problem
            self?.rebuild()
        }
    }

    /// Why the last check failed, if it did. Cleared by a successful one.
    private var lastCheckProblem: String?

    @objc private func installAppUpdate() {
        appDelegate?.installLatestRelease()
    }
}
