import AppKit
import Foundation

/// App lifecycle plus the parts of UpdateAll that talk to macOS rather than to
/// package managers: the App Management permission dance, the sudo/Touch ID
/// helper scripts, and the self-update check. The UI itself lives in Sources/UI.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private(set) var toolList: [Tool] = []
    private var main: MainWindowController!
    var coordinator: Coordinator!
    private var featuresMenu: NSMenu!

    var window: NSWindow? { main?.window }

    func applicationDidFinishLaunching(_ note: Notification) {
        AppPaths.ensure()
        buildToolList()

        main = MainWindowController(tools: toolList, appDelegate: self)
        coordinator = Coordinator(host: main.updates)
        main.updates.coordinator = coordinator
        // After `main` exists — the Settings menu item targets it.
        buildMenu()
        main.show()

        offerSudoersFixIfNeeded()
        // Ask for App Management up front rather than at the first failed cask:
        // the permission only takes effect after a relaunch, so discovering it
        // mid-run would mean losing the run.
        requireAppManagement { [weak self] in
            guard Settings.scanOnLaunch else { return }
            self?.main.updates.scan()
        }
        // background, throttled once-per-day GitHub release check
        checkSelfUpdateIfDue()
    }

    /// The tools, in display + execution order.
    private func buildToolList() {
        toolList = [
            RegistryTool(), BrewFormulaeTool(), BrewCasksTool(), MacPortsTool(),
            MasTool(), NpmTool(), GemTool(), RustupTool(), PipxTool(),
            ClaudeTool(), SparkleTool(), SoftwareUpdateTool(),
        ]
    }

    func applicationWillTerminate(_ notification: Notification) {
        // make sure the subprocess doesn't outlive the app
        coordinator?.forceKill()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Human-readable build string, shown in Settings.
    var versionSummary: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return v.map { "Version \($0)" } ?? "Development build"
    }

    // MARK: App Management permission ────────────────────────────────────

    /// State file recording that the user confirmed App Management for THIS
    /// build of UpdateAll. We pin it to the bundle's actual codesign CDHash
    /// (not CFBundleVersion — that doesn't change between rebuilds of the
    /// same commit) so any rebuild forces a fresh prompt, matching macOS's
    /// own rule that TCC is per-signature.
    private var appMgmtStateFile: String {
        NSHomeDirectory() + "/Library/Application Support/UpdateAll/app-management-acked"
    }
    private var _cachedBuildId: String?
    var currentBuildId: String {
        if let c = _cachedBuildId { return c }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-d", "--verbose=4", Bundle.main.bundlePath]
        let err = Pipe()
        task.standardError = err
        task.standardOutput = Pipe()
        var id = "unknown"
        do {
            try task.run()
            task.waitUntilExit()
            if let s = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                              encoding: .utf8) {
                for line in s.components(separatedBy: "\n") where line.hasPrefix("CDHash=") {
                    id = String(line.dropFirst("CDHash=".count))
                    break
                }
            }
        } catch {}
        _cachedBuildId = id
        return id
    }

    var appMgmtAcknowledged: Bool {
        guard let s = try? String(contentsOfFile: appMgmtStateFile, encoding: .utf8) else { return false }
        return s.trimmingCharacters(in: .whitespacesAndNewlines) == currentBuildId
    }

    private func markAppMgmtAcknowledged() {
        let dir = (appMgmtStateFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? currentBuildId.write(toFile: appMgmtStateFile, atomically: true, encoding: .utf8)
    }

    private var appMgmtActivationObserver: NSObjectProtocol?

    /// Hard gate: only call `proceed` if the user has confirmed App Management
    /// access for THIS build of UpdateAll. macOS App Management permission is
    /// per-code-signature and only takes effect on app restart — there's no
    /// reliable in-process probe (a Swift-side write to a user-owned app
    /// bundle slips past tccd because the gating is on privileged writes,
    /// which is what brew's installer does). So we ask the user once per
    /// build and persist the acknowledgement.
    func requireAppManagement(_ proceed: @escaping () -> Void) {
        if appMgmtAcknowledged {
            if let o = appMgmtActivationObserver {
                NotificationCenter.default.removeObserver(o)
                appMgmtActivationObserver = nil
            }
            proceed()
            return
        }
        let isUpgrade = FileManager.default.fileExists(atPath: appMgmtStateFile)
        let alert = NSAlert()
        let bundlePath = Bundle.main.bundlePath
        let body = """
        1. Click Open Settings — UpdateAll's path is also copied to your clipboard.
        2. In Privacy & Security → App Management:
           • Click the + (plus) button
           • Press Cmd+Shift+G in the file picker
           • Cmd+V to paste the path (\(bundlePath))
           • Click Open → toggle UpdateAll on
        3. macOS pops "Quit & Reopen" — click it. UpdateAll restarts with the new permission and runs the updates automatically.
        """
        if isUpgrade {
            alert.messageText = "New version of UpdateAll — refresh access?"
            alert.informativeText = "This build of UpdateAll (\(currentBuildId)) has a different code signature than the one you previously authorized, so macOS treats it as a new app. App Management permission must be re-granted and UpdateAll restarted before it can install or update casks.\n\n" + body
        } else {
            alert.messageText = "App Management permission required"
            alert.informativeText = "macOS gates writes to /Applications behind an explicit toggle. UpdateAll's cask installs and upgrades won't work until it's granted, and the permission only takes effect on the next launch.\n\n" + body
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "I've toggled it on — Quit & Reopen")
        alert.addButton(withTitle: "Quit")

        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Copy the bundle path so the file picker in App Management is
            // a Cmd+Shift+G → Cmd+V → Open instead of a manual navigate.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(Bundle.main.bundlePath, forType: .string)
            // Pre-write the acknowledgement now. Once the user toggles the
            // switch in System Settings macOS will pop its own "Quit & Reopen"
            // dialog; when they click that, the relaunched process will see
            // matching state and head straight into the run — no second modal
            // here. (If they instead click "Later" without granting, brew's
            // first cask install will fail and surface the error.)
            markAppMgmtAcknowledged()
            openAppManagementSettings()
            // If they come back via Cmd-Tab instead of macOS's relaunch
            // dialog (i.e. they Later'd it), re-check on activation — state
            // now matches so requireAppManagement falls through to proceed.
            if appMgmtActivationObserver == nil {
                appMgmtActivationObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    // posted on the main queue → safe to assert isolation
                    MainActor.assumeIsolated { self?.requireAppManagement(proceed) }
                }
            }
        case .alertSecondButtonReturn:
            // user asserts they already granted the toggle; persist the
            // build ID and relaunch so the new process inherits fresh TCC
            markAppMgmtAcknowledged()
            relaunchSelf()
        default:
            NSApp.terminate(nil)
        }
    }

    /// Relaunch UpdateAll cleanly so the new process picks up freshly-granted
    /// TCC permissions. We schedule an `open` in a detached shell and then
    /// terminate ourselves; the shell sleeps ~0.3s so our process is gone
    /// before macOS tries to launch the (single-instance) app.
    private func relaunchSelf() {
        let appPath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.3; open \"\(appPath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc func openAppManagementSettings() {
        // macOS Ventura+ deep link to the App Management pane.
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles")!
        NSWorkspace.shared.open(url)
    }

    // MARK: features.sh (Touch ID / sudoers) ─────────────────────────────

    var featuresScriptPath: String {
        Bundle.main.path(forResource: "features", ofType: "sh")!
    }

    /// Wrapper around features.sh `<feature> check` — returns "current",
    /// "outdated", "missing", or "" on script error.
    func featureCheck(_ feature: String) -> String {
        runFeatureScript(args: [feature, "check"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func featureStatus(_ feature: String) -> String {
        runFeatureScript(args: [feature, "status"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }

    @discardableResult
    func runFeatureScript(args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = [featuresScriptPath] + args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Sudoers v1 → v2 upgrade nudge. Soft prompt; either choice proceeds.
    func offerSudoersFixIfNeeded() {
        let sudoers = featureCheck("sudoers")
        guard sudoers == "outdated" || sudoers == "missing" else { return }
        let alert = NSAlert()
        alert.messageText = sudoers == "missing"
            ? "Skip the password prompt for system installer?"
            : "Permissions rule has been updated"
        alert.informativeText = sudoers == "missing"
            ? "UpdateAll can install a tiny sudoers rule so runs don't ask for your password during routine /usr/sbin/installer and /usr/sbin/softwareupdate calls. You'll be asked for your admin password once now."
            : "UpdateAll's sudoers rule grew coverage for MacPorts. Update now? (One admin prompt.)"
        alert.addButton(withTitle: sudoers == "missing" ? "Install" : "Update")
        alert.addButton(withTitle: "Skip")
        if alert.runModal() == .alertFirstButtonReturn {
            _ = runFeatureScript(args: ["sudoers", "enable"])
        }
    }

    @objc func toggleTouchID() {
        let action = (featureStatus("touchid") == "enabled") ? "disable" : "enable"
        let result = runFeatureScript(args: ["touchid", action]) ?? "(no output)"
        showAlert(title: "Touch ID for sudo", message: result)
    }

    @objc func toggleSudoers() {
        let action = (featureStatus("sudoers") == "enabled") ? "disable" : "enable"
        let result = runFeatureScript(args: ["sudoers", action]) ?? "(no output)"
        showAlert(title: "Passwordless sudo updates", message: result)
    }

    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    @objc func showLog() { ConsoleView.revealLogInFinder() }

    // MARK: menu ─────────────────────────────────────────────────────────

    func buildMenu() {
        let menuBar = NSMenu()

        // Application menu (first item — title shown as app name)
        let appItem = NSMenuItem()
        menuBar.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Update All",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        // ⌘, — where every macOS app keeps its settings.
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(MainWindowController.showSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self.main
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Update All",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu — without it, Cmd+C in the console and Cmd+F don't work.
        let editItem = NSMenuItem()
        editItem.title = "Edit"
        menuBar.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Features menu
        let featuresItem = NSMenuItem()
        featuresItem.title = "Features"
        menuBar.addItem(featuresItem)
        featuresMenu = NSMenu(title: "Features")
        featuresMenu.delegate = self
        featuresItem.submenu = featuresMenu

        NSApp.mainMenu = menuBar
    }

    /// Refresh the Features menu each time it opens so labels reflect state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === featuresMenu else { return }
        menu.removeAllItems()

        let tidOn = featureStatus("touchid") == "enabled"
        let tidItem = NSMenuItem(
            title: tidOn ? "Disable Touch ID for sudo" : "Enable Touch ID for sudo",
            action: #selector(toggleTouchID), keyEquivalent: "")
        tidItem.target = self
        menu.addItem(tidItem)

        let suOn = featureStatus("sudoers") == "enabled"
        let suItem = NSMenuItem(
            title: suOn ? "Disable passwordless sudo updates" : "Enable passwordless sudo updates",
            action: #selector(toggleSudoers), keyEquivalent: "")
        suItem.target = self
        menu.addItem(suItem)

        menu.addItem(NSMenuItem.separator())
        let appMgmtState = appMgmtAcknowledged
            ? "✓ acknowledged for build \(currentBuildId)"
            : "⚠ needs grant + restart"
        let appMgmtItem = NSMenuItem(
            title: "App Management permission… (\(appMgmtState))",
            action: #selector(openAppManagementSettings), keyEquivalent: "")
        appMgmtItem.target = self
        menu.addItem(appMgmtItem)

        menu.addItem(NSMenuItem.separator())
        let openLog = NSMenuItem(title: "Show log in Console",
                                 action: #selector(showLog), keyEquivalent: "l")
        openLog.target = self
        menu.addItem(openLog)
    }

    // MARK: declined casks ───────────────────────────────────────────────

    private var declinedCasksSheet: DeclinedCasksSheet?

    @objc func openDeclinedCasksSheet() {
        guard let parent = window else { return }
        let sheet = DeclinedCasksSheet()
        declinedCasksSheet = sheet   // retain
        sheet.present(over: parent)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.observeSheetClose(parent: parent)
        }
    }

    private func observeSheetClose(parent: NSWindow) {
        // poll: sheet is dismissed when parent has no attached sheets
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if parent.attachedSheet == nil {
                self?.declinedCasksSheet = nil
                self?.main?.settings.rebuild()
            } else {
                self?.observeSheetClose(parent: parent)
            }
        }
    }

    // MARK: self-update checker ──────────────────────────────────────────

    /// Cached "newer release available" info. nil = up to date or unknown.
    private var selfUpdateAvailable: (tag: String, url: String)?

    /// Throttled launch-time check; uses cached state when <24h old.
    private func checkSelfUpdateIfDue() {
        let now = Date()
        if let cached = SelfUpdateChecker.loadState() {
            if now.timeIntervalSince(cached.lastCheck) < 24 * 3600 {
                if let tag = cached.cachedTag,
                   SelfUpdateChecker.isNewer(remote: tag,
                                             current: SelfUpdateChecker.currentSemver()) {
                    selfUpdateAvailable = (tag, cached.cachedURL ?? "")
                    announceSelfUpdate()
                }
                return
            }
        }
        performSelfUpdateCheck(notify: false)
    }

    @objc func checkForAppUpdate() { performSelfUpdateCheck(notify: true) }

    @objc func openLatestRelease() {
        if let urlStr = selfUpdateAvailable?.url, let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(SelfUpdateChecker.releasesURL)
        }
    }

    /// A newer release exists — say so in the window subtitle rather than
    /// interrupting with a modal the user didn't ask for.
    private func announceSelfUpdate() {
        guard let avail = selfUpdateAvailable else {
            window?.subtitle = ""
            return
        }
        window?.subtitle = "Update available: \(avail.tag)"
    }

    private func performSelfUpdateCheck(notify: Bool) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = SelfUpdateChecker.fetchLatest()
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let rel):
                    let current = SelfUpdateChecker.currentSemver()
                    let isNew = SelfUpdateChecker.isNewer(remote: rel.tag_name, current: current)
                    SelfUpdateChecker.saveState(latestTag: rel.tag_name, htmlUrl: rel.html_url)
                    self.selfUpdateAvailable = isNew ? (rel.tag_name, rel.html_url) : nil
                    self.announceSelfUpdate()
                    if notify {
                        let alert = NSAlert()
                        if isNew {
                            alert.messageText = "Update available: \(rel.tag_name)"
                            alert.informativeText = "You're on \(current). Open the release page to download?"
                            alert.addButton(withTitle: "Open release page")
                            alert.addButton(withTitle: "Later")
                            if alert.runModal() == .alertFirstButtonReturn,
                               let url = URL(string: rel.html_url) {
                                NSWorkspace.shared.open(url)
                            }
                        } else {
                            alert.messageText = "Up to date"
                            alert.informativeText = "You're on \(current), the latest release."
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                        }
                    }
                case .failure(let err):
                    if notify {
                        let alert = NSAlert()
                        alert.messageText = "Couldn't check for app updates"
                        alert.informativeText = err.message
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                }
            }
        }
    }
}
