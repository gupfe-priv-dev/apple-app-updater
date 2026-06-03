import AppKit

// Entry point. With a multi-file Swift target, top-level executable code is
// only permitted in a file named `main.swift` — everything else lives in
// type definitions across the other Sources/*.swift files.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
