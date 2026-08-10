import Foundation

/// Lightweight UserDefaults-backed preferences: which tools the user disabled
/// (scan/install skip them entirely) and which individual packages are hidden.
enum Settings {
    private static let disabledKey = "disabledToolIDs"
    private static let excludeKey  = "excludedItems"
    private static let splitKey    = "consoleHeight"
    private static let defaults = UserDefaults.standard

    // MARK: tools ────────────────────────────────────────────────────────

    static var disabledToolIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: disabledKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: disabledKey) }
    }

    static func isEnabled(_ toolID: String) -> Bool { !disabledToolIDs.contains(toolID) }

    static func setEnabled(_ toolID: String, _ enabled: Bool) {
        var s = disabledToolIDs
        if enabled { s.remove(toolID) } else { s.insert(toolID) }
        disabledToolIDs = s
    }

    // MARK: excluded packages ────────────────────────────────────────────
    // A package whose update reliably prompts, hangs, or is simply unwanted.
    // Excluding drops it from the table entirely rather than leaving a row the
    // user has to remember to uncheck on every run.

    /// Stored as "<toolID>/<token>" so the Settings tab can show a readable,
    /// hand-editable list.
    static func excludeKeyFor(_ toolID: String, _ token: String) -> String {
        "\(toolID)/\(token)"
    }

    static var excludedItems: Set<String> {
        get { Set(defaults.stringArray(forKey: excludeKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: excludeKey) }
    }

    static func isExcluded(_ toolID: String, _ token: String) -> Bool {
        excludedItems.contains(excludeKeyFor(toolID, token))
    }

    static func exclude(_ toolID: String, _ token: String) {
        var s = excludedItems
        s.insert(excludeKeyFor(toolID, token))
        excludedItems = s
        NotificationCenter.default.post(name: .excludedItemsChanged, object: nil)
    }

    static func unexclude(_ entry: String) {
        var s = excludedItems
        s.remove(entry)
        excludedItems = s
        NotificationCenter.default.post(name: .excludedItemsChanged, object: nil)
    }

    // MARK: behaviour ────────────────────────────────────────────────────

    private static let scanOnLaunchKey = "scanOnLaunch"

    /// Scan automatically when the app opens. On by default — UpdateAll runs at
    /// login, and a launch that reports nothing until you press a button would
    /// miss the point. Off is for anyone who wants it purely on demand (and
    /// makes a rebuild-test loop much faster).
    static var scanOnLaunch: Bool {
        get {
            guard defaults.object(forKey: scanOnLaunchKey) != nil else { return true }
            return defaults.bool(forKey: scanOnLaunchKey)
        }
        set { defaults.set(newValue, forKey: scanOnLaunchKey) }
    }

    // MARK: layout ───────────────────────────────────────────────────────

    /// Remembered console height so the split doesn't reset every launch.
    static var consoleHeight: CGFloat {
        get {
            let v = defaults.double(forKey: splitKey)
            return v > 60 ? CGFloat(v) : 220
        }
        set { defaults.set(Double(newValue), forKey: splitKey) }
    }
}

extension Notification.Name {
    /// The hidden-package list changed. The updates table listens so that
    /// unhiding something puts its row back immediately, rather than leaving
    /// the user to guess that a re-scan is needed.
    static let excludedItemsChanged = Notification.Name("UpdateAll.excludedItemsChanged")
}
