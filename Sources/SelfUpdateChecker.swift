import Foundation

/// Checks GitHub Releases for a newer build of UpdateAll itself.
///
/// Lifecycle:
///   - App launches → AppDelegate calls `checkIfDue()`. Throttled to once
///     per 24 h via a state file under ~/Library/Application Support/UpdateAll.
///   - User clicks "Check for app updates" in the SETTINGS sidebar → forces
///     an immediate check, shows the result in an NSAlert.
///   - If a newer release is available the sidebar row swaps to a banner
///     "Update available: vX.Y.Z" linking to the release page.
enum SelfUpdateChecker {
    static let repoOwner = "gupfe-priv-dev"
    static let repoName  = "apple-app-updater"

    struct LatestRelease: Decodable {
        let tag_name: String
        let html_url: String
        let name: String?
        let published_at: String?
    }

    private struct CachedState: Codable {
        var lastCheckEpoch: TimeInterval
        var latestTag: String?
        var htmlUrl: String?
    }

    private static var stateFile: String { AppPaths.state + "/self-update.json" }

    // MARK: Versions

    /// Current bundle version string (free-form, e.g. "1.3.1 (af7beba, …)").
    static func currentVersionRaw() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Just the semver portion ("1.3.1" out of "1.3.1 (af7beba, …)").
    static func currentSemver() -> String {
        let raw = currentVersionRaw()
        return raw.split(separator: " ").first.map(String.init) ?? raw
    }

    /// True iff `remote` is strictly newer than `current`. Strips a leading
    /// "v" on the remote tag; ignores pre-release suffixes after `-`.
    static func isNewer(remote: String, current: String) -> Bool {
        let r = parseSemver(remote)
        let c = parseSemver(current)
        for i in 0..<3 {
            if r[i] > c[i] { return true }
            if r[i] < c[i] { return false }
        }
        return false
    }

    private static func parseSemver(_ s: String) -> [Int] {
        var t = s
        if t.hasPrefix("v") { t.removeFirst() }
        let parts = t.split(separator: ".").map { seg -> Int in
            let core = seg.split(separator: "-").first.map(String.init) ?? "0"
            return Int(core) ?? 0
        }
        return [parts.first ?? 0,
                parts.count > 1 ? parts[1] : 0,
                parts.count > 2 ? parts[2] : 0]
    }

    // MARK: State

    static func loadState() -> (lastCheck: Date, cachedTag: String?, cachedURL: String?)? {
        guard let data = FileManager.default.contents(atPath: stateFile),
              let s = try? JSONDecoder().decode(CachedState.self, from: data) else { return nil }
        return (Date(timeIntervalSince1970: s.lastCheckEpoch), s.latestTag, s.htmlUrl)
    }

    static func saveState(latestTag: String?, htmlUrl: String?) {
        try? FileManager.default.createDirectory(atPath: AppPaths.state,
                                                 withIntermediateDirectories: true)
        let s = CachedState(lastCheckEpoch: Date().timeIntervalSince1970,
                            latestTag: latestTag, htmlUrl: htmlUrl)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: URL(fileURLWithPath: stateFile))
        }
    }

    // MARK: Fetch

    struct CheckError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Hit the GitHub Releases API via /usr/bin/curl. Blocking — call from a
    /// background queue. Uses an unauthenticated request (60 req/h per IP);
    /// our once-per-day cadence stays well under that.
    static func fetchLatest() -> Result<LatestRelease, CheckError> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = [
            "-sf", "-m", "10",
            "-H", "Accept: application/vnd.github+json",
            "-A", "UpdateAll/" + currentVersionRaw(),
            "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest",
        ]
        let out = Pipe()
        task.standardOutput = out
        task.standardError  = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                return .failure(CheckError(message: "curl exited \(task.terminationStatus) (no network?)"))
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let release = try JSONDecoder().decode(LatestRelease.self, from: data)
            return .success(release)
        } catch {
            return .failure(CheckError(message: error.localizedDescription))
        }
    }

    /// Fallback URL when we never managed to hit the API and the user clicks
    /// "Open release page".
    static var releasesURL: URL {
        URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest")!
    }
}
