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

    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }

    struct LatestRelease: Decodable {
        let tag_name: String
        let html_url: String
        let name: String?
        let published_at: String?
        /// The built .app, zipped by the release workflow. Absent on a release
        /// published without artifacts, in which case we can only link.
        let assets: [Asset]

        var appZip: Asset? { assets.first { $0.name.hasSuffix(".zip") } }
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

    /// True iff `remote` is strictly newer than `current`.
    ///
    /// Follows semver's pre-release rule, which matters here because every local
    /// build is a pre-release: 1.4.9-preview.3 is newer than 1.4.8 but older
    /// than 1.4.9. Comparing only the numbers would make a preview and its own
    /// release look identical, so the preview would never be offered the release
    /// it was previewing.
    static func isNewer(remote: String, current: String) -> Bool {
        let r = parseSemver(remote)
        let c = parseSemver(current)
        for i in 0..<3 {
            if r[i] > c[i] { return true }
            if r[i] < c[i] { return false }
        }
        // Same numbers: a release beats a pre-release of itself, and nothing
        // beats a release.
        return !isPrerelease(remote) && isPrerelease(current)
    }

    /// Does this version carry a pre-release suffix ("1.4.9-preview.3")?
    private static func isPrerelease(_ s: String) -> Bool {
        var t = s
        if t.hasPrefix("v") { t.removeFirst() }
        // Only after the patch segment — a "-" earlier would be malformed.
        return t.split(separator: ".").dropFirst(2).first?.contains("-") ?? false
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
                // 22 is curl's "HTTP error" under -f. The overwhelmingly common
                // cause here is GitHub's 60-requests-an-hour limit for
                // unauthenticated callers, which is worth naming rather than
                // reporting as a bare exit code.
                let why = task.terminationStatus == 22
                    ? "GitHub refused the request — most likely its hourly rate limit. Try again later."
                    : "curl exited \(task.terminationStatus) (no network?)"
                return .failure(CheckError(message: why))
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

    // MARK: Install

    /// Where the updater script records what it did.
    static var updateLogPath: String {
        NSHomeDirectory() + "/Library/Logs/update-all-selfupdate.log"
    }

    /// Write the updater script, start it detached, and let the caller quit.
    ///
    /// An app can't cleanly replace its own bundle while it's running, so the
    /// work happens outside it: the script waits for us to exit, downloads the
    /// release asset, swaps the bundle, and reopens the app.
    ///
    /// It runs headless rather than in Terminal. Terminal leaves its window
    /// sitting there afterwards — its "close on exit" behaviour is a per-profile
    /// setting we don't control — so the update ended with a stray window to
    /// tidy up every time. The whole thing takes a couple of seconds, so there
    /// is little to watch; it logs to `updateLogPath` for when something goes
    /// wrong, and restores the previous bundle if it does.
    ///
    /// It fetches the asset URL resolved from the Releases API rather than
    /// piping a remote script into bash — one less thing to trust.
    /// Returns nil on success, or why it couldn't start.
    static func launchUpdater(for release: LatestRelease, appPath: String) -> String? {
        guard let asset = release.appZip else {
            return "That release has no .zip asset to install."
        }
        let script = """
        #!/bin/bash
        set -euo pipefail
        exec >>"\(updateLogPath)" 2>&1
        echo "=== $(date '+%Y-%m-%d %H:%M:%S')  UpdateAll → \(release.tag_name) ==="
        echo "Target: \(appPath)"

        # The app quits itself as it hands over; don't touch the bundle until it has.
        for _ in $(seq 1 40); do
            pgrep -x UpdateAll >/dev/null 2>&1 || break
            sleep 0.25
        done

        TMP=$(mktemp -d)
        trap 'rm -rf "$TMP"' EXIT

        echo "Downloading \(asset.name)…"
        curl -fL -sS -o "$TMP/app.zip" "\(asset.browser_download_url)"

        echo "Unpacking…"
        ditto -x -k "$TMP/app.zip" "$TMP/x"
        NEW=$(find "$TMP/x" -maxdepth 2 -name '*.app' -print -quit)
        [ -n "$NEW" ] || { echo "No .app inside the archive — aborting."; exit 1; }

        # Downloads carry the quarantine flag; without this the first launch is
        # blocked by Gatekeeper.
        xattr -dr com.apple.quarantine "$NEW" 2>/dev/null || true

        echo "Installing…"
        # Keep the old bundle until the new one is in place, so a failure here
        # doesn't leave you with no app at all.
        BACKUP="$TMP/previous.app"
        if [ -d "\(appPath)" ]; then mv "\(appPath)" "$BACKUP"; fi
        if ! ditto "$NEW" "\(appPath)"; then
            echo "Install failed — putting the previous version back."
            rm -rf "\(appPath)"
            [ -d "$BACKUP" ] && mv "$BACKUP" "\(appPath)"
            exit 1
        fi

        echo
        echo "Done. Reopening UpdateAll…"
        open "\(appPath)"
        """

        let path = NSTemporaryDirectory() + "update-updateall-\(UUID().uuidString).command"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: path)
        } catch {
            return "Couldn't write the updater script: \(error.localizedDescription)"
        }

        // Detached with nohup and a trailing & so it outlives this process —
        // it has to, since its first job is to wait for us to exit.
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/bin/sh")
        launch.arguments = ["-c", "nohup /bin/bash '\(path)' >/dev/null 2>&1 &"]
        do { try launch.run() } catch {
            return "Couldn't start the updater: \(error.localizedDescription)"
        }
        return nil
    }
}
