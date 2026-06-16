import Foundation

/// brew 4.6+ requires explicit "tap trust" before loading formulae/casks from
/// non-official taps. Without it, `brew outdated` silently hides anything from
/// untrusted taps and `brew info` refuses to load them — they look gone.
///
/// We auto-trust only what's *already installed* from each non-official tap
/// (matching the per-formula recommendation in brew's warning text). The trust
/// list persists in `~/.homebrew/trust.json`, so calls after the first one are
/// no-ops.
enum BrewTapTrust {
    static func ensure(_ ctx: RunContext) async {
        async let formulae = ctx.capture(["brew", "list", "--formula"])
        async let casks    = ctx.capture(["brew", "list", "--cask"])
        async let info     = ctx.capture(["brew", "tap-info", "--json", "--installed"])
        let (f, c, t) = await (formulae, casks, info)

        let installedFormulae = Set(f.output.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        let installedCasks = Set(c.output.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })

        guard let data = t.output.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }

        for tap in arr {
            guard let tapName = tap["name"] as? String else { continue }
            if tapName == "homebrew/core" || tapName == "homebrew/cask" { continue }
            for full in (tap["formula_names"] as? [String]) ?? [] {
                let short = String(full.split(separator: "/").last ?? Substring(full))
                if installedFormulae.contains(short) {
                    _ = await ctx.capture(["brew", "trust", "--formula", full])
                }
            }
            for full in (tap["cask_tokens"] as? [String]) ?? [] {
                let short = String(full.split(separator: "/").last ?? Substring(full))
                if installedCasks.contains(short) {
                    _ = await ctx.capture(["brew", "trust", "--cask", full])
                }
            }
        }
    }
}
