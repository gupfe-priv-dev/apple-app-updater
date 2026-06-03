import Foundation

/// App registry: scans /Applications vs brew/mas, classifies unmanaged apps
/// (sparkle/electron/unmanaged), maintains apps.json, and surfaces brew-cask
/// suggestions. Currently bridges to the bundled registry.py; ported to Swift
/// in Phase 4. On install it also offers to install "safe" cask matches.
struct RegistryTool: Tool {
    let id = "registry"
    let title = "App registry"
    func isAvailable() -> Bool { true }

    private var scriptPath: String? { Bundle.main.path(forResource: "registry", ofType: "py") }

    func scan(_ ctx: RunContext) async -> ScanResult {
        guard let script = scriptPath else { ctx.line("✗ registry.py missing"); return .unknown("registry helper missing") }
        AppPaths.ensure()
        _ = await ctx.run(["python3", script], env: AppPaths.bridgeEnv())
        // Registry maintenance isn't an "update" — report informational/green.
        return .upToDate
    }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        guard let script = scriptPath else { return .unavailable }
        AppPaths.ensure()
        let safeList = NSTemporaryDirectory() + "ua-safe-casks-\(ProcessInfo.processInfo.processIdentifier).txt"
        try? FileManager.default.removeItem(atPath: safeList)
        var env = AppPaths.bridgeEnv()
        env["_BREW_SAFE_LIST"] = safeList
        _ = await ctx.run(["python3", script], env: env)

        // Offer to install each "safe" (same-or-newer) cask match, inline.
        guard let listText = try? String(contentsOfFile: safeList, encoding: .utf8) else { return .ok }
        try? FileManager.default.removeItem(atPath: safeList)
        let tokens = listText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return .ok }

        var declined: [String] = []
        for token in tokens {
            if await ctx.ask("Install brew cask “\(token)”? (No = don't offer it again)") {
                ctx.line("→ brew install --cask --force --quiet \(token)")
                let status = await ctx.run(["brew", "install", "--cask", "--force", "--quiet", token])
                if status != 0 { ctx.line("✗ install failed for \(token) (continuing)") }
            } else {
                declined.append(token)
            }
        }
        if !declined.isEmpty { persistDeclines(declined, ctx) }
        return .ok
    }

    /// Append declined cask tokens to declined-casks.json so they aren't
    /// re-offered. Mirrors the old shell decline-list behavior.
    private func persistDeclines(_ tokens: [String], _ ctx: RunContext) {
        let path = AppPaths.state + "/declined-casks.json"
        var existing = Set<String>()
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            existing = Set(arr)
        }
        existing.formUnion(tokens)
        if let out = try? JSONSerialization.data(withJSONObject: existing.sorted(),
                                                 options: [.prettyPrinted]) {
            try? out.write(to: URL(fileURLWithPath: path))
        }
        ctx.line("↳ Won't re-offer: \(tokens.joined(separator: ", "))")
    }
}
