import AppKit

// Entry point. With a multi-file Swift target, top-level executable code is
// only permitted in a file named `main.swift` — everything else lives in
// type definitions across the other Sources/*.swift files.
//
// AppDelegate is @MainActor-isolated; top-level code is nonisolated, so we
// assert main-actor isolation (true here — this runs on the main thread) to
// construct and start the app. app.run() blocks until termination, so the
// local `delegate` stays retained for the program's lifetime.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
