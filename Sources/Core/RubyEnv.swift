import Foundation

/// Which Ruby the user actually runs, so gems are updated where they live.
///
/// With rbenv, the Ruby on the user's PATH is `~/.rbenv/versions/<global>` and
/// Homebrew's ruby — if it is installed at all — is only there because some
/// formula (cocoapods) depends on it. Updating Homebrew's gems in that setup
/// reports success while the user's own `fastlane` stays exactly where it was.
/// The app's PATH has no rbenv shims, so it has to be asked directly.
struct RubyEnv {
    enum Kind: Equatable {
        case rbenv(version: String)
        case homebrew
    }

    let kind: Kind
    /// Absolute path to this Ruby's `gem`. Invoked by full path so PATH
    /// ordering (and shims) never decide which Ruby gets updated.
    let gem: String

    /// Where rbenv's versions live, or nil if rbenv isn't installed.
    static func rbenvRoot() -> String? {
        let r = Shell.capture(["rbenv", "root"])
        let root = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !root.isEmpty ? root : nil
    }

    /// The global rbenv version — what a new terminal gets. "system" means the
    /// user has rbenv but defers to whatever Ruby is on PATH.
    static func rbenvGlobal() -> String? {
        let r = Shell.capture(["rbenv", "global"])
        let v = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !v.isEmpty ? v : nil
    }

    static func rbenvGem(_ version: String) -> String? {
        guard let root = rbenvRoot() else { return nil }
        let gem = "\(root)/versions/\(version)/bin/gem"
        return FileManager.default.isExecutableFile(atPath: gem) ? gem : nil
    }

    /// rbenv's global Ruby when it names a real version, else Homebrew's ruby.
    static func current() -> RubyEnv? {
        if let v = rbenvGlobal(), v != "system", let gem = rbenvGem(v) {
            return RubyEnv(kind: .rbenv(version: v), gem: gem)
        }
        let prefix = Shell.capture(["brew", "--prefix", "ruby"]).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return nil }
        let gem = prefix + "/bin/gem"
        return FileManager.default.isExecutableFile(atPath: gem)
            ? RubyEnv(kind: .homebrew, gem: gem) : nil
    }

    /// Newest stable release ruby-build knows how to build, e.g. "4.0.7".
    /// Only plain x.y.z — previews, rcs and other implementations (jruby-,
    /// truffleruby-) are listed alongside and are not upgrades. nil when
    /// ruby-build isn't installed, since rbenv can't install anything without it.
    ///
    /// This is ruby-build's own list, so a release newer than the installed
    /// ruby-build is invisible until Homebrew upgrades the formula — which this
    /// same app does, so it shows up on the following check.
    static func latestStableRuby() -> String? {
        let r = Shell.capture(["rbenv", "install", "--list"])
        guard r.status == 0 else { return nil }
        return r.out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil }
            .max { Version.sortV($0, $1) < 0 }
    }
}
