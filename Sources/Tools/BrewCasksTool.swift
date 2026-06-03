import Foundation

/// Homebrew casks. Core path: `brew outdated --cask --greedy` / `brew upgrade
/// --cask --greedy`. Drift recovery, stuck-keg cleanup, quarantine stripping
/// and the safe-cask install offer are layered on in Phase 4.
struct BrewCasksTool: Tool {
    let id = "brew-casks"
    let title = "Homebrew — casks"
    func isAvailable() -> Bool { commandExists("brew") }

    func scan(_ ctx: RunContext) async -> ScanResult {
        let r = await ctx.capture(["brew", "outdated", "--cask", "--greedy", "--quiet"])
        let items = r.output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { UpdateItem($0) }
        return .from(items)
    }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        let status = await ctx.run(["brew", "upgrade", "--cask", "--greedy", "--quiet"])
        // Strip the Gatekeeper quarantine flag so freshly-installed casks don't
        // trigger the "verifying…" dialog on first launch.
        _ = await ctx.capture(["/bin/sh", "-c",
            "find /Applications -maxdepth 2 -name '*.app' -print0 2>/dev/null | " +
            "xargs -0 -P 8 -I{} sh -c 'xattr -p com.apple.quarantine \"$1\" >/dev/null 2>&1 && " +
            "xattr -dr com.apple.quarantine \"$1\" 2>/dev/null; true' _ {}"])
        return status == 0 ? .ok : .failed("brew upgrade --cask exited \(status)")
    }
}
