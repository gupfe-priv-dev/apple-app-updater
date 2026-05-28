// One-shot icon generator. Run via build-app.sh.
// Produces AppIcon.icns from an SF Symbol drawn on a gradient rounded square.
import AppKit

let dir = CommandLine.arguments.dropFirst().first ?? "."
let iconset = "\(dir)/AppIcon.iconset"
let outIcns = "\(dir)/AppIcon.icns"

try? FileManager.default.removeItem(atPath: iconset)
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// macOS iconset spec: name@scale.png for each size
let entries: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func renderPNG(px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
    rep.size = NSSize(width: s, height: s)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Rounded-square background with a teal->blue gradient (macOS app look)
    let inset = s * 0.05
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = s * 0.22
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let top = NSColor(calibratedRed: 0.18, green: 0.78, blue: 0.78, alpha: 1)   // teal
    let bot = NSColor(calibratedRed: 0.15, green: 0.40, blue: 0.85, alpha: 1)   // blue
    let gradient = NSGradient(colors: [top, bot])!
    gradient.draw(in: path, angle: -90)

    // Subtle inner highlight
    NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
    let hl = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2),
                          xRadius: radius - 2, yRadius: radius - 2)
    hl.lineWidth = max(1, s * 0.005)
    hl.stroke()

    // SF Symbol "arrow.clockwise" centered, white, large
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.55, weight: .bold)
    if let sym = NSImage(systemSymbolName: "arrow.clockwise",
                         accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        // tint to white by drawing into a new image with white fill
        let tinted = NSImage(size: sym.size)
        tinted.lockFocus()
        NSColor.white.set()
        let r = NSRect(origin: .zero, size: sym.size)
        r.fill(using: .sourceOver)
        sym.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()

        let drawSize = NSSize(width: sym.size.width, height: sym.size.height)
        let drawRect = NSRect(
            x: (s - drawSize.width) / 2,
            y: (s - drawSize.height) / 2,
            width: drawSize.width, height: drawSize.height)
        tinted.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for entry in entries {
    let data = renderPNG(px: entry.px)
    try data.write(to: URL(fileURLWithPath: "\(iconset)/\(entry.name)"))
}

// iconutil to .icns
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", outIcns]
try p.run()
p.waitUntilExit()
exit(p.terminationStatus)
