import Foundation

/// Version comparison — a faithful Swift port of the Python `cmp_version`
/// helper that used to live in update-all.sh. Same contract:
///   compare(a, b) → 1 if a > b, -1 if a < b, 0 if equal, nil if structurally
///   incomparable (different version schemes → caller treats as "don't touch").
enum Version {

    /// Leading integer run of a string, or nil. "148.0.1" → 148, "x1" → nil.
    static func firstInt(_ s: String?) -> Int? {
        guard let s = s else { return nil }
        var digits = ""
        for ch in s {
            if ch.isNumber { digits.append(ch) } else { break }
        }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// `sort -V`-style comparison: split each string into alternating digit and
    /// non-digit runs, compare run-by-run (digits numerically, others by ASCII).
    /// Returns 1 if a > b, -1 if a < b, 0 if equal.
    static func sortV(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let ra = runs(a), rb = runs(b)
        let n = max(ra.count, rb.count)
        for i in 0..<n {
            if i >= ra.count { return -1 }   // a ran out → shorter sorts first
            if i >= rb.count { return 1 }
            let x = ra[i], y = rb[i]
            switch (x, y) {
            case let (.num(p), .num(q)):
                if p != q { return p < q ? -1 : 1 }
            case let (.str(p), .str(q)):
                if p != q { return p < q ? -1 : 1 }
            case (.num, .str): return 1    // numeric run sorts after alpha in -V
            case (.str, .num): return -1
            }
        }
        return 0
    }

    private enum Run: Equatable { case num(Int), str(String) }

    private static func runs(_ s: String) -> [Run] {
        var out: [Run] = []
        var cur = ""
        var curIsDigit: Bool? = nil
        func flush() {
            guard !cur.isEmpty else { return }
            if curIsDigit == true { out.append(.num(Int(cur) ?? 0)) }
            else { out.append(.str(cur)) }
            cur = ""
        }
        for ch in s {
            let d = ch.isNumber
            if curIsDigit == nil || d == curIsDigit { cur.append(ch); curIsDigit = d }
            else { flush(); cur.append(ch); curIsDigit = d }
        }
        flush()
        return out
    }

    /// Full `cmp_version` port. Handles Chromium-style concatenations like
    /// Brave's "148.1.90.122" by also trying the leading segment stripped.
    static func compare(_ a: String?, _ b: String?) -> Int? {
        guard let a = a, let b = b, !a.isEmpty, !b.isEmpty else { return nil }
        let aClean = a.split(separator: ",")[0].split(separator: " ")[0].description
        let bClean = b.split(separator: ",")[0].split(separator: " ")[0].description
        if aClean == bClean { return 0 }

        let fa = firstInt(aClean), fb = firstInt(bClean)
        var pairs: [(String, String)] = [(aClean, bClean)]
        if let fa = fa, let fb = fb {
            if fa >= 10 * max(fb, 1), aClean.contains(".") {
                pairs.append((String(aClean.drop(while: { $0 != "." }).dropFirst()), bClean))
            }
            if fb >= 10 * max(fa, 1), bClean.contains(".") {
                pairs.append((aClean, String(bClean.drop(while: { $0 != "." }).dropFirst())))
            }
        }
        for (ax, bx) in pairs {
            guard let ma = firstInt(ax), let mb = firstInt(bx) else { continue }
            let hi = max(ma, mb), lo = max(min(ma, mb), 1)
            if hi < 10 * lo { return sortV(ax, bx) }
        }
        return nil
    }
}
