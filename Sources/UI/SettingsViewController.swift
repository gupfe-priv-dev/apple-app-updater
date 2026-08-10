import AppKit

/// The Settings tab — everything that used to live in the sidebar's SETTINGS
/// group, plus the two lists the new table needs a home for (hidden packages
/// and remembered failures).
@MainActor
final class SettingsViewController: NSViewController {

    let toolList: [Tool]
    weak var appDelegate: AppDelegate?

    /// Flipped so the scroll view's origin is top-left. An unflipped document
    /// view opens scrolled to the *bottom* of the stack, which reads as an
    /// empty pane when the content is taller than the window.
    private final class FlippedStack: NSStackView {
        override var isFlipped: Bool { true }
    }

    private let content = FlippedStack()
    private var managerBoxes: [(id: String, box: NSButton)] = []
    private var hiddenList: NSStackView!

    init(tools: [Tool]) {
        self.toolList = tools
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        content.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = content
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        view = scroll
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        rebuild()
    }

    /// Rebuilt on every appearance — feature state (Touch ID, sudoers) can
    /// change outside the app, and the lists change from the Updates tab.
    func rebuild() {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        wrappingLabels.removeAll()
        for card in [managersCard(), systemCard(), hiddenCard(), maintenanceCard()] {
            content.addArrangedSubview(card)
            // Width is pinned only once the card is actually in the hierarchy —
            // a constraint between views with no common ancestor yet throws.
            card.widthAnchor.constraint(equalTo: content.widthAnchor,
                                        constant: -44).isActive = true
        }
        // Wrapping labels need an explicit wrap width; they're several levels
        // deep inside their box, so give them the number rather than a
        // constraint across the hierarchy.
        applyWrapWidth()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyWrapWidth()
    }

    /// Every caption wraps at the card's inner width.
    private func applyWrapWidth() {
        let width = max(240, content.bounds.width - 90)
        for label in wrappingLabels {
            label.preferredMaxLayoutWidth = width
        }
    }

    private var wrappingLabels: [NSTextField] = []

    // MARK: cards ────────────────────────────────────────────────────────

    private func managersCard() -> NSView {
        managerBoxes.removeAll()
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .width
        body.spacing = 6

        body.addArrangedSubview(caption(
            "A disabled manager is skipped entirely — not scanned, not updated."))

        for tool in toolList {
            let box = NSButton(checkboxWithTitle: tool.title, target: self,
                               action: #selector(managerToggled(_:)))
            box.state = Settings.isEnabled(tool.id) ? .on : .off
            box.identifier = NSUserInterfaceItemIdentifier(tool.id)
            // Greyed-out label for a manager that isn't installed at all; the
            // checkbox still works so it takes effect if it's installed later.
            if !tool.isAvailable() {
                box.attributedTitle = NSAttributedString(
                    string: tool.title + "  (not installed)",
                    attributes: [.foregroundColor: NSColor.tertiaryLabelColor,
                                 .font: NSFont.systemFont(ofSize: 13)])
            }
            managerBoxes.append((tool.id, box))
            body.addArrangedSubview(box)
        }
        return card("Package managers", body)
    }

    private func systemCard() -> NSView {
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .width
        body.spacing = 8

        body.addArrangedSubview(caption(
            "macOS gates the two things a system updater has to do: writing to "
            + "/Applications, and running the installer as root."))

        let touchID = appDelegate?.featureCheck("touchid") == "current"
        body.addArrangedSubview(featureRow(
            title: "Touch ID for sudo",
            state: touchID ? .good : .warn,
            detail: touchID ? "Enabled" : "Off — sudo asks for your password",
            buttonTitle: touchID ? "Disable" : "Enable",
            action: #selector(toggleTouchID)))

        let sudoers = appDelegate?.featureCheck("sudoers") ?? ""
        body.addArrangedSubview(featureRow(
            title: "Passwordless installer / softwareupdate",
            state: sudoers == "current" ? .good : (sudoers == "outdated" ? .stale : .warn),
            detail: sudoers == "current" ? "Rule installed and current"
                  : sudoers == "outdated" ? "Rule is out of date"
                                          : "Not installed — runs will prompt",
            buttonTitle: sudoers == "current" ? "Remove" : "Install",
            action: #selector(toggleSudoers)))

        let appMgmt = appDelegate?.appMgmtAcknowledged ?? false
        body.addArrangedSubview(featureRow(
            title: "App Management permission",
            state: appMgmt ? .good : .warn,
            detail: appMgmt ? "Granted for this build"
                            : "Required before casks can be upgraded",
            buttonTitle: "Open Settings",
            action: #selector(openAppManagement)))

        return card("System access", body)
    }

    private func hiddenCard() -> NSView {
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .width
        body.spacing = 6

        body.addArrangedSubview(caption(
            "Packages hidden from the updates table — right-click a row to add one. "
            + "Usually something whose installer prompts and stalls a run."))

        hiddenList = NSStackView()
        hiddenList.orientation = .vertical
        hiddenList.alignment = .leading
        hiddenList.spacing = 2
        rebuildHiddenList()
        body.addArrangedSubview(hiddenList)

        return card("Hidden packages", body)
    }

    private func rebuildHiddenList() {
        hiddenList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let entries = Settings.excludedItems.sorted()
        if entries.isEmpty {
            hiddenList.addArrangedSubview(caption("Nothing hidden."))
            return
        }
        for entry in entries {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8

            let label = NSTextField(labelWithString: entry)
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .labelColor

            let remove = NSButton(title: "Unhide", target: self, action: #selector(unhide(_:)))
            remove.bezelStyle = .inline
            remove.controlSize = .small
            remove.identifier = NSUserInterfaceItemIdentifier(entry)

            row.addArrangedSubview(remove)
            row.addArrangedSubview(label)
            hiddenList.addArrangedSubview(row)
        }
    }

    private func maintenanceCard() -> NSView {
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .width
        body.spacing = 8

        let failures = History.failureCount
        body.addArrangedSubview(featureRow(
            title: "Remembered failures",
            state: failures == 0 ? .good : .stale,
            detail: failures == 0
                ? "No package is currently flagged"
                : "\(failures) package\(failures == 1 ? "" : "s") arrive unchecked after failing",
            buttonTitle: "Clear all",
            action: #selector(clearHistory),
            buttonEnabled: failures > 0))

        let declined = Registry.declinedCasks().count
        body.addArrangedSubview(featureRow(
            title: "Declined casks",
            state: .neutral,
            detail: declined == 0 ? "None" : "\(declined) cask\(declined == 1 ? "" : "s") won't be re-offered",
            buttonTitle: "Manage…",
            action: #selector(openDeclinedCasks),
            buttonEnabled: declined > 0))

        body.addArrangedSubview(featureRow(
            title: "Run log",
            state: .neutral,
            detail: "The last four runs, in ~/Library/Logs/update-all.log",
            buttonTitle: "Open",
            action: #selector(openLog)))

        body.addArrangedSubview(featureRow(
            title: "UpdateAll itself",
            state: .neutral,
            detail: appDelegate?.versionSummary ?? "",
            buttonTitle: "Check for updates",
            action: #selector(checkAppUpdate)))

        return card("Maintenance", body)
    }

    // MARK: building blocks ──────────────────────────────────────────────

    private enum FeatureState { case good, warn, stale, neutral
        var symbol: String {
            switch self {
            case .good:    return "checkmark.circle.fill"
            case .warn:    return "exclamationmark.triangle.fill"
            case .stale:   return "arrow.triangle.2.circlepath"
            case .neutral: return "circle"
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

    private func featureRow(title: String, state: FeatureState, detail: String,
                            buttonTitle: String, action: Selector,
                            buttonEnabled: Bool = true) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        icon.contentTintColor = state.tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13)
        let sub = NSTextField(labelWithString: detail)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [name, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let button = NSButton(title: buttonTitle, target: self, action: action)
        button.controlSize = .regular
        button.isEnabled = buttonEnabled
        button.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [icon, text, NSView(), button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func caption(_ s: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = .systemFont(ofSize: 11)
        f.textColor = .secondaryLabelColor
        f.translatesAutoresizingMaskIntoConstraints = false
        wrappingLabels.append(f)
        return f
    }

    /// A titled group box — the macOS equivalent of CliSync's settings cards.
    /// Width is pinned by the caller, once the box is in the hierarchy.
    private func card(_ title: String, _ body: NSView) -> NSView {
        let box = NSBox()
        box.title = title
        box.titlePosition = .atTop
        box.boxType = .primary
        box.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        box.contentView = body
        return box
    }

    // MARK: actions ──────────────────────────────────────────────────────

    @objc private func managerToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        Settings.setEnabled(id, sender.state == .on)
    }

    @objc private func toggleTouchID() {
        appDelegate?.toggleTouchID()
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
        appDelegate?.checkForAppUpdate()
    }
}
