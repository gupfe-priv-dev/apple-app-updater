import AppKit
import Foundation

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSToolbarDelegate, CoordinatorHost {
    var window: NSWindow!
    var textView: NSTextView!
    var closeButton: NSButton!
    var abortButton: NSButton!
    var sectionsStack: NSStackView!
    var featuresStack: NSStackView!
    var consoleScroll: NSScrollView!
    var successView: NSView!
    var rerunButton: NSButton!
    var dashboardView: NSView!
    private weak var dashboardIcon: NSImageView?
    private weak var dashboardTitle: NSTextField?
    private weak var dashboardSubtitle: NSTextField?
    private weak var dashboardProgress: NSTextField?
    private weak var dashboardUpdatesList: NSStackView?
    private var toolbarRefreshItem: NSToolbarItem?
    private var toolbarRerunItem:   NSToolbarItem?
    private var toolbarAbortItem:   NSToolbarItem?
    // The ordered tool list defines both the run sequence and the sidebar rows.
    var toolList: [Tool] = []
    var coordinator: Coordinator!
    private struct SectionRow {
        var title: String
        var button: NSButton
        var status: SectionStatus
        var offset: Int  // textStorage position when it became active
        var updateCount: Int = 0   // # of updates available (when status == .hasUpdates)
    }
    private enum SectionStatus { case pending, active, done, hasUpdates, skipped }
    private var currentRunMode: Coordinator.Mode = .scan
    private var sectionRows: [SectionRow] = []
    private var activeSectionIndex: Int?
    private var sectionSpinnerFrame: Int = 0
    private var sectionSpinnerTimer: Timer?
    // One log buffer per section. Index 0 is the preamble (output before the
    // first section header). Index N (N>=1) corresponds to sectionRows[N-1].
    // The textView's layoutManager swaps between these so only one section's
    // log is on screen at a time.
    private var sectionStorages: [NSTextStorage] = [NSTextStorage()]
    private var liveSectionIdx: Int = 0   // where output is being appended
    private var displayedSectionIdx: Int = 0 // which storage textView shows
    private var followLive: Bool = true   // auto-switch on new live section
    private var liveStorage: NSTextStorage { sectionStorages[liveSectionIdx] }
    // streaming-line state for detecting print_header sections
    var featuresMenu: NSMenu!

    func applicationDidFinishLaunching(_ note: Notification) {
        AppPaths.ensure()
        buildToolList()
        coordinator = Coordinator(host: self)
        buildMenu()
        buildWindow()
        offerSudoersFixIfNeeded()
        // Start with a scan so the dashboard tells the user what's available
        // BEFORE any install runs. Apply Updates in the toolbar triggers
        // the real installer.
        requireAppManagement { [weak self] in self?.coordinator.run(.scan) }
    }

    /// The tools, in display + execution order. Defines the sidebar rows.
    private func buildToolList() {
        toolList = [
            RegistryTool(), BrewFormulaeTool(), BrewCasksTool(), MacPortsTool(),
            MasTool(), NpmTool(), GemTool(), RustupTool(), PipxTool(),
            ClaudeTool(), SparkleTool(), SoftwareUpdateTool(),
        ]
    }

    /// State file recording that the user confirmed App Management for THIS
    /// build of UpdateAll. We pin it to the bundle's actual codesign CDHash
    /// (not CFBundleVersion — that doesn't change between rebuilds of the
    /// same commit) so any rebuild forces a fresh prompt, matching macOS's
    /// own rule that TCC is per-signature.
    private var appMgmtStateFile: String {
        NSHomeDirectory() + "/Library/Application Support/UpdateAll/app-management-acked"
    }
    private var _cachedBuildId: String?
    private var currentBuildId: String {
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
    private func appMgmtAlreadyAcknowledgedForThisBuild() -> Bool {
        guard let s = try? String(contentsOfFile: appMgmtStateFile, encoding: .utf8) else { return false }
        return s.trimmingCharacters(in: .whitespacesAndNewlines) == currentBuildId
    }
    private func markAppMgmtAcknowledged() {
        let dir = (appMgmtStateFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? currentBuildId.write(toFile: appMgmtStateFile, atomically: true, encoding: .utf8)
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
            ? "UpdateAll can install a tiny sudoers rule so the script doesn't ask for your password during routine /usr/sbin/installer and /usr/sbin/softwareupdate calls. You'll be asked for your admin password once now."
            : "UpdateAll's sudoers rule grew coverage for MacPorts. Update now? (One admin prompt.)"
        alert.addButton(withTitle: sudoers == "missing" ? "Install" : "Update")
        alert.addButton(withTitle: "Skip")
        if alert.runModal() == .alertFirstButtonReturn {
            _ = runFeatureScript(args: ["sudoers", "enable"])
        }
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
        if appMgmtAlreadyAcknowledgedForThisBuild() {
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
            // matching state and head straight into the script — no second
            // modal here. (If they instead click "Later" without granting,
            // brew's first cask install will fail and surface the error.)
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

    /// Probe whether macOS App Management permission is granted.
    ///
    /// The naïve "create a hidden file inside .app" test FAILS — macOS doesn't
    /// consider that a TCC-protected modification, so it returns success even
    /// when the actual cask install (which replaces the whole .app) would be
    /// blocked. We need an operation TCC actually gates.
    ///
    /// What works: an atomic write to an existing file inside a third-party
    /// signed .app bundle. The atomic step renames a temp file over the target,
    /// which is what TCC actually checks for "modifying another app". We read
    /// the existing bytes and write them back, then restore the original
    /// modification timestamp so we're a no-op visible to brew/codesign.
    func appManagementGranted() -> Bool {
        let fm = FileManager.default
        var candidates: [String] = []
        for app in ["Brave Browser.app", "Visual Studio Code.app",
                    "VLC.app", "Firefox.app", "Google Chrome.app"] {
            let info = "/Applications/\(app)/Contents/Info.plist"
            if fm.fileExists(atPath: info) { candidates.append(info) }
        }
        if candidates.isEmpty,
           let items = try? fm.contentsOfDirectory(atPath: "/Applications") {
            // skip Apple-shipped apps (separate TCC entitlements)
            let appleApps: Set<String> = ["Safari.app", "Mail.app", "Calendar.app",
                "Contacts.app", "Messages.app", "FaceTime.app", "Photos.app",
                "Music.app", "TV.app", "News.app", "Reminders.app", "Notes.app",
                "Books.app", "Maps.app", "Stocks.app", "Weather.app",
                "Voice Memos.app", "Find My.app", "Freeform.app",
                "Image Capture.app", "Photo Booth.app", "Preview.app",
                "QuickTime Player.app", "Stickies.app", "TextEdit.app",
                "Time Machine.app", "Dictionary.app", "Font Book.app",
                "Chess.app", "Calculator.app", "App Store.app",
                "System Settings.app", "Pages.app", "Numbers.app",
                "Keynote.app", "GarageBand.app", "iMovie.app",
                "Shortcuts.app", "Home.app", "Automator.app"]
            for name in items where name.hasSuffix(".app") && !appleApps.contains(name) {
                let info = "/Applications/\(name)/Contents/Info.plist"
                if fm.fileExists(atPath: info) { candidates.append(info) }
            }
        }
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            do {
                let originalMtime = (try fm.attributesOfItem(atPath: path))[.modificationDate]
                let original = try Data(contentsOf: url)
                // Write *modified* bytes first, then restore. Writing identical
                // bytes back gets optimized into a no-op by macOS and slips
                // past tccd; an actual content change forces a real rename
                // that tccd validates against the current code signature.
                let modified = original + Data([0x20])    // append one space
                try modified.write(to: url, options: .atomic)
                try original.write(to: url, options: .atomic)
                if let mtime = originalMtime as? Date {
                    try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
                }
                return true
            } catch {
                // Likely TCC denial (EPERM) — but could also be a root-owned
                // file (EACCES). Try the next candidate before concluding.
                continue
            }
        }
        // every write failed → App Management is blocking us, OR every
        // candidate is root-owned (unlikely with brew installs). Either way,
        // the upcoming cask install would fail; safer to treat as blocked.
        return false
    }

    @objc func openAppManagementSettings() {
        // macOS Ventura+ deep link to the App Management pane.
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles")!
        NSWorkspace.shared.open(url)
    }

    /// Wrapper around features.sh `<feature> check` — returns "current",
    /// "outdated", "missing", or "" on script error.
    func featureCheck(_ feature: String) -> String {
        runFeatureScript(args: [feature, "check"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func buildMenu() {
        let main = NSMenu()

        // Application menu (first item — title shown as app name)
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Update All",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Update All",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Features menu
        let featuresItem = NSMenuItem()
        featuresItem.title = "Features"
        main.addItem(featuresItem)
        featuresMenu = NSMenu(title: "Features")
        featuresMenu.delegate = self
        featuresItem.submenu = featuresMenu

        NSApp.mainMenu = main
    }

    // refresh Features menu items each time it opens so labels reflect current state
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
        let appMgmtState = appMgmtAlreadyAcknowledgedForThisBuild()
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

    var featuresScriptPath: String {
        Bundle.main.path(forResource: "features", ofType: "sh")!
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

    @objc func toggleTouchID() {
        let action = (featureStatus("touchid") == "enabled") ? "disable" : "enable"
        let result = runFeatureScript(args: ["touchid", action]) ?? "(no output)"
        refreshFeaturesSidebar()
        showAlert(title: "Touch ID for sudo", message: result)
    }

    @objc func toggleSudoers() {
        let action = (featureStatus("sudoers") == "enabled") ? "disable" : "enable"
        let result = runFeatureScript(args: ["sudoers", action]) ?? "(no output)"
        refreshFeaturesSidebar()
        showAlert(title: "Passwordless sudo updates", message: result)
    }

    @objc func showLog() {
        let path = NSHomeDirectory() + "/Library/Logs/update-all.log"
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Update All"
        // let system materials / appearance drive the look — adapts to dark/light
        window.backgroundColor = NSColor.windowBackgroundColor
        window.titlebarAppearsTransparent = false  // standard mac titlebar
        window.center()

        // ── Sidebar (left): Sections jump-list + Features panel ──────────
        sectionsStack = NSStackView()
        sectionsStack.orientation = .vertical
        sectionsStack.alignment = .leading
        sectionsStack.spacing = 1

        featuresStack = NSStackView()
        featuresStack.orientation = .vertical
        featuresStack.alignment = .leading
        featuresStack.spacing = 1

        let sectionsHeader = sidebarSectionHeader("UPDATE SECTIONS")
        let settingsHeader = sidebarSectionHeader("SETTINGS")

        // Flexible spacer that pushes the SETTINGS group to the bottom of the
        // sidebar (sections grow from the top, settings grow from the bottom).
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let sidebarBody = NSStackView(views: [
            sectionsHeader, sectionsStack,
            spacer,
            settingsHeader, featuresStack,
        ])
        sidebarBody.orientation = .vertical
        sidebarBody.alignment = .leading
        // .fill (NOT the default .gravityAreas which centers content vertically)
        // — combined with the spacer's low hugging priority this anchors
        // sections at the top and settings at the bottom.
        sidebarBody.distribution = .fill
        sidebarBody.spacing = 4
        sidebarBody.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        sidebarBody.translatesAutoresizingMaskIntoConstraints = false

        let sidebarScroll = NSScrollView()
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.borderType = .noBorder
        // .sidebar material gives the native translucent / vibrant look that
        // every modern macOS app's sidebar uses (Finder, Mail, Music, …)
        let sidebarBackdrop = NSVisualEffectView()
        sidebarBackdrop.translatesAutoresizingMaskIntoConstraints = false
        sidebarBackdrop.material = .sidebar
        sidebarBackdrop.blendingMode = .behindWindow
        sidebarBackdrop.state = .followsWindowActiveState
        sidebarScroll.documentView = sidebarBody
        sidebarScroll.contentView.postsBoundsChangedNotifications = false
        NSLayoutConstraint.activate([
            sidebarBody.widthAnchor.constraint(equalTo: sidebarScroll.widthAnchor),
            // force the stack to be at least as tall as the visible scroll
            // area; this gives the spacer something to expand into so
            // SETTINGS gets pushed to the bottom
            sidebarBody.heightAnchor.constraint(greaterThanOrEqualTo: sidebarScroll.contentView.heightAnchor),
        ])

        // ── Main pane (right): three overlaid views (only one visible) ──
        // Default = dashboard.
        // Click section row     → console for that section.
        // Script exits cleanly  → success view + Re-run button.
        consoleScroll = NSScrollView()
        consoleScroll.translatesAutoresizingMaskIntoConstraints = false
        consoleScroll.hasVerticalScroller = true
        consoleScroll.drawsBackground = false
        consoleScroll.borderType = .noBorder    // no heavy frame

        textView = NSTextView()
        textView.isEditable = false
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 12)
        textView.autoresizingMask = .width
        textView.isRichText = false
        textView.layoutManager?.replaceTextStorage(sectionStorages[0])
        consoleScroll.documentView = textView

        successView = buildSuccessView()
        successView.isHidden = true

        dashboardView = buildDashboardView()
        dashboardView.isHidden = false

        consoleScroll.isHidden = true   // dashboard visible by default

        let mainContainer = NSView()
        mainContainer.translatesAutoresizingMaskIntoConstraints = false
        mainContainer.addSubview(dashboardView)
        mainContainer.addSubview(consoleScroll)
        mainContainer.addSubview(successView)
        for v in [dashboardView, consoleScroll, successView] as [NSView] {
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: mainContainer.topAnchor),
                v.leadingAnchor.constraint(equalTo: mainContainer.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: mainContainer.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: mainContainer.bottomAnchor),
            ])
        }

        // ── Split: sidebar | main ─────────────────────────────────────────
        sidebarBackdrop.addSubview(sidebarScroll)
        NSLayoutConstraint.activate([
            sidebarScroll.topAnchor.constraint(equalTo: sidebarBackdrop.topAnchor),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebarBackdrop.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebarBackdrop.trailingAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebarBackdrop.bottomAnchor),
        ])
        let split = NSSplitView()
        split.translatesAutoresizingMaskIntoConstraints = false
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebarBackdrop)
        split.addArrangedSubview(mainContainer)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        let sidebarPreferred = sidebarBackdrop.widthAnchor.constraint(equalToConstant: 260)
        sidebarPreferred.priority = .defaultHigh
        NSLayoutConstraint.activate([
            sidebarBackdrop.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            sidebarBackdrop.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            sidebarPreferred,
        ])

        // Bottom button bar is replaced by the toolbar at the top. Keep the
        // properties live (referenced in terminationHandler etc.) but never
        // add them to the window.
        closeButton = NSButton(title: "Close", target: self, action: #selector(quit))
        closeButton.isHidden = true
        abortButton = NSButton(title: "Abort", target: self, action: #selector(abortRun))
        abortButton.isHidden = true

        let content = window.contentView!
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // ── Toolbar ───────────────────────────────────────────────────────
        let toolbar = NSToolbar(identifier: "com.gunnar.update-all.toolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        populateUpdateSectionsSidebar()
        refreshFeaturesSidebar()
        refreshDashboard()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Sidebar helpers ─────────────────────────────────────────────

    private func sidebarSectionHeader(_ text: String) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        // mac-standard "source list" header: small caps, semibold, secondary
        lbl.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        lbl.textColor = NSColor.secondaryLabelColor
        return lbl
    }

    private func sidebarGap(height: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([v.heightAnchor.constraint(equalToConstant: height)])
        return v
    }

    /// One clickable sidebar row using an SF Symbol + title.
    private func sidebarRow(title: String, systemSymbol: String,
                            target: AnyObject?, action: Selector?,
                            tint: NSColor = NSColor.labelColor) -> NSButton {
        let btn = NSButton(title: " " + title, target: target, action: action)
        btn.alignment = .left
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.focusRingType = .none
        btn.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        btn.contentTintColor = tint
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        btn.image = NSImage(systemSymbolName: systemSymbol,
                            accessibilityDescription: title)?
                    .withSymbolConfiguration(cfg)
        btn.imagePosition = .imageLeft
        btn.imageHugsTitle = true
        return btn
    }

    // MARK: CoordinatorHost ──────────────────────────────────────────────
    // Section boundaries and results are now explicit (driven by the
    // Coordinator) instead of scraped from the script's stdout.

    var tools: [Tool] { toolList }

    func runWillStart(_ mode: Coordinator.Mode) {
        currentRunMode = mode
        openLog()
        resetForRun()
    }

    /// Section `idx` became active: allocate its log storage, mark the row,
    /// and (if following live) swap the console to it.
    func sectionDidBegin(_ idx: Int) {
        let newLiveIdx = idx + 1   // storage[0] is the preamble
        while sectionStorages.count <= newLiveIdx { sectionStorages.append(NSTextStorage()) }
        liveSectionIdx = newLiveIdx
        lineStartLen = 0
        pendingLogLine = ""
        spinnerVisible = false
        sectionRows[idx].offset = 0
        activeSectionIndex = idx
        markRow(idx, status: .active)
        if followLive {
            displayedSectionIdx = newLiveIdx
            textView.layoutManager?.replaceTextStorage(sectionStorages[newLiveIdx])
        }
        refreshDashboard()
        if sectionSpinnerTimer == nil {
            sectionSpinnerTimer = Timer.scheduledTimer(timeInterval: 0.12, target: self,
                                                      selector: #selector(tickSectionSpinner),
                                                      userInfo: nil, repeats: true)
        }
    }

    func appendConsole(_ text: String) { append(text) }

    func sectionDidEndScan(_ idx: Int, _ result: ScanResult) {
        renderScanSummary(result)
        switch result.state {
        case .hasUpdates:
            sectionRows[idx].updateCount = result.items.count
            markRow(idx, status: .hasUpdates)
        case .unavailable:
            markRow(idx, status: .skipped)
        case .upToDate, .unknown:
            sectionRows[idx].updateCount = 0
            markRow(idx, status: .done)
        }
        activeSectionIndex = nil
        updateToolbarState()
        refreshDashboard()
    }

    func sectionDidEndInstall(_ idx: Int, _ outcome: InstallOutcome) {
        switch outcome.state {
        case .ok:
            markRow(idx, status: .done)
        case .skipped:
            markRow(idx, status: .done)
            if let m = outcome.message { appendConsole("  ⊘ \(m)\n") }
        case .failed:
            markRow(idx, status: .done)
            appendConsole("  ✗ \(outcome.message ?? "failed")\n")
        case .unavailable:
            markRow(idx, status: .skipped)
        }
        sectionRows[idx].updateCount = 0
        activeSectionIndex = nil
        updateToolbarState()
        refreshDashboard()
    }

    func sectionSkipped(_ idx: Int, reason: String) {
        // "up to date" on an install pass reads as success (green check);
        // disabled / not-installed reads as intentionally inactive (grey).
        markRow(idx, status: reason == "up to date" ? .done : .skipped)
        refreshDashboard()
    }

    func ask(_ question: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Update All"
            alert.informativeText = question
            alert.addButton(withTitle: "Yes")
            alert.addButton(withTitle: "No")
            // Sheet (drops from the titlebar) keeps the prompt inside the app.
            alert.beginSheetModal(for: self.window) { resp in
                let yes = (resp == .alertFirstButtonReturn)
                self.appendConsole("  → \(yes ? "Yes" : "No")\n")
                cont.resume(returning: yes)
            }
        }
    }

    func runDidFinish(_ mode: Coordinator.Mode, aborted: Bool) {
        sectionSpinnerTimer?.invalidate(); sectionSpinnerTimer = nil
        eraseSpinner()
        activeSectionIndex = nil
        abortButton.isHidden = true
        abortButton.title = "Abort"
        abortButton.action = #selector(abortRun)
        abortButton.isEnabled = true
        closeButton.isHidden = false
        updateToolbarState()
        refreshDashboard()
        showRightPane(.dashboard)
        if mode == .install && !aborted { showSuccessScreen() }
    }

    /// Append a standard one-line summary of a scan result to the console.
    private func renderScanSummary(_ r: ScanResult) {
        switch r.state {
        case .upToDate:
            appendConsole("  ✓ Up to date\n")
        case .unavailable:
            appendConsole("  – not installed — skipping\n")
        case .unknown:
            appendConsole("  ? \(r.note ?? "indeterminate")\n")
        case .hasUpdates:
            appendConsole("  ↑ \(r.items.count) update\(r.items.count == 1 ? "" : "s") available\n")
            for it in r.items.prefix(40) { appendConsole("    • \(it.summary)\n") }
            if r.items.count > 40 { appendConsole("    … and \(r.items.count - 40) more\n") }
        }
    }

    /// Pre-populate every known section as "pending" so the user can see the
    /// whole pipeline at a glance and jump to a finished one immediately.
    private func populateUpdateSectionsSidebar() {
        for (i, tool) in toolList.enumerated() {
            let btn = sidebarRow(title: tool.title, systemSymbol: "circle",
                                 target: self,
                                 action: #selector(jumpToSection(_:)),
                                 tint: NSColor.tertiaryLabelColor)
            btn.tag = i
            sectionsStack.addArrangedSubview(btn)
            sectionRows.append(SectionRow(title: tool.title, button: btn,
                                          status: .pending, offset: 0))
        }
    }


    private func markRow(_ idx: Int, status: SectionStatus) {
        sectionRows[idx].status = status
        let title = sectionRows[idx].title
        let btn   = sectionRows[idx].button
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        switch status {
        case .pending:
            btn.title = " " + title
            btn.image = NSImage(systemSymbolName: "circle", accessibilityDescription: "pending")?
                        .withSymbolConfiguration(cfg)
            btn.contentTintColor = NSColor.tertiaryLabelColor
        case .active:
            // trailing braille frame animates via tickSectionSpinner; the
            // SF Symbol stays as a rotating-arrows icon for static identity
            let glyph = Self.spinnerGlyphs[sectionSpinnerFrame % Self.spinnerGlyphs.count]
            btn.title = " \(title)  \(glyph)"
            btn.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                accessibilityDescription: "running")?
                        .withSymbolConfiguration(cfg)
            btn.contentTintColor = NSColor.controlAccentColor
        case .done:
            btn.title = " " + title
            btn.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                accessibilityDescription: "done")?
                        .withSymbolConfiguration(cfg)
            btn.contentTintColor = NSColor.systemGreen
        case .hasUpdates:
            btn.title = " " + title
            btn.image = NSImage(systemSymbolName: "arrow.up.circle.fill",
                                accessibilityDescription: "updates available")?
                        .withSymbolConfiguration(cfg)
            btn.contentTintColor = NSColor.systemOrange
        case .skipped:
            // tool not installed → dim row + slash icon so it reads as
            // intentionally inactive rather than failed
            btn.title = " " + title
            btn.image = NSImage(systemSymbolName: "minus.circle",
                                accessibilityDescription: "not installed")?
                        .withSymbolConfiguration(cfg)
            btn.contentTintColor = NSColor.tertiaryLabelColor
        }
    }

    // MARK: Right-pane state ─────────────────────────────────────────────

    private enum RightPane { case dashboard, console, success }

    private func showRightPane(_ which: RightPane) {
        dashboardView.isHidden  = (which != .dashboard)
        consoleScroll.isHidden  = (which != .console)
        successView.isHidden    = (which != .success)
    }

    /// Centered status view: large symbol, headline, subtitle, progress count.
    /// This is what the right pane shows by default — the console only opens
    /// when the user clicks a section row to drill down.
    private func buildDashboardView() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 80, weight: .regular)
        icon.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                             accessibilityDescription: "Updating")?
                     .withSymbolConfiguration(cfg)
        icon.contentTintColor = NSColor.controlAccentColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        dashboardIcon = icon

        let title = NSTextField(labelWithString: "Starting…")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = NSFont.systemFont(ofSize: 28, weight: .semibold)
        title.alignment = .center
        dashboardTitle = title

        let subtitle = NSTextField(labelWithString: "")
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        subtitle.textColor = NSColor.secondaryLabelColor
        subtitle.alignment = .center
        dashboardSubtitle = subtitle

        let progress = NSTextField(labelWithString: "")
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.font = NSFont.systemFont(ofSize: 12)
        progress.textColor = NSColor.tertiaryLabelColor
        progress.alignment = .center
        dashboardProgress = progress

        let updatesList = NSStackView()
        updatesList.orientation = .vertical
        updatesList.alignment = .leading
        updatesList.spacing = 4
        updatesList.translatesAutoresizingMaskIntoConstraints = false
        dashboardUpdatesList = updatesList

        let stack = NSStackView(views: [icon, title, subtitle, updatesList, progress])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])
        return container
    }

    /// Refresh the dashboard headline / progress / icon to reflect the
    /// current pipeline state.
    private func refreshDashboard() {
        let bigCfg = NSImage.SymbolConfiguration(pointSize: 80, weight: .regular)
        // skipped sections shouldn't count toward "progress" — those tools
        // aren't installed, the script never touches them, so a counter that
        // jumps from 0 to (#skipped) at the start is misleading. Total =
        // sections actually being run; Done = how many of those have a result.
        let active = activeSectionIndex.map { sectionRows[$0].title }
        // Fixed denominator = all tools, so the counter climbs monotonically
        // (1/12, 2/12, …) instead of jumping as not-installed tools shrink the
        // total. A section is "complete" once it reaches any terminal state,
        // including .skipped (not installed / disabled / already up to date).
        let total = sectionRows.count
        let done = sectionRows.filter {
            $0.status == .done || $0.status == .hasUpdates || $0.status == .skipped
        }.count
        let updates = sectionRows.filter { $0.status == .hasUpdates }.count
        let busy = isScriptRunning

        // wipe the per-section list; rebuild it below for the relevant states
        dashboardUpdatesList?.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if busy, let activeTitle = active {
            dashboardIcon?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                           accessibilityDescription: "Running")?.withSymbolConfiguration(bigCfg)
            dashboardIcon?.contentTintColor = NSColor.controlAccentColor
            dashboardTitle?.stringValue = currentRunMode == .scan ? "Scanning…" : "Applying updates…"
            dashboardSubtitle?.stringValue = activeTitle
            dashboardProgress?.stringValue = "\(done) of \(total) sections complete"
        } else if busy {
            dashboardTitle?.stringValue = currentRunMode == .scan ? "Scanning…" : "Starting…"
            dashboardSubtitle?.stringValue = ""
            dashboardProgress?.stringValue = "\(done) of \(total) sections complete"
        } else if done < total {
            // script ended before completing — aborted, crashed, or killed
            dashboardIcon?.image = NSImage(systemSymbolName: "stop.circle.fill",
                                           accessibilityDescription: "Stopped")?
                                   .withSymbolConfiguration(bigCfg)
            dashboardIcon?.contentTintColor = NSColor.secondaryLabelColor
            dashboardTitle?.stringValue = "Stopped"
            dashboardSubtitle?.stringValue = "\(done) of \(total) sections completed before stopping."
            dashboardProgress?.stringValue = ""
        } else if done == total && total > 0 {
            if updates > 0 {
                dashboardIcon?.image = NSImage(systemSymbolName: "arrow.up.circle.fill",
                                               accessibilityDescription: "Updates available")?
                                       .withSymbolConfiguration(bigCfg)
                dashboardIcon?.contentTintColor = NSColor.systemOrange
                dashboardTitle?.stringValue = "\(updates) tool\(updates == 1 ? "" : "s") with updates"
                dashboardSubtitle?.stringValue = "Click Apply Updates in the toolbar to install."
                dashboardProgress?.stringValue = ""
                // populate the per-section list
                for row in sectionRows where row.status == .hasUpdates {
                    let label = NSTextField(labelWithString: dashboardRowText(for: row))
                    label.font = NSFont.systemFont(ofSize: 13)
                    label.textColor = NSColor.labelColor
                    dashboardUpdatesList?.addArrangedSubview(label)
                }
            } else {
                dashboardIcon?.image = NSImage(systemSymbolName: "checkmark.seal.fill",
                                               accessibilityDescription: "All done")?
                                       .withSymbolConfiguration(bigCfg)
                dashboardIcon?.contentTintColor = NSColor.systemGreen
                dashboardTitle?.stringValue = "All up to date"
                dashboardSubtitle?.stringValue = currentRunMode == .scan ? "No updates available." : ""
                dashboardProgress?.stringValue = ""
            }
        } else {
            dashboardTitle?.stringValue = currentRunMode == .scan ? "Scanning…" : "Starting…"
            dashboardSubtitle?.stringValue = ""
            dashboardProgress?.stringValue = "\(done) of \(total) sections complete"
        }
    }

    private func dashboardRowText(for row: SectionRow) -> String {
        if row.updateCount > 0 {
            return "↑  \(row.title)  —  \(row.updateCount) update\(row.updateCount == 1 ? "" : "s")"
        }
        return "↑  \(row.title)"
    }

    // MARK: NSToolbarDelegate ────────────────────────────────────────────

    private static let toolbarRefreshID:  NSToolbarItem.Identifier = .init("refresh")
    private static let toolbarInstallID:  NSToolbarItem.Identifier = .init("install")
    private static let toolbarAbortID:    NSToolbarItem.Identifier = .init("abort")
    private static let toolbarLogID:      NSToolbarItem.Identifier = .init("log")
    private static let toolbarDashID:     NSToolbarItem.Identifier = .init("dashboard")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toolbarDashID, Self.toolbarRefreshID, Self.toolbarInstallID, Self.toolbarAbortID,
         .flexibleSpace, Self.toolbarLogID]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.flexibleSpace, .space]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        switch id {
        case Self.toolbarDashID:
            item.label = "Dashboard"
            item.image = NSImage(systemSymbolName: "house",
                                 accessibilityDescription: "Dashboard")?
                         .withSymbolConfiguration(cfg)
            item.target = self
            item.action = #selector(showDashboardFromToolbar)
        case Self.toolbarRefreshID:
            item.label = "Refresh"
            item.image = NSImage(systemSymbolName: "arrow.clockwise",
                                 accessibilityDescription: "Refresh (scan only)")?
                         .withSymbolConfiguration(cfg)
            item.target = self
            item.action = #selector(refreshAction)
            item.isEnabled = !isScriptRunning
            toolbarRefreshItem = item
            lastToolbarSnapshot = nil  // force next updateToolbarState to re-apply
        case Self.toolbarInstallID:
            item.label = "Apply Updates"
            item.image = NSImage(systemSymbolName: "arrow.down.circle.fill",
                                 accessibilityDescription: "Apply all available updates")?
                         .withSymbolConfiguration(cfg)
            item.target = self
            item.action = #selector(applyAction)
            item.isEnabled = !isScriptRunning && anyUpdatesAvailable
            toolbarRerunItem = item
            lastToolbarSnapshot = nil
        case Self.toolbarAbortID:
            item.label = "Abort"
            item.image = NSImage(systemSymbolName: "stop.circle",
                                 accessibilityDescription: "Abort")?
                         .withSymbolConfiguration(cfg)
            item.target = self
            item.action = #selector(abortRun)
            item.isEnabled = isScriptRunning
            toolbarAbortItem = item
            lastToolbarSnapshot = nil
        case Self.toolbarLogID:
            item.label = "Log"
            item.image = NSImage(systemSymbolName: "doc.text",
                                 accessibilityDescription: "Open log")?
                         .withSymbolConfiguration(cfg)
            item.target = self
            item.action = #selector(showLog)
        default: return nil
        }
        return item
    }

    @objc func refreshAction() {
        guard !isScriptRunning else { return }
        coordinator.run(.scan)   // re-scan every enabled tool
    }

    @objc func applyAction() {
        guard !isScriptRunning else { return }
        // The coordinator skips tools the last scan found up to date, so an
        // install only touches sections that actually have updates (plus the
        // always-run App registry and indeterminate tools like pipx/claude).
        coordinator.run(.install)
    }
    // legacy alias for the success-view button selector
    @objc func installAction() { applyAction() }

    /// Re-evaluate toolbar enable states. Rules:
    ///   - Refresh: enabled iff no run is active.
    ///   - Apply Updates: enabled iff no run is active AND the last scan
    ///     surfaced at least one section with available updates.
    ///   - Abort: enabled iff a run IS active.
    private var isScriptRunning: Bool { coordinator?.isRunning == true }
    private var anyUpdatesAvailable: Bool {
        sectionRows.contains { $0.status == .hasUpdates }
    }
    private func setToolbarRunning(_ running: Bool) { updateToolbarState() }
    private var lastToolbarSnapshot: (busy: Bool, hasUpdates: Bool)?
    /// Force the toolbar to re-validate visible items. NSToolbar will call
    /// validateToolbarItem(_:) on the target for each item, which is where
    /// the real enable/disable decision lives.
    private func updateToolbarState(running: Bool? = nil) {
        let busy = running ?? isScriptRunning
        let hasUpdates = anyUpdatesAvailable
        if let last = lastToolbarSnapshot,
           last.busy == busy && last.hasUpdates == hasUpdates { return }
        lastToolbarSnapshot = (busy, hasUpdates)
        window?.toolbar?.validateVisibleItems()
    }

    /// Resets per-run UI state. The coordinator decides which sections to skip
    /// live (disabled / unavailable / already up to date), so every row starts
    /// as .pending here.
    private func resetForRun() {
        sectionSpinnerTimer?.invalidate(); sectionSpinnerTimer = nil
        for i in 0..<sectionRows.count {
            sectionRows[i].offset = 0
            sectionRows[i].updateCount = 0
            markRow(i, status: .pending)
        }
        activeSectionIndex = nil
        sectionStorages = [NSTextStorage()]
        liveSectionIdx = 0; displayedSectionIdx = 0; followLive = true
        lineStartLen = 0; pendingLogLine = ""; spinnerVisible = false
        textView.layoutManager?.replaceTextStorage(sectionStorages[0])
        showRightPane(.dashboard)
        refreshDashboard()
        abortButton.isHidden = false
        closeButton.isHidden = true
    }

    @objc private func showDashboardFromToolbar() {
        showRightPane(.dashboard)
        refreshDashboard()
    }

    /// NSToolbar auto-validates items via this method on the target. Without
    /// it, NSToolbar lights items back up after our isEnabled writes.
    @objc func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let busy = isScriptRunning
        switch item.itemIdentifier {
        case Self.toolbarRefreshID: return !busy
        case Self.toolbarInstallID: return !busy && anyUpdatesAvailable
        case Self.toolbarAbortID:   return busy
        default: return true
        }
    }

    /// Big green checkmark + "All up to date" + Re-run, shown when the script
    /// finishes successfully. Replaces the console view in the right pane.
    private func buildSuccessView() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 128, weight: .semibold)
        icon.image = NSImage(systemSymbolName: "checkmark.seal.fill",
                             accessibilityDescription: "All updates complete")?
                     .withSymbolConfiguration(cfg)
        icon.contentTintColor = NSColor.systemGreen
        icon.imageScaling = .scaleProportionallyUpOrDown

        let title = NSTextField(labelWithString: "All up to date")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        title.alignment = .center

        rerunButton = NSButton(title: "Refresh", target: self, action: #selector(refreshAction))
        rerunButton.translatesAutoresizingMaskIntoConstraints = false
        rerunButton.bezelStyle = .rounded
        rerunButton.keyEquivalent = "r"
        rerunButton.keyEquivalentModifierMask = [.command]

        container.addSubview(icon)
        container.addSubview(title)
        container.addSubview(rerunButton)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -60),
            icon.widthAnchor.constraint(equalToConstant: 140),
            icon.heightAnchor.constraint(equalToConstant: 140),
            title.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 18),
            rerunButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            rerunButton.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 24),
            rerunButton.widthAnchor.constraint(equalToConstant: 160),
        ])
        return container
    }

    /// Show the success view. Called from terminationHandler when the script
    /// completed normally (status 0).
    private func showSuccessScreen() {
        showRightPane(.success)
    }

    /// Legacy alias kept for any leftover wiring — runs a full install pass.
    @objc func rerun() { installAction() }

    @objc private func tickSectionSpinner() {
        guard let idx = activeSectionIndex else { return }
        sectionSpinnerFrame = (sectionSpinnerFrame + 1) % Self.spinnerGlyphs.count
        let glyph = Self.spinnerGlyphs[sectionSpinnerFrame]
        sectionRows[idx].button.title = "\(glyph)  \(sectionRows[idx].title)"
    }


    @objc private func jumpToSection(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < sectionRows.count else { return }
        let row = sectionRows[sender.tag]
        guard row.status != .pending else { return }    // hasn't run yet
        let storageIdx = sender.tag + 1
        guard storageIdx < sectionStorages.count else { return }
        displayedSectionIdx = storageIdx
        followLive = (storageIdx == liveSectionIdx)
        textView.layoutManager?.replaceTextStorage(sectionStorages[storageIdx])
        // surface the console (it's hidden by default; dashboard is the
        // default right-pane view)
        showRightPane(.console)
        if followLive {
            textView.scrollToEndOfDocument(nil)
        } else {
            textView.scroll(.zero)
        }
    }

    /// Rebuild the Features rows from features.sh state. Called on launch,
    /// after a feature is toggled, and when the user opens the app.
    private func refreshFeaturesSidebar() {
        for v in featuresStack.arrangedSubviews { v.removeFromSuperview() }
        let touchidOK = featureCheck("touchid") == "current"
        let sudoersState = featureCheck("sudoers")
        let appMgmtOK = appMgmtAlreadyAcknowledgedForThisBuild()
        let entries: [(title: String, symbol: String, tint: NSColor, sel: Selector?)] = [
            ("Touch ID for sudo",   touchidOK ? "touchid"  : "exclamationmark.triangle.fill",
                                    touchidOK ? .systemGreen : .systemOrange, #selector(toggleTouchID)),
            ("Passwordless sudo",   sudoersState == "current" ? "lock.shield.fill"
                                       : (sudoersState == "outdated" ? "arrow.triangle.2.circlepath"
                                                                     : "exclamationmark.triangle.fill"),
                                    sudoersState == "current" ? .systemGreen
                                       : (sudoersState == "outdated" ? .systemYellow : .systemOrange),
                                    #selector(toggleSudoers)),
            ("App Management",      appMgmtOK ? "app.badge.checkmark"
                                              : "exclamationmark.triangle.fill",
                                    appMgmtOK ? .systemGreen : .systemOrange,
                                    #selector(openAppManagementSettings)),
            ("Open log",            "doc.text", .secondaryLabelColor, #selector(showLog)),
        ]
        for entry in entries {
            featuresStack.addArrangedSubview(
                sidebarRow(title: entry.title, systemSymbol: entry.symbol,
                           target: self, action: entry.sel, tint: entry.tint)
            )
        }
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func abortRun() {
        guard isScriptRunning else { return }
        coordinator.abort()   // SIGINT to the current subprocess; stop the loop
        // 2nd click escalates to SIGTERM
        abortButton.title = "Force quit"
        abortButton.action = #selector(forceKill)
        append("\n  ⚠ Sent SIGINT — waiting for tasks to clean up...\n")
    }

    @objc func forceKill() {
        coordinator?.forceKill()   // SIGTERM
        abortButton.isEnabled = false
        append("\n  ⚠ Sent SIGTERM\n")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // make sure the subprocess doesn't outlive the app
        coordinator?.forceKill()
    }

    private func eraseSpinner() {
        guard spinnerVisible else { return }
        let storage = liveStorage
        if storage.length > lineStartLen {
            storage.deleteCharacters(in: NSRange(location: lineStartLen,
                                                 length: storage.length - lineStartLen))
        }
        spinnerVisible = false
    }

    // strip ANSI escape codes
    private static let ansi = try! NSRegularExpression(pattern: "\u{1b}\\[[0-9;]*[mGKHFABCDJsu]")

    private var logHandle: FileHandle?
    // position in textStorage where the current (in-progress) line begins —
    // used to overwrite that range when we see a CR (`\r`) from terminal-style
    // progress redraws (Homebrew downloads, etc.)
    private var lineStartLen: Int = 0
    // current-line buffer for the log: only committed lines (post-\n) get
    // written, so the log keeps a clean record without hundreds of progress ticks
    private var pendingLogLine: String = ""

    // Spinner-erase bookkeeping (the active-section sidebar spinner communicates
    // "still working"; no in-console ghost line is rendered).
    private var spinnerVisible: Bool = false
    private static let spinnerGlyphs = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]

    func openLog() {
        let dir = NSHomeDirectory() + "/Library/Logs"
        let path = dir + "/update-all.log"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        rotateLog(atPath: path, keep: 4)   // we're about to write the 5th
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        logHandle = FileHandle(forWritingAtPath: path)
        logHandle?.seekToEndOfFile()
        let fmt = ISO8601DateFormatter()
        let header = "\n==== UpdateAll run \(fmt.string(from: Date())) ====\n"
        logHandle?.write(header.data(using: .utf8)!)
    }

    /// Keep at most `keep` prior runs in the log. Each run begins with
    /// "==== UpdateAll run <ISO> ====" on its own line — find those markers
    /// and drop everything before the `keep`-th from the end.
    private func rotateLog(atPath path: String, keep: Int) {
        guard let existing = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = existing.components(separatedBy: "\n")
        var headerIndexes: [Int] = []
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("==== UpdateAll run ") { headerIndexes.append(i) }
        }
        guard headerIndexes.count > keep else { return }
        let dropBefore = headerIndexes[headerIndexes.count - keep]
        let trimmed = lines[dropBefore...].joined(separator: "\n")
        try? trimmed.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static let textAttrs: [NSAttributedString.Key: Any] = [
        // labelColor adapts to light/dark mode so the console reads in both
        .foregroundColor: NSColor.labelColor,
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
    ]

    func append(_ raw: String) {
        let cleaned = Self.ansi.stringByReplacingMatches(
            in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{04}", with: "")   // PTY EOF control char
            .replacingOccurrences(of: "^D", with: "")       // PTY EOF display form
            .replacingOccurrences(of: "━", with: "")        // strip print_header
                                                            // rule chars; the
                                                            // sidebar shows the
                                                            // section name
        let storage = liveStorage

        var i = cleaned.startIndex
        while i < cleaned.endIndex {
            let ch = cleaned[i]
            switch ch {
            case "\r":
                // overwrite: erase visible content of current line in the UI
                if storage.length > lineStartLen {
                    storage.deleteCharacters(in: NSRange(
                        location: lineStartLen,
                        length: storage.length - lineStartLen))
                }
                pendingLogLine = ""
                i = cleaned.index(after: i)
            case "\n":
                storage.append(NSAttributedString(string: "\n", attributes: Self.textAttrs))
                pendingLogLine.append("\n")
                if let data = pendingLogLine.data(using: .utf8) {
                    logHandle?.write(data)
                }
                pendingLogLine = ""
                lineStartLen = storage.length
                i = cleaned.index(after: i)
            default:
                // batch consecutive non-CR/non-LF chars into one append
                var j = i
                while j < cleaned.endIndex, cleaned[j] != "\r", cleaned[j] != "\n" {
                    j = cleaned.index(after: j)
                }
                let chunk = String(cleaned[i..<j])
                storage.append(NSAttributedString(string: chunk, attributes: Self.textAttrs))
                pendingLogLine.append(chunk)
                i = j
            }
        }
        if followLive { textView.scrollToEndOfDocument(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
