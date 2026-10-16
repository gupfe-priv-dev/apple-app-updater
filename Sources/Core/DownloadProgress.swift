import Foundation

/// Turns a silent download into something you can watch.
///
/// A 750 MB cask download used to show nothing but a counting timer, which
/// reads the same as a hang. Homebrew hands the transfer to curl and curl
/// writes into `~/Library/Caches/Homebrew/downloads/<sha>--<name>.incomplete`,
/// so that file's growth *is* the progress — no extra network request, and it
/// works for whatever brew downloads, bottles and casks alike.
///
/// Two sources, because neither alone is enough:
///   * the `.incomplete` file gives bytes so far, and sampling it gives a rate;
///   * curl's `--progress-bar` (brew passes it whenever stdout is a tty, which
///     it is here — we run tools under script(1)) prints a percentage, and
///     bytes ÷ percent gives the total, hence a share done and an ETA.
///
/// When only the file is there we show size and rate; the percentage just adds
/// detail when it arrives.
@MainActor
final class DownloadWatcher {

    struct Snapshot {
        let name: String
        let bytes: Int64
        /// Only known once a percentage has been seen.
        let total: Int64?
        let bytesPerSecond: Double?
    }

    private let directory: String
    /// (sampled at, size) for the file currently growing, oldest first.
    private var samples: [(at: Date, bytes: Int64)] = []
    private var watchedPath: String?
    private var percent: (value: Double, at: Date)?

    /// A rate averaged over this window rather than over the last second: a
    /// one-second delta swings wildly enough to be unreadable.
    private let rateWindow: TimeInterval = 8
    /// Beyond this, output has moved on to something else (unpacking,
    /// installing) and a stale `.incomplete` file would keep claiming the
    /// status line.
    private let staleAfter: TimeInterval = 20

    init(directory: String = NSHomeDirectory() + "/Library/Caches/Homebrew/downloads") {
        self.directory = directory
    }

    /// Everything the run prints passes through here, looking for curl's
    /// percentage. Only the last one in the chunk matters — a chunk can carry
    /// several redraws of the bar.
    func noteOutput(_ chunk: String) {
        guard let v = Self.lastPercent(in: chunk) else { return }
        percent = (v, Date())
    }

    /// Forget everything. Called when a run starts or ends, so one run's
    /// numbers never leak into the next.
    func reset() {
        samples = []
        watchedPath = nil
        percent = nil
    }

    /// The current state of play, or nil when nothing is downloading.
    func sample() -> Snapshot? {
        let now = Date()
        guard let file = newestIncompleteFile() else {
            // Keep the samples: a download that briefly has no visible file
            // (curl renaming it on completion) shouldn't restart its rate.
            return nil
        }
        guard now.timeIntervalSince(file.modified) < staleAfter else { return nil }

        if file.path != watchedPath {         // a new download started
            watchedPath = file.path
            samples = []
            percent = nil
        }
        samples.append((now, file.size))
        samples.removeAll { now.timeIntervalSince($0.at) > rateWindow }

        // A percentage from before this download began says nothing about it.
        var share: Double?
        if let p = percent, now.timeIntervalSince(p.at) < staleAfter, p.value > 0.5 {
            share = p.value
        }
        let total = share.map { Int64(Double(file.size) / ($0 / 100)) }

        return Snapshot(name: Self.displayName(for: file.path),
                        bytes: file.size,
                        total: total,
                        bytesPerSecond: rate())
    }

    /// Needs two samples at least two seconds apart, or the number is noise.
    private func rate() -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let dt = last.at.timeIntervalSince(first.at)
        let db = last.bytes - first.bytes
        guard dt >= 2, db > 0 else { return nil }
        return Double(db) / dt
    }

    private struct Candidate { let path: String; let size: Int64; let modified: Date }

    /// The most recently written `.incomplete` file. Several can exist — brew
    /// leaves them behind when a download is interrupted — so the newest one
    /// is the only one that can be in flight.
    private func newestIncompleteFile() -> Candidate? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return nil }
        var best: Candidate?
        for name in names where name.hasSuffix(".incomplete") {
            let path = directory + "/" + name
            guard let a = try? fm.attributesOfItem(atPath: path),
                  let size = a[.size] as? Int64,
                  let modified = a[.modificationDate] as? Date else { continue }
            if best == nil || modified > best!.modified {
                best = Candidate(path: path, size: size, modified: modified)
            }
        }
        return best
    }

    // MARK: formatting ───────────────────────────────────────────────────

    /// `<64 hex chars>--LibreOffice_26.2_MacOS_aarch64.dmg.incomplete` →
    /// `LibreOffice_26.2_MacOS_aarch64.dmg`. The hash is noise on screen.
    static func displayName(for path: String) -> String {
        var n = (path as NSString).lastPathComponent
        if n.hasSuffix(".incomplete") { n = String(n.dropLast(".incomplete".count)) }
        if let sep = n.range(of: "--") { n = String(n[sep.upperBound...]) }
        return n
    }

    /// curl's bar is `####...####  45.2%`, redrawn with a carriage return.
    private static let percentPattern = try! NSRegularExpression(
        pattern: "([0-9]{1,3}\\.[0-9])%")

    static func lastPercent(in s: String) -> Double? {
        let r = NSRange(s.startIndex..., in: s)
        guard let m = percentPattern.matches(in: s, range: r).last,
              let range = Range(m.range(at: 1), in: s) else { return nil }
        guard let v = Double(s[range]), v >= 0, v <= 100 else { return nil }
        return v
    }

    /// Decimal units, matching what download sites and curl itself quote.
    static func bytes(_ n: Int64) -> String {
        let d = Double(n)
        if d >= 1_000_000_000 { return String(format: "%.1f GB", d / 1_000_000_000) }
        if d >= 1_000_000     { return String(format: "%.0f MB", d / 1_000_000) }
        if d >= 1_000         { return String(format: "%.0f KB", d / 1_000) }
        return "\(n) B"
    }

    static func rate(_ bps: Double) -> String {
        if bps >= 1_000_000 { return String(format: "%.1f MB/s", bps / 1_000_000) }
        if bps >= 1_000     { return String(format: "%.0f KB/s", bps / 1_000) }
        return String(format: "%.0f B/s", bps)
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        if s >= 60   { return "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }

    /// One line for the status bar. Every part is optional except the name and
    /// the bytes, because that is all we are ever certain of.
    static func statusLine(_ s: Snapshot) -> String {
        var text = "⬇ \(s.name) — \(bytes(s.bytes))"
        if let total = s.total, total > s.bytes {
            text += " of \(bytes(total))"
            text += String(format: " (%.0f%%)", Double(s.bytes) / Double(total) * 100)
        }
        if let r = s.bytesPerSecond {
            text += " · \(rate(r))"
            if let total = s.total, total > s.bytes, r > 0 {
                text += " · \(duration(Double(total - s.bytes) / r)) left"
            }
        }
        return text
    }
}
