import Foundation

/// Unmanaged apps that ship a Sparkle appcast (SUFeedURL). Feeds are checked at
/// install time (no cheap dry-run). Native port of sparkle.py: parses the
/// appcast, compares versions, and installs DMG/ZIP/PKG updates.
struct SparkleTool: Tool {
    let id = "sparkle"
    let title = "Sparkle updates (unmanaged apps)"
    func isAvailable() -> Bool { true }

    func scan(_ ctx: RunContext) async -> ScanResult {
        .unknown("feeds checked on install")
    }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        AppPaths.ensure()
        var registry = Registry.load()
        let appsDir = "/Applications"
        var checked = 0

        for (name, entry) in registry.sorted(by: { $0.key < $1.key }) {
            guard entry.manager == "sparkle" else { continue }
            checked += 1
            let display = name.removingSuffix(".app")
            let installedVer = Plist.value("\(appsDir)/\(name)/Contents/Info.plist", "CFBundleShortVersionString") ?? "?"
            guard let feed = entry.feed_url, !feed.isEmpty else { ctx.line("? \(name): no feed URL"); continue }

            guard let (latest, url) = Appcast.fetch(feed) else { ctx.line("✗ \(display): feed unreachable"); continue }
            // newer iff latest sorts strictly after installed
            if Version.sortV(latest, installedVer) != 1 {
                ctx.line("✓ \(display) \(installedVer)")
                continue
            }
            ctx.line("↑ \(display): \(installedVer) → \(latest)")
            guard let url = url else { ctx.line("  no download URL — skipping"); continue }
            if await install(url: url, newVersion: latest, ctx: ctx) {
                registry[name]?.last_version = latest
                Registry.save(registry)
            }
        }
        if checked == 0 { ctx.line("✓ No Sparkle apps tracked") }
        return .ok
    }

    /// Download + install one Sparkle update. Returns true on success.
    private func install(url: String, newVersion: String, ctx: RunContext) async -> Bool {
        let ext = (url.components(separatedBy: "?").first ?? url)
            .components(separatedBy: ".").last?.lowercased() ?? ""
        let tmp = NSTemporaryDirectory() + "ua-sparkle-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let pkg = "\(tmp)/update.\(ext)"

        ctx.line("  Downloading...")
        if await ctx.run(["curl", "-L", "--progress-bar", "-o", pkg, url]) != 0 {
            ctx.line("  ✗ download failed"); return false
        }

        switch ext {
        case "dmg":
            let r = Shell.capture(["hdiutil", "attach", pkg, "-nobrowse", "-quiet"])
            guard r.status == 0, let vol = r.out.split(separator: "\n").last?
                    .components(separatedBy: "\t").last, !vol.isEmpty else {
                ctx.line("  ✗ mount failed"); return false
            }
            defer { _ = Shell.capture(["hdiutil", "detach", vol, "-quiet"]) }
            guard let app = findApp(in: vol, maxdepth: 2) else { ctx.line("  ✗ no .app in DMG"); return false }
            return replaceApp(from: app, newVersion: newVersion, ctx: ctx)

        case "zip":
            let ex = "\(tmp)/x"
            if Shell.capture(["unzip", "-q", pkg, "-d", ex]).status != 0 { ctx.line("  ✗ unzip failed"); return false }
            guard let app = findApp(in: ex, maxdepth: 3) else { ctx.line("  ✗ no .app in ZIP"); return false }
            return replaceApp(from: app, newVersion: newVersion, ctx: ctx)

        case "pkg":
            if await ctx.run(["sudo", "installer", "-pkg", pkg, "-target", "/"]) == 0 {
                ctx.line("  ✓ updated to \(newVersion) (pkg)"); return true
            }
            return false

        default:
            ctx.line("  ✗ unknown format: .\(ext)"); return false
        }
    }

    private func findApp(in dir: String, maxdepth: Int) -> String? {
        let r = Shell.capture(["find", dir, "-maxdepth", "\(maxdepth)", "-name", "*.app"])
        return r.out.split(separator: "\n").first.map(String.init)
    }

    private func replaceApp(from app: String, newVersion: String, ctx: RunContext) -> Bool {
        let dest = "/Applications/" + (app as NSString).lastPathComponent
        _ = Shell.capture(["rm", "-rf", dest])
        if Shell.capture(["cp", "-R", app, "/Applications/"]).status != 0 {
            ctx.line("  ✗ copy failed"); return false
        }
        ctx.line("  ✓ updated to \(newVersion)")
        return true
    }
}

/// Minimal Sparkle appcast parser. Namespaces are left unprocessed so we match
/// the qualified "sparkle:…" names directly — covering both the http:// and
/// https:// Sparkle namespace variants (both use the "sparkle" prefix).
final class Appcast: NSObject, XMLParserDelegate {
    /// Returns (best version, download URL) or nil if unreachable/unparseable.
    static func fetch(_ feedURL: String) -> (String, String?)? {
        guard let url = URL(string: feedURL) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Sparkle/2.0", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var payload: Data?
        URLSession.shared.dataTask(with: req) { d, _, _ in payload = d; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 12)
        guard let data = payload else { return nil }

        let p = Appcast()
        let parser = XMLParser(data: data)
        parser.delegate = p
        guard parser.parse(), let v = p.bestVersion else { return nil }
        return (v, p.bestURL)
    }

    private var bestVersion: String?
    private var bestURL: String?
    // current <item> state
    private var inItem = false
    private var encURL: String?
    private var encShort: String?, encVersion: String?
    private var childShort: String?, childVersion: String?
    private var capturing: String?      // which child element we're reading chars into

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attrs: [String: String]) {
        let n = qName ?? name
        switch n {
        case "item":
            inItem = true; encURL = nil; encShort = nil; encVersion = nil
            childShort = nil; childVersion = nil
        case "enclosure":
            encURL = attrs["url"]
            encShort = attrs["sparkle:shortVersionString"]
            encVersion = attrs["sparkle:version"]
        case "sparkle:shortVersionString": capturing = "short"
        case "sparkle:version":            capturing = "version"
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem, let c = capturing else { return }
        let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if c == "short" { childShort = (childShort ?? "") + t } else { childVersion = (childVersion ?? "") + t }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let n = qName ?? name
        if n == "sparkle:shortVersionString" || n == "sparkle:version" { capturing = nil; return }
        guard n == "item" else { return }
        inItem = false
        let ver = childShort ?? childVersion ?? encShort ?? encVersion
        guard let v = ver, let u = encURL else { return }
        // keep the highest version seen
        if bestVersion == nil || Version.sortV(v, bestVersion!) == 1 {
            bestVersion = v; bestURL = u
        }
    }
}
