import Foundation

/// One available update surfaced by a tool's scan.
struct UpdateItem {
    var name: String       // display name, e.g. "google-chrome"
    /// Identifier the manager's CLI actually takes on the command line — a cask
    /// token, an npm package name, an App Store numeric id. Usually identical to
    /// `name`; differs where the display name isn't addressable (mas).
    var token: String
    var current: String?   // installed version, if known
    var latest: String?    // available version, if known
    var detail: String?    // freeform extra (app path, note, …)

    init(_ name: String, token: String? = nil, current: String? = nil,
         latest: String? = nil, detail: String? = nil) {
        self.name = name
        self.token = token ?? name
        self.current = current; self.latest = latest; self.detail = detail
    }

    /// One-line summary for compact contexts (menus, logs).
    var summary: String {
        switch (current, latest) {
        case let (c?, l?) where c != l: return "\(name)  \(c) → \(l)"
        case let (_, l?):               return "\(name)  \(l)"
        default:                        return name
        }
    }
}

/// Result of scanning a single tool for available updates.
struct ScanResult {
    enum State {
        case upToDate      // tool present, nothing to do
        case hasUpdates    // tool present, items.count updates available
        case unavailable   // tool not installed → section skipped/greyed
        case unknown       // tool present but can't determine (e.g. pipx/claude)
    }
    var state: State
    var items: [UpdateItem]
    var note: String?      // shown when state == .unknown or as extra context

    init(state: State, items: [UpdateItem] = [], note: String? = nil) {
        self.state = state; self.items = items; self.note = note
    }

    static let upToDate     = ScanResult(state: .upToDate)
    static let unavailable  = ScanResult(state: .unavailable)
    static func unknown(_ note: String) -> ScanResult { ScanResult(state: .unknown, note: note) }
    /// upToDate when empty, hasUpdates otherwise.
    static func from(_ items: [UpdateItem]) -> ScanResult {
        items.isEmpty ? .upToDate : ScanResult(state: .hasUpdates, items: items)
    }

    var updateCount: Int { state == .hasUpdates ? items.count : 0 }
}

/// Outcome of an install run for a single tool.
struct InstallOutcome {
    enum State { case ok, skipped, failed, unavailable }
    var state: State
    var message: String?
    /// Tokens that failed individually while the run as a whole still counts as
    /// ok (brew casks upgrade one token per command, so a single bad download
    /// shouldn't fail the section). Feeds the per-row failure memory.
    var failedItems: [String]

    init(_ state: State, _ message: String? = nil, failedItems: [String] = []) {
        self.state = state; self.message = message; self.failedItems = failedItems
    }

    static let ok          = InstallOutcome(.ok)
    static let unavailable = InstallOutcome(.unavailable)
    static func skipped(_ m: String? = nil) -> InstallOutcome { InstallOutcome(.skipped, m) }
    static func failed(_ m: String? = nil)  -> InstallOutcome { InstallOutcome(.failed, m) }
    /// Section succeeded overall, but these tokens didn't.
    static func partial(_ failed: [String]) -> InstallOutcome {
        InstallOutcome(.ok, nil, failedItems: failed)
    }
}
