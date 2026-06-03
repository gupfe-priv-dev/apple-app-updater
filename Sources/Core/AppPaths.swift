import Foundation

/// Canonical on-disk locations for UpdateAll's state and cache. Kept OUT of the
/// .app bundle so rebuilds don't wipe them and writes don't break the bundle's
/// code signature.
enum AppPaths {
    static var state: String { NSHomeDirectory() + "/Library/Application Support/UpdateAll" }
    static var cache: String { NSHomeDirectory() + "/Library/Caches/UpdateAll" }
    static var registry: String { state + "/apps.json" }

    /// Make sure both directories exist. Safe to call repeatedly.
    static func ensure() {
        for d in [state, cache] {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
    }

    /// Environment additions the bundled Python bridges expect.
    static func bridgeEnv() -> [String: String] {
        ["_STATE_DIR": state, "_CACHE_DIR": cache]
    }
}
