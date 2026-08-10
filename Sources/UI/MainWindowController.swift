import AppKit

/// Owns the main window and its toolbar. Toolbar buttons are the only controls
/// that act on a run, so this is also where "is a run in progress" gets
/// translated into enabled/disabled state.
///
/// Settings live in their own ⌘, window (the macOS convention) rather than a
/// second tab: the main window is about the table and the console, and nothing
/// in Settings is content you'd flip back and forth to.
@MainActor
final class MainWindowController: NSObject, NSToolbarDelegate, NSWindowDelegate {

    let window: NSWindow
    let updates: UpdatesViewController
    let settings: SettingsViewController
    private var settingsWindow: NSWindow?

    private var checkItem: NSToolbarItem?
    private var updateItem: NSToolbarItem?
    private var abortItem: NSToolbarItem?
    private var selectAllItem: NSToolbarItem?
    private var deselectItem: NSToolbarItem?
    /// Second Abort click escalates SIGINT → SIGTERM.
    private var abortArmed = false

    private enum ItemID {
        static let check     = NSToolbarItem.Identifier("check")
        static let update    = NSToolbarItem.Identifier("update")
        static let selectAll = NSToolbarItem.Identifier("selectAll")
        static let deselect  = NSToolbarItem.Identifier("deselect")
        static let abort     = NSToolbarItem.Identifier("abort")
    }

    init(tools: [Tool], appDelegate: AppDelegate) {
        updates = UpdatesViewController(tools: tools)
        settings = SettingsViewController(tools: tools)
        updates.appDelegate = appDelegate
        settings.appDelegate = appDelegate

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        super.init()

        window.title = "Update All"
        window.titlebarAppearsTransparent = false
        window.contentViewController = updates
        window.setContentSize(NSSize(width: 1020, height: 680))
        window.minSize = NSSize(width: 820, height: 480)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("UpdateAllMainWindow")

        let toolbar = NSToolbar(identifier: "com.gunnar.update-all.toolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshToolbar),
            name: .updatesStateChanged, object: nil)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshToolbar()
    }

    // MARK: toolbar ──────────────────────────────────────────────────────

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.check, ItemID.update, .flexibleSpace,
         ItemID.selectAll, ItemID.deselect, .space, ItemID.abort]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ItemID.check:
            let item = button(id, "Check for Updates", "arrow.clockwise", #selector(check))
            checkItem = item
            return item
        case ItemID.update:
            let item = button(id, "Update Selected", "arrow.down.circle.fill", #selector(update))
            item.isBordered = true
            updateItem = item
            return item
        case ItemID.selectAll:
            let item = button(id, "Select All", "checkmark.square", #selector(selectAll))
            selectAllItem = item
            return item
        case ItemID.deselect:
            let item = button(id, "Deselect All", "square", #selector(deselectAll))
            deselectItem = item
            return item
        case ItemID.abort:
            let item = button(id, "Stop", "stop.circle", #selector(abort))
            abortItem = item
            return item
        default:
            return nil
        }
    }

    private func button(_ id: NSToolbarItem.Identifier, _ label: String,
                        _ symbol: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = true
        // Without this, AppKit re-enables any item whose target responds to its
        // action on every event pass, undoing refreshToolbar() — Stop would sit
        // clickable with nothing to stop.
        item.autovalidates = false
        return item
    }

    /// Toolbar state is derived, never set by hand at call sites — one place
    /// decides what's clickable so a half-updated toolbar can't happen.
    @objc private func refreshToolbar() {
        let busy = updates.isBusy
        let selected = updates.selectedCount

        checkItem?.isEnabled = !busy
        selectAllItem?.isEnabled = !busy
        deselectItem?.isEnabled = !busy
        updateItem?.isEnabled = !busy && selected > 0
        updateItem?.label = selected > 0 ? "Update Selected (\(selected))" : "Update Selected"
        abortItem?.isEnabled = busy
        if !busy {
            abortArmed = false
            abortItem?.label = "Stop"
        }
    }

    // MARK: actions ──────────────────────────────────────────────────────

    @objc private func check() { updates.scan() }

    @objc private func update() { updates.updateSelected() }

    /// Settings, in a panel of its own. Reused across opens so it keeps its
    /// position, and refreshed each time since feature state (Touch ID,
    /// sudoers) can change outside the app.
    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Update All Settings"
            w.contentViewController = settings
            w.isReleasedWhenClosed = false      // we keep and reuse it
            // Size AFTER installing the controller: assigning a
            // contentViewController resizes the window to fit that view, and
            // a scroll view with no intrinsic size collapses the window to
            // almost nothing.
            w.setContentSize(NSSize(width: 560, height: 620))
            w.minSize = NSSize(width: 480, height: 400)
            w.setFrameAutosaveName("UpdateAllSettingsWindow")
            w.center()
            settingsWindow = w
        }
        settings.rebuild()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func selectAll() { updates.selectAll() }
    @objc private func deselectAll() { updates.deselectAll() }

    @objc private func abort() {
        if abortArmed {
            updates.forceKill()
            abortItem?.isEnabled = false
        } else {
            updates.abort()
            abortArmed = true
            abortItem?.label = "Force Quit"
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard updates.isBusy else { return true }
        let alert = NSAlert()
        alert.messageText = "A run is in progress."
        alert.informativeText = "Quitting now stops it partway through. Packages already "
            + "updated stay updated; the rest are left as they were."
        alert.addButton(withTitle: "Stop and Close")
        alert.addButton(withTitle: "Keep Running")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        updates.forceKill()
        return true
    }
}
