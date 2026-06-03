import Foundation

/// Tiny synchronous helpers for the native tools/registry. These block the
/// calling thread, so only call them from a tool's async scan()/install()
/// (which runs off the main actor), never directly on the main thread.
enum Shell {
    /// Run argv (PATH-resolved via env), return exit status + combined output.
    @discardableResult
    static func capture(_ argv: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        p.environment = ProcessRunner.baseEnvironment()
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

/// Read a top-level Info.plist key (handles binary or XML plists).
enum Plist {
    static func value(_ plistPath: String, _ key: String) -> String? {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any] else { return nil }
        if let s = dict[key] as? String { return s }
        if let v = dict[key] { return "\(v)" }
        return nil
    }
}

extension String {
    /// Python's str.removesuffix — drop a trailing suffix if present.
    func removingSuffix(_ s: String) -> String {
        hasSuffix(s) ? String(dropLast(s.count)) : self
    }
}
