import Foundation
import AppKit

/// Mac App Store via `mas`. scan: `mas outdated`. install: `mas upgrade`.
struct MasTool: Tool {
    let id = "mas"
    let title = "Mac App Store"
    func isAvailable() -> Bool { commandExists("mas") }

    // mas otherwise spams stderr with "Found a likely App Store app not indexed
    // in Spotlight…" warnings; this env disables that auto-indexing chatter.
    private let env = ["MAS_NO_AUTO_INDEX": "1"]

    /// A Mac App Store purchase, as `mas list` reports it.
    private func masApps(_ ctx: RunContext) async -> [(id: String, name: String, version: String)] {
        let r = await ctx.capture(["mas", "list"], env: env)
        return r.output.split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " "), t[t.startIndex..<sp].allSatisfy(\.isNumber)
            else { return nil }
            let id = String(t[t.startIndex..<sp])
            var rest = String(t[sp...]).trimmingCharacters(in: .whitespaces)
            var version = ""
            if let open = rest.lastIndex(of: "("), rest.hasSuffix(")") {
                version = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
                rest = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
            }
            return (id, rest, version)
        }
    }

    /// The store's current version for a Mac purchase.
    ///
    /// `mas outdated` is the obvious source and reports nothing at all on this
    /// machine while apps are genuinely behind. `mas info` asks the store about
    /// one app and answers correctly — and crucially answers for the *Mac*
    /// build. The iTunes lookup API cannot: a universal purchase has a single
    /// record carrying the iPhone version, so Canva reads as 1.124.0 → 4.231.0
    /// when the Mac build is simply current.
    private func masInfoVersion(_ ctx: RunContext, _ id: String) async -> String? {
        let r = await ctx.capture(["mas", "info", id], env: env)
        for line in r.output.split(separator: "\n") where line.hasPrefix("Version") {
            let v = line.drop(while: { !$0.isNumber })
            if !v.isEmpty { return String(v).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// iPhone/iPad apps running on Apple Silicon: a wrapper directory whose
    /// metadata carries the store id and the installed version. `mas` does not
    /// list them at all, so they are found on disk and asked about by id — and
    /// here the lookup API's iPhone record is the right answer.
    private func iOSApps() -> [(id: String, name: String, version: String)] {
        let fm = FileManager.default
        var out: [(String, String, String)] = []
        for entry in (try? fm.contentsOfDirectory(atPath: "/Applications")) ?? []
        where entry.hasSuffix(".app") {
            let meta = "/Applications/\(entry)/Wrapper/iTunesMetadata.plist"
            guard fm.fileExists(atPath: meta),
                  let id = Plist.value(meta, "itemId"),
                  let v = Plist.value(meta, "bundleShortVersionString") else { continue }
            out.append((id, entry.removingSuffix(".app"), v))
        }
        return out
    }

    private func storeVersionsByID(_ ids: [String]) async -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        var out: [String: String] = [:]
        let region = (Locale.current.region?.identifier ?? "US").lowercased()
        // The lookup API is served from a CDN that caches per URL, and the
        // cached copy can be months stale: TEAMPUNKT returned 2.10.0 from June
        // while the App Store was offering 2.10.1 released that morning. The
        // same request with a unique parameter returns the current version
        // every time, so vary the URL per call. Measured: plain stayed stale
        // across repeated calls, busted was always fresh, and apps that were
        // already correct answered identically.
        let nonce = "\(Int(Date().timeIntervalSince1970))\(Int.random(in: 1000...9999))"
        guard let url = URL(string:
            "https://itunes.apple.com/lookup?id=\(ids.joined(separator: ","))"
            + "&country=\(region)&limit=200&_=\(nonce)")
        else { return [:] }
        var req = URLRequest(url: url); req.timeoutInterval = 20
        // …and don't let URLSession serve its own cached copy either.
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let data: Data? = await withCheckedContinuation { cont in
            URLSession.shared.dataTask(with: req) { d, _, _ in cont.resume(returning: d) }.resume()
        }
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return [:] }
        for r in results {
            guard let v = r["version"] as? String,
                  let track = r["trackId"] as? Int else { continue }
            out[String(track)] = v
        }
        return out
    }

    func scan(_ ctx: RunContext) async -> ScanResult {
        var items: [UpdateItem] = []
        var unknown = 0

        let mac = await masApps(ctx)
        // A few at a time: each `mas info` is a process and a request.
        for batch in stride(from: 0, to: mac.count, by: 8).map({
            Array(mac[$0..<min($0 + 8, mac.count)])
        }) {
            await withTaskGroup(of: (String, String, String, String?).self) { group in
                for a in batch {
                    group.addTask { (a.id, a.name, a.version, await masInfoVersion(ctx, a.id)) }
                }
                for await (id, name, installed, store) in group {
                    guard let store else { unknown += 1; continue }
                    if Version.sortV(store, installed) == 1 {
                        items.append(UpdateItem(name, token: id, current: installed, latest: store))
                    }
                }
            }
        }

        let ios = iOSApps()
        let iosStore = await storeVersionsByID(ios.map(\.id))
        for a in ios {
            guard let store = iosStore[a.id] else { unknown += 1; continue }
            if Version.sortV(store, a.version) == 1 {
                items.append(UpdateItem(a.name, token: "\(Self.iOSPrefix)\(a.id)",
                                        current: a.version, latest: store,
                                        detail: "iPhone app — update in the App Store"))
            }
        }

        if unknown > 0 {
            ctx.line("– \(unknown) app\(unknown == 1 ? "" : "s") the store has no record for "
                     + "(pre-installed Apple apps, or bought in another storefront)")
        }
        return .from(items.sorted { $0.name < $1.name })
    }


    /// What `mas list` currently reports for one app, to tell a real upgrade
    /// from one that re-downloaded the same build.
    private func installedVersion(_ ctx: RunContext, _ id: String) async -> String? {
        await masApps(ctx).first { $0.id == id }?.version
    }

    static let iOSPrefix = "ios:"

    var supportsTargetedInstall: Bool { true }

    func install(_ ctx: RunContext) async -> InstallOutcome {
        // `mas upgrade` with no arguments upgrades what *mas* thinks is
        // outdated — which is what this tool stopped trusting. Drive it from
        // the scan instead, so the same list the user saw is the list acted on.
        await install(ctx, only: (await scan(ctx)).items)
    }

    func install(_ ctx: RunContext, only items: [UpdateItem]) async -> InstallOutcome {
        guard !items.isEmpty else { return .skipped("nothing selected") }
        // One app per command. `mas upgrade <id> <id> …` would take them all at
        // once, but then a single failed download fails every app it was given,
        // and nothing can say which one is in progress.
        var failed: [String] = []
        var deferred: [String] = []
        var stalled: [String] = []
        var statuses: [String: String] = [:]
        for item in items {
            ctx.line("")
            ctx.line("==> \(item.name)")
            // `mas` drives the Mac App Store, which has no command for an
            // iPhone app running under the wrapper — only the App Store itself
            // can update those. Saying so beats an exit code that looks like
            // the download failed.
            if item.token.hasPrefix(Self.iOSPrefix) {
                ctx.line("   ⊘ iPhone app — the App Store has to update this one")
                deferred.append(item.token)
                statuses[item.token] = "↗ managed in App Store"
                continue
            }
            ctx.itemStarted(item.token)
            let before = await installedVersion(ctx, item.token)
            let status = await ctx.run(["mas", "upgrade", item.token], env: env)
            let after = await installedVersion(ctx, item.token)
            // A "ghost" update: the iTunes API advertises a version the App
            // Store back end will not actually hand over for this Mac yet, so
            // the upgrade exits cleanly having re-downloaded what was already
            // installed. Reporting that as updated would park the app in the
            // list for good, offered on every scan and never changing.
            if status == 0, let before, let after, before == after {
                ctx.line("   ⊘ the store delivered \(after) again — not yet available for this Mac")
                stalled.append(item.token)
                statuses[item.token] = "◷ not offered yet"
                ctx.itemFinished(item.token, ok: false)
                continue
            }
            if status != 0 { failed.append(item.token) }
            ctx.itemFinished(item.token, ok: status == 0)
        }
        if !deferred.isEmpty {
            ctx.line("")
            let names = items.filter { deferred.contains($0.token) }
                             .map(\.name).joined(separator: ", ")
            ctx.line("  Only the App Store itself can update: \(names)")
            // These are the one case where we know exactly where the user has
            // to go next, so offer to take them there instead of leaving a
            // line in the console that scrolls away. Not offered for stalled
            // apps below: the App Store can't update those either yet.
            if await ctx.ask("The App Store has to update \(names). "
                             + "Open its Updates tab now?") {
                await MainActor.run {
                    NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
                }
                ctx.line("  → opened the App Store's Updates tab")
            }
        }
        if !stalled.isEmpty {
            ctx.line("")
            ctx.line("  Advertised but not delivered: \(stalled.count) app\(stalled.count == 1 ? "" : "s"). "
                     + "The App Store will offer it when it is ready for this Mac.")
        }
        let attempted = items.count - deferred.count
        if attempted > 0 && failed.count == attempted {
            return InstallOutcome(.failed, "mas upgrade failed for every app it could update",
                                  failedItems: failed, skippedItems: deferred,
                                  itemStatuses: statuses)
        }
        return InstallOutcome(.ok, nil, failedItems: failed,
                              skippedItems: deferred + stalled, itemStatuses: statuses)
    }
}
