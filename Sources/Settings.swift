import Foundation

/// Lightweight UserDefaults-backed preferences. Currently: which tools the
/// user has disabled (so the scan/install skip them entirely). A disabled
/// tool stays visible in the sidebar but greyed, with no work done.
enum Settings {
    private static let disabledKey = "disabledToolIDs"
    private static let defaults = UserDefaults.standard

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
}
