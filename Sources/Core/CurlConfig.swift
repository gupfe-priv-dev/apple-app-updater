import Foundation

/// The curl configuration UpdateAll hands to its own `brew` downloads.
///
/// Homebrew shells out to curl for every download, and passes
/// `--disable --config <path>` when `HOMEBREW_CURLRC` names an absolute path
/// (see `Library/Homebrew/utils/curl.rb`). That is the only supported way to
/// give brew's downloads a timeout: a cask has exactly one URL — no `mirror`
/// stanza, no fallback list — so when its host stalls there is nothing to fall
/// back to, and without a guard the run simply hangs behind it.
///
/// Scope matters here. `HOMEBREW_CURLRC` is set on the brew *child process*
/// only. Nothing is written to a shell profile, no global Homebrew setting is
/// touched, and the user's own `brew` in a terminal behaves exactly as before.
enum CurlConfig {
    static var path: String { AppPaths.state + "/brew-curlrc" }

    /// Environment additions for a brew invocation that downloads. Empty when
    /// the guard is off, which leaves Homebrew's own default (`--disable`, no
    /// curlrc) exactly as it was.
    /// The existence check is not paranoia. Homebrew passes `--config` to
    /// *every* curl call including `curl --version`, so pointing
    /// HOMEBREW_CURLRC at a file that isn't there doesn't merely skip the
    /// guard — it fails brew outright with "Failed to parse curl version",
    /// before it gets anywhere near a download. Better no guard than no brew.
    static func env() -> [String: String] {
        guard Settings.downloadGuardEnabled,
              let p = write(),
              FileManager.default.fileExists(atPath: p) else { return [:] }
        return ["HOMEBREW_CURLRC": p]
    }

    /// Rewrite the file from the current settings. Returns the path, or nil if
    /// it couldn't be written — in which case brew just runs unguarded, which
    /// is the old behaviour rather than a failure.
    @discardableResult
    static func write() -> String? {
        AppPaths.ensure()
        // Deliberately no `max-time`. A total cap can't tell a slow download
        // from a dead one, and would kill a 285 MB DMG on a hotel line at the
        // 90% mark. `speed-limit`/`speed-time` abort only a transfer that is
        // genuinely going nowhere, which is the case that actually hurts.
        let body = """
        # Written by UpdateAll — Settings → General → Downloads.
        # Applies to UpdateAll's own brew runs only: HOMEBREW_CURLRC is set on
        # the child process, so `brew` in your terminal is unaffected.
        connect-timeout = \(Settings.downloadConnectTimeout)
        speed-limit = \(Settings.downloadSpeedFloorKBps * 1024)
        speed-time = \(Settings.downloadStallSeconds)

        """
        do {
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            return nil
        }
    }

    /// One-line description of the active guard, for the console.
    static var summary: String {
        guard Settings.downloadGuardEnabled else { return "download stall guard: off" }
        return "download stall guard: abort below \(Settings.downloadSpeedFloorKBps) KB/s "
             + "for \(Settings.downloadStallSeconds)s"
    }
}

/// Environment for brew invocations that download.
enum BrewEnv {
    static func download() -> [String: String] {
        var env = ["HOMEBREW_DOWNLOAD_CONCURRENCY": "1"]
        env.merge(CurlConfig.env()) { _, new in new }
        return env
    }
}
