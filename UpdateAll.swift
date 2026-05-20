import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var textView: NSTextView!
    var closeButton: NSButton!

    func applicationDidFinishLaunching(_ note: Notification) {
        buildWindow()
        runScript()
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

        let content = window.contentView!
        content.addSubview(scroll)
        content.addSubview(closeButton)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -8),
            closeButton.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            closeButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 120),
        ])

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quit() { NSApp.terminate(nil) }

    var scriptPath: String {
        let appDir = Bundle.main.bundlePath
        let parent = (appDir as NSString).deletingLastPathComponent
        return (parent as NSString).appendingPathComponent("update-all.sh")
    }

    func runScript() {
        let proc = Process()
        // script(1) allocates a pseudo-TTY so sudo/Touch ID can prompt properly
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        proc.arguments = ["-q", "/dev/null", "/bin/zsh", scriptPath]
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLUMNS"] = "110"
        env["LINES"] = "40"
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.append(text) }
        }

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.append("\n\nDone.")
                self?.closeButton.isHidden = false
            }
        }

        try? proc.run()
    }

    // strip ANSI escape codes
    private static let ansi = try! NSRegularExpression(pattern: "\u{1b}\\[[0-9;]*[mGKHFABCDJsu]")

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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
