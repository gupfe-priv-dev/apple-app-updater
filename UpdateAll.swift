import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var window: NSWindow!
    var textView: NSTextView!
    var closeButton: NSButton!
    var abortButton: NSButton!
    var featuresMenu: NSMenu!
    var runningProcess: Process?

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        buildWindow()
        offerSudoersFixIfNeeded()
        requireAppManagement { [weak self] in self?.runScript() }
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
                    self?.requireAppManagement(proceed)
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
        showAlert(title: "Touch ID for sudo", message: result)
    }

    @objc func toggleSudoers() {
        let action = (featureStatus("sudoers") == "enabled") ? "disable" : "enable"
        let result = runFeatureScript(args: ["sudoers", action]) ?? "(no output)"
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
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Update All"
        // window background = mid-dark gray so the textView (much darker) reads
        // as a framed inner pane instead of bleeding to the window edges
        window.backgroundColor = NSColor(calibratedWhite: 0.22, alpha: 1)
        window.center()

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .lineBorder

        textView = NSTextView()
        textView.isEditable = false
        textView.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1)
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = .width
        textView.isRichText = false
        scroll.documentView = textView

        closeButton = NSButton(title: "Close  ↩", target: self, action: #selector(quit))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = true
        closeButton.keyEquivalent = "\r"
        closeButton.bezelStyle = .rounded

        abortButton = NSButton(title: "Abort  ⎋", target: self, action: #selector(abortRun))
        abortButton.translatesAutoresizingMaskIntoConstraints = false
        abortButton.keyEquivalent = "\u{1b}" // Esc
        abortButton.bezelStyle = .rounded

        let content = window.contentView!
        content.addSubview(scroll)
        content.addSubview(closeButton)
        content.addSubview(abortButton)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -10),
            closeButton.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            closeButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 120),
            abortButton.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            abortButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            abortButton.widthAnchor.constraint(equalToConstant: 140),
        ])

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func abortRun() {
        guard let proc = runningProcess, proc.isRunning else { return }
        proc.interrupt()  // SIGINT (= Ctrl+C)
        // 2nd click escalates to SIGTERM
        abortButton.title = "Force quit"
        abortButton.action = #selector(forceKill)
        append("\n  ⚠ Sent SIGINT — waiting for tasks to clean up...\n")
    }

    @objc func forceKill() {
        guard let proc = runningProcess, proc.isRunning else { return }
        proc.terminate()  // SIGTERM
        abortButton.isEnabled = false
        append("\n  ⚠ Sent SIGTERM\n")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // make sure the subprocess doesn't outlive the app
        if let proc = runningProcess, proc.isRunning {
            proc.terminate()
        }
    }

    var scriptPath: String {
        Bundle.main.path(forResource: "update-all", ofType: "sh")!
    }

    func runScript() {
        openLog()
        let proc = Process()
        // script(1) allocates a pseudo-TTY so sudo/Touch ID can prompt properly
        // -F forces an immediate flush after each write so output streams live (no chunking)
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        proc.arguments = ["-F", "-q", "/dev/null", "/bin/zsh", scriptPath]
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLUMNS"] = "110"
        env["LINES"] = "40"
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["UPDATER_GUI"] = "1"   // tells ask_yn in the script to use osascript dialogs
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.append(text) }
        }

        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.heartbeat?.invalidate()
                self?.heartbeat = nil
                self?.eraseSpinner()
                // distinguish from the script's own "✅ All done" — this only matters
                // if the script died abnormally (non-zero exit) or was aborted
                if proc.terminationStatus != 0 {
                    self?.append("\n[process exited with status \(proc.terminationStatus)]\n")
                }
                self?.abortButton.isHidden = true
                self?.closeButton.isHidden = false
            }
        }

        runningProcess = proc
        try? proc.run()

        // tick once per second to refresh the heartbeat spinner
        heartbeat = Timer.scheduledTimer(timeInterval: 1.0, target: self,
                                         selector: #selector(tickHeartbeat),
                                         userInfo: nil, repeats: true)
    }

    @objc func tickHeartbeat() {
        guard let proc = runningProcess, proc.isRunning else {
            eraseSpinner()
            return
        }
        guard let storage = textView.textStorage else { return }
        // only render the spinner at a clean line boundary; don't trample a
        // partial line in progress (e.g. a \r-style progress update mid-flight)
        let atBoundary = storage.length == lineStartLen
        let idle = Date().timeIntervalSince(lastOutputAt)
        if !spinnerVisible {
            guard idle >= 2.0, atBoundary else { return }
            spinnerVisible = true
            spinnerStartedAt = Date()
        }
        let secs = Int(Date().timeIntervalSince(spinnerStartedAt))
        let glyph = Self.spinnerGlyphs[secs % Self.spinnerGlyphs.count]
        // erase prior spinner frame and redraw
        if storage.length > lineStartLen {
            storage.deleteCharacters(in: NSRange(location: lineStartLen,
                                                 length: storage.length - lineStartLen))
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1),
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        ]
        storage.append(NSAttributedString(string: "  \(glyph) still working… \(secs)s",
                                          attributes: attrs))
        textView.scrollToEndOfDocument(nil)
    }

    private func eraseSpinner() {
        guard spinnerVisible, let storage = textView.textStorage else { return }
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

    // "still alive" spinner — shown as a ghost line after 2s of subprocess
    // silence (e.g. while pkg installer is unpacking). Erased the moment any
    // real output arrives or the process exits. Not written to the log.
    private var lastOutputAt: Date = Date()
    private var spinnerVisible: Bool = false
    private var spinnerStartedAt: Date = Date()
    private var heartbeat: Timer?
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
        .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1),
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
    ]

    func append(_ raw: String) {
        // any real output → clear the heartbeat spinner and reset its clock
        eraseSpinner()
        lastOutputAt = Date()

        let cleaned = Self.ansi.stringByReplacingMatches(
            in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{04}", with: "")   // PTY EOF control char
            .replacingOccurrences(of: "^D", with: "")       // PTY EOF display form
        guard let storage = textView.textStorage else { return }

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
        textView.scrollToEndOfDocument(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
