import Foundation

/// Something UpdateAll noticed during a run and thinks is worth mentioning,
/// usually alongside the setting that can act on it.
///
/// Deliberately not an alert. These arise *while* an update is running, and a
/// modal sheet would interrupt the very thing the user asked for — to say
/// something that isn't urgent. A tip waits in the action bar until it's read.
struct Tip {
    /// Dedupe key: one tip per cause, however often the cause recurs.
    let id: String
    let text: String
    /// The settings pane that can act on it, when there is one.
    let section: SettingsPane.Section?
}

@MainActor
enum Tips {
    static let changed = Notification.Name("UpdateAllTipsChanged")

    private(set) static var all: [Tip] = []

    static func post(_ tip: Tip) {
        guard !all.contains(where: { $0.id == tip.id }) else { return }
        all.append(tip)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Post from a tool, which runs off the main actor.
    nonisolated static func postAsync(_ tip: Tip) {
        Task { @MainActor in post(tip) }
    }

    static func dismiss(_ id: String) {
        guard all.contains(where: { $0.id == id }) else { return }
        all.removeAll { $0.id == id }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func clear() {
        guard !all.isEmpty else { return }
        all.removeAll()
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
