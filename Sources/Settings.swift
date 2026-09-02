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

    // MARK: downloads ────────────────────────────────────────────────────
    // A cask has one URL and no mirror list, so a stalled host can't be routed
    // around — it can only be given up on. These feed the curl config handed to
    // UpdateAll's own brew runs (see CurlConfig); they are not global Homebrew
    // settings and don't affect `brew` in a terminal.

    private static let dlGuardKey   = "downloadGuardEnabled"
    private static let dlFloorKey   = "downloadSpeedFloorKBps"
    private static let dlStallKey   = "downloadStallSeconds"
    private static let dlConnectKey = "downloadConnectTimeout"

    /// On by default: without it, one dead mirror blocks every package queued
    /// behind it for as long as the user is willing to wait.
    static var downloadGuardEnabled: Bool {
        get { defaults.object(forKey: dlGuardKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: dlGuardKey); CurlConfig.write() }
    }

    /// Throughput floor, KB/s. Below this for `downloadStallSeconds`, curl aborts.
    ///
    /// Deliberately low. The failure worth catching is a transfer going
    /// *nowhere*, which sits at 0 B/s; "slow" is not the same thing and is
    /// usually recoverable. A 50 KB/s floor aborted real ghcr.io downloads —
    /// a bottle manifest and an openssl blob in one run — because curl measures
    /// the average over the whole transfer, so a server that takes its time
    /// answering drags a small file under the floor no matter how quickly the
    /// bytes themselves would arrive.
    ///
    /// It still needs margin over the rate worth rejecting, though: measured
    /// against a 4.8 KB/s crawl, a 5 KB/s floor never fires, because the
    /// bursts keep nudging the average back over the line and the timer
    /// restarts. 10 KB/s catches that crawl in 61s and leaves healthy traffic
    /// alone. Below it, a large download would take many hours.
    static var downloadSpeedFloorKBps: Int {
        get { migrated(); return defaults.object(forKey: dlFloorKey) as? Int ?? 10 }
        set { defaults.set(newValue, forKey: dlFloorKey); CurlConfig.write() }
    }

    /// How long throughput may stay under the floor before giving up.
    static var downloadStallSeconds: Int {
        get { migrated(); return defaults.object(forKey: dlStallKey) as? Int ?? 60 }
        set { defaults.set(newValue, forKey: dlStallKey); CurlConfig.write() }
    }

    /// Settings stored before the floor was lowered keep their old, too-strict
    /// values — a new default only applies where nothing was saved. Anything
    /// from the old range is moved onto the new scale once.
    private static let dlSchemaKey = "downloadGuardSchema"
    private static func migrated() {
        guard defaults.integer(forKey: dlSchemaKey) < 2 else { return }
        defaults.set(2, forKey: dlSchemaKey)
        // Every value on the old scale was chosen against a 50 KB/s ladder, so
        // none of them mean what they used to. Move any stored pair onto the
        // new default rather than trying to map old intent onto a new axis.
        guard defaults.object(forKey: dlFloorKey) != nil else { return }
        defaults.set(10, forKey: dlFloorKey)
        defaults.set(60, forKey: dlStallKey)
    }

    /// Cap on the TCP/TLS connect phase. The LibreOffice mirror connected in
    /// 40 ms and then never completed its TLS handshake, so this is the guard
    /// that catches a host which accepts a socket and then goes silent.
    static var downloadConnectTimeout: Int {
        get { defaults.object(forKey: dlConnectKey) as? Int ?? 15 }
        set { defaults.set(newValue, forKey: dlConnectKey); CurlConfig.write() }
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
