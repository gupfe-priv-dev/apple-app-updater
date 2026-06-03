import Foundation

/// A cask that can install a given app, with its catalog version.
struct CaskCandidate { let token: String; let version: String }

/// The full Homebrew cask catalog (formulae.brew.sh) indexed by app name, so we
/// can answer "is there a cask that installs /Applications/Foo.app, and what
/// version?" without a per-app `brew info` call. Cached on disk for 24h.
/// Native port of registry.py's load_cask_catalog + find_brew_cask.
final class CaskCatalog {
    /// app name (lowercased, no ".app") → candidate casks
    private var index: [String: [CaskCandidate]] = [:]
    private var loaded = false

    private var cachePath: String { AppPaths.cache + "/brew_cask_catalog_v4.json" }

    /// Load from cache if fresh (<24h), else fetch + index + persist.
    func load(emit: (String) -> Void) {
        if loaded { return }
        loaded = true
        let fm = FileManager.default

        if let attrs = try? fm.attributesOfItem(atPath: cachePath),
           let mtime = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mtime) < 86400,
           let data = fm.contents(atPath: cachePath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: String]]] {
            index = obj.mapValues { $0.map { CaskCandidate(token: $0["token"] ?? "", version: $0["version"] ?? "") } }
            return
        }

        emit("  ⤓ Fetching Homebrew cask catalog (~15MB, cached for 24h)...\n")
        guard let url = URL(string: "https://formulae.brew.sh/api/cask.json"),
              let data = try? Data(contentsOf: url),
              let casks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            emit("    ✗ catalog fetch failed — continuing without cask suggestions\n")
            return
        }

        var cat: [String: [[String: String]]] = [:]
        for c in casks {
            guard let token = c["token"] as? String else { continue }
            let ver = (c["version"] as? String) ?? ""
            var apps = Set<String>()
            for art in (c["artifacts"] as? [[String: Any]]) ?? [] {
                for a in (art["app"] as? [Any]) ?? [] {
                    if let s = a as? String { apps.insert(s) }
                }
                for u in (art["uninstall"] as? [[String: Any]]) ?? [] {
                    for p in (u["delete"] as? [Any]) ?? [] {
                        guard let path = p as? String,
                              path.hasPrefix("/Applications/"), path.hasSuffix(".app"),
                              !path.contains("*") else { continue }
                        apps.insert((path as NSString).lastPathComponent)
                    }
                }
            }
            for a in apps {
                cat[a.lowercased().removingSuffix(".app"), default: []].append(["token": token, "version": ver])
            }
        }

        if let out = try? JSONSerialization.data(withJSONObject: cat) {
            try? out.write(to: URL(fileURLWithPath: cachePath))
        }
        index = cat.mapValues { $0.map { CaskCandidate(token: $0["token"] ?? "", version: $0["version"] ?? "") } }
        emit("    ✓ catalog indexed: \(cat.count) apps from \(casks.count) casks\n")

        // purge orphaned old-format caches
        for old in ["brew_cask_catalog.json", "brew_cask_catalog_v2.json", "brew_cask_catalog_v3.json"] {
            try? fm.removeItem(atPath: AppPaths.cache + "/" + old)
        }
    }

    /// Best-matching cask for `appName`. When several casks install the same
    /// app, prefer the one whose major version matches the installed major
    /// (e.g. LibreOffice 26.x → libreoffice, not libreoffice-still 25.x).
    func find(_ appName: String, installedVersion: String?) -> CaskCandidate? {
        let key = appName.lowercased().removingSuffix(".app")
        guard let cands = index[key], !cands.isEmpty else { return nil }
        if cands.count == 1 { return cands[0] }
        func major(_ s: String) -> Int { Version.firstInt(s) ?? -1 }
        if let iv = installedVersion, !iv.isEmpty {
            let m = major(iv)
            if let same = cands.first(where: { major($0.version) == m }) { return same }
        }
        return cands.max(by: { major($0.version) < major($1.version) })
    }
}
