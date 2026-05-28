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
        runScript()
    }

    func buildMenu() {
        let main = NSMenu()

        // Application menu (first item — title shown as app name)
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Update All", action: nil, keyEquivalent: "")
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
        window.backgroundColor = .black
        window.center()

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        textView = NSTextView()
        textView.isEditable = false
        textView.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
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
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -8),
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
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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
    }

    // strip ANSI escape codes
    private static let ansi = try! NSRegularExpression(pattern: "\u{1b}\\[[0-9;]*[mGKHFABCDJsu]")

    private var logHandle: FileHandle?

    func openLog() {
        let dir = NSHomeDirectory() + "/Library/Logs"
        let path = dir + "/update-all.log"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        logHandle = FileHandle(forWritingAtPath: path)
        logHandle?.seekToEndOfFile()
        let fmt = ISO8601DateFormatter()
        let header = "\n==== UpdateAll run \(fmt.string(from: Date())) ====\n"
        logHandle?.write(header.data(using: .utf8)!)
    }

    func append(_ raw: String) {
        let clean = Self.ansi.stringByReplacingMatches(
            in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{04}", with: "")   // strip PTY EOF control char
            .replacingOccurrences(of: "^D", with: "")       // strip PTY EOF display form
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1),
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        ]
        textView.textStorage?.append(NSAttributedString(string: clean, attributes: attrs))
        textView.scrollToEndOfDocument(nil)
        if let data = clean.data(using: .utf8) {
            logHandle?.write(data)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
