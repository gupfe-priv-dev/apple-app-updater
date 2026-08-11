import AppKit

/// Owns the main window. The commands themselves live in the updates view's
/// action bar, directly under the table they act on, so there's no toolbar
/// state to manage here.
///
/// Settings live in their own ⌘, window (the macOS convention) rather than a
/// second tab: the main window is about the table and the console, and nothing
/// in Settings is content you'd flip back and forth to.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {

    let window: NSWindow
    let updates: UpdatesViewController
    let settings: SettingsViewController
    private var settingsWindow: NSWindow?

    init(tools: [Tool], appDelegate: AppDelegate) {
        updates = UpdatesViewController(tools: tools)
        settings = SettingsViewController(tools: tools, appDelegate: appDelegate)
        updates.appDelegate = appDelegate

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

        // No toolbar: every command that acts on the table lives in the action
        // bar directly beneath it. An empty unified toolbar would just be a
        // band of dead chrome.
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: actions ──────────────────────────────────────────────────────

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
            // The tab controller drives the size from each pane's
            // preferredContentSize, the way a native preferences window does —
            // so no frame autosave here, it would fight that.
            w.center()
            settingsWindow = w
        }
        settings.rebuild()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
