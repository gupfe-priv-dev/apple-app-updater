import Foundation

/// App registry: scans /Applications vs brew/mas, classifies unmanaged apps
/// (sparkle/electron/unmanaged), maintains apps.json, and surfaces brew-cask
/// suggestions. On install it offers to install "safe" (same-or-newer) cask
/// matches via inline prompts. Native (Registry + CaskCatalog).
struct RegistryTool: Tool {
    let id = "registry"
    let title = "App registry"
    /// Shared across this tool's scan/install calls (toolList holds one instance).
    private let catalog = CaskCatalog()

    func isAvailable() -> Bool { true }

    func scan(_ ctx: RunContext) async -> ScanResult {
        AppPaths.ensure()
        catalog.load { ctx.emit($0) }
        _ = Registry.sync(catalog: catalog) { ctx.emit($0) }
        return .upToDate   // registry maintenance isn't an "update"
    }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        AppPaths.ensure()
        catalog.load { ctx.emit($0) }
        let safeTokens = Registry.sync(catalog: catalog) { ctx.emit($0) }
        guard !safeTokens.isEmpty else { return .ok }

        var declined: [String] = []
        for token in safeTokens {
            if await ctx.ask("Install brew cask “\(token)”? (No = don't offer it again)") {
                ctx.line("→ brew install --cask --force --quiet \(token)")
                let status = await ctx.run(["brew", "install", "--cask", "--force", "--quiet", token])
                if status != 0 { ctx.line("✗ install failed for \(token) (continuing)") }
            } else {
                declined.append(token)
            }
        }
        if !declined.isEmpty {
            Registry.addDeclines(declined)
            ctx.line("↳ Won't re-offer: \(declined.joined(separator: ", "))")
        }
        return .ok
    }
}
