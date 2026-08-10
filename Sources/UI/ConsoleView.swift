import AppKit

/// The single output console. One buffer for the whole run — every tool writes
/// here in order, separated by its own header — which is the point: one place
/// to look, and Cmd+F finds anything the run said.
///
/// Handles the two things raw CLI output does that a plain text view can't:
/// ANSI escapes (stripped) and carriage returns (Homebrew's download progress
/// redraws its line with `\r`, so we overwrite in place instead of printing a
/// hundred near-identical lines).
@MainActor
final class ConsoleView: NSView {
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private let storage = NSTextStorage()

    /// Byte offset where the in-progress line starts, so a `\r` knows how much
    /// to erase.
    private var lineStartLen: Int = 0
    /// Only completed lines go to the log file — the log shouldn't collect
    /// hundreds of progress-bar ticks.
    private var pendingLogLine: String = ""
    private var logHandle: FileHandle?

    private static let ansi = try! NSRegularExpression(
        pattern: "\u{1b}\\[[0-9;]*[mGKHFABCDJsu]")

    private static let textAttrs: [NSAttributedString.Key: Any] = [
        // labelColor adapts to light/dark so the console reads in both
        .foregroundColor: NSColor.labelColor,
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
    ]
    private static let headerAttrs: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.controlAccentColor,
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
    ]
    private static let mutedAttrs: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.secondaryLabelColor,
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.autoresizingMask = .width
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.replaceTextStorage(storage)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = textView

        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: writing ──────────────────────────────────────────────────────

    /// Whether the view is scrolled to (or very near) the bottom. Only then do
    /// we auto-follow — a user who scrolled up to read something shouldn't be
    /// yanked back down by the next line of output.
    private var isAtBottom: Bool {
        let visible = scroll.contentView.documentVisibleRect
        let height = textView.bounds.height
        return visible.maxY >= height - 24
    }

    /// A tool is starting — write its banner.
    func writeHeader(_ title: String) {
        let follow = isAtBottom
        if storage.length > 0 {
            storage.append(NSAttributedString(string: "\n", attributes: Self.textAttrs))
        }
        storage.append(NSAttributedString(string: "==> \(title)\n", attributes: Self.headerAttrs))
        lineStartLen = storage.length
        writeLog("\n==> \(title)\n")
        if follow { textView.scrollToEndOfDocument(nil) }
    }

    /// A de-emphasised note (skips, summaries) that isn't tool output.
    func writeNote(_ text: String) {
        let follow = isAtBottom
        storage.append(NSAttributedString(string: text + "\n", attributes: Self.mutedAttrs))
        lineStartLen = storage.length
        writeLog(text + "\n")
        if follow { textView.scrollToEndOfDocument(nil) }
    }

    /// Raw streamed output from a subprocess.
    func append(_ raw: String) {
        // Treat "cursor to column 1" (ESC[G / ESC[0G / ESC[1G) as a carriage
        // return so a progress bar that redraws with it (instead of \r) still
        // overwrites its line in place rather than appending.
        let normalized = raw
            .replacingOccurrences(of: "\u{1b}[G",  with: "\r")
            .replacingOccurrences(of: "\u{1b}[0G", with: "\r")
            .replacingOccurrences(of: "\u{1b}[1G", with: "\r")
        let cleaned = Self.ansi.stringByReplacingMatches(
            in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{04}", with: "")   // PTY EOF control char
            .replacingOccurrences(of: "^D", with: "")       // PTY EOF display form

        let follow = isAtBottom
        var i = cleaned.startIndex
        while i < cleaned.endIndex {
            switch cleaned[i] {
            case "\r":
                // overwrite: erase the visible content of the current line
                if storage.length > lineStartLen {
                    storage.deleteCharacters(in: NSRange(
                        location: lineStartLen, length: storage.length - lineStartLen))
                }
                pendingLogLine = ""
                i = cleaned.index(after: i)
            case "\n":
                storage.append(NSAttributedString(string: "\n", attributes: Self.textAttrs))
                pendingLogLine.append("\n")
                writeLog(pendingLogLine)
                pendingLogLine = ""
                lineStartLen = storage.length
                i = cleaned.index(after: i)
            default:
                // batch consecutive printable chars into one append
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
        if follow { textView.scrollToEndOfDocument(nil) }
    }

    func clear() {
        storage.setAttributedString(NSAttributedString(string: ""))
        lineStartLen = 0
        pendingLogLine = ""
    }

    var isEmpty: Bool { storage.length == 0 }

    // MARK: log file ─────────────────────────────────────────────────────

    private static var logPath: String {
        NSHomeDirectory() + "/Library/Logs/update-all.log"
    }

    private func writeLog(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        logHandle?.write(data)
    }

    /// Open (and rotate) the run log. Called at the start of every run.
    func startLogging() {
        let dir = NSHomeDirectory() + "/Library/Logs"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        rotateLog(atPath: Self.logPath, keep: 4)   // we're about to write the 5th
        if !FileManager.default.fileExists(atPath: Self.logPath) {
            FileManager.default.createFile(atPath: Self.logPath, contents: nil)
        }
        logHandle = FileHandle(forWritingAtPath: Self.logPath)
        logHandle?.seekToEndOfFile()
        let fmt = ISO8601DateFormatter()
        writeLog("\n==== UpdateAll run \(fmt.string(from: Date())) ====\n")
    }

    /// Keep at most `keep` prior runs in the log. Each run begins with
    /// "==== UpdateAll run <ISO> ====" on its own line — find those markers
    /// and drop everything before the `keep`-th from the end.
    private func rotateLog(atPath path: String, keep: Int) {
        guard let existing = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = existing.components(separatedBy: "\n")
        var headerIndexes: [Int] = []
        for (i, line) in lines.enumerated() where line.hasPrefix("==== UpdateAll run ") {
            headerIndexes.append(i)
        }
        guard headerIndexes.count > keep else { return }
        let dropBefore = headerIndexes[headerIndexes.count - keep]
        let trimmed = lines[dropBefore...].joined(separator: "\n")
        try? trimmed.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func revealLogInFinder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }
}
