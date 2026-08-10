import Foundation

/// Failure memory: the outcome of the last install attempt per (tool, item).
///
/// The point is the "false friend" — a package that shows up as outdated on
/// every single run because its update reliably fails (a cask whose app was
/// dragged to the Trash, a gem needing a toolchain that isn't there). Without
/// memory the user re-selects it every time and watches it fail again. With it,
/// the row arrives pre-flagged and unchecked, and they can decide once.
///
/// Stored as JSON next to the other app state so it survives rebuilds.
enum History {
    struct Attempt: Codable {
        var ok: Bool
        var exitCode: Int32
        var when: Date
    }

    private static var path: String { AppPaths.state + "/history.json" }

    /// Key is "<toolID>\u{1}<token>" — \u{1} can't occur in either half.
    private static func key(_ toolID: String, _ token: String) -> String {
        "\(toolID)\u{1}\(token)"
    }

    /// In-memory mirror so the table can flag hundreds of rows without hitting
    /// the disk once per row. Loaded lazily, written through on every record.
    private static var cache: [String: Attempt]?

    private static func load() -> [String: Attempt] {
        if let c = cache { return c }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = FileManager.default.contents(atPath: path) ?? Data()
        let loaded = (try? decoder.decode([String: Attempt].self, from: data)) ?? [:]
        cache = loaded
        return loaded
    }

    private static func save(_ map: [String: Attempt]) {
        cache = map
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(map) else { return }
        AppPaths.ensure()
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Record how an install attempt went. Successes are *removed* rather than
    /// stored — the only thing worth remembering is a failure, and clearing on
    /// success is what lets a fixed package stop being flagged.
    static func record(tool: String, token: String, ok: Bool, exitCode: Int32,
                       when: Date = Date()) {
        var map = load()
        if ok {
            map.removeValue(forKey: key(tool, token))
        } else {
            map[key(tool, token)] = Attempt(ok: false, exitCode: exitCode, when: when)
        }
        save(map)
    }

    /// The last recorded attempt, or nil if this item has never failed (or has
    /// succeeded since).
    static func lastFailure(tool: String, token: String) -> Attempt? {
        load()[key(tool, token)]
    }

    /// Forget one item's failure — the user's "I know, try it anyway".
    static func clear(tool: String, token: String) {
        var map = load()
        map.removeValue(forKey: key(tool, token))
        save(map)
    }

    static func clearAll() { save([:]) }

    static var failureCount: Int { load().count }

    /// "failed 3 days ago (exit 1)" — the flag text shown in the table.
    static func flagText(for attempt: Attempt) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .full
        let ago = fmt.localizedString(for: attempt.when, relativeTo: Date())
        return "failed \(ago) (exit \(attempt.exitCode))"
    }
}
