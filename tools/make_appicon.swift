// Рисует иконку приложения (три полоски лимитов) и собирает AppIcon.icns.
// Использование: swift tools/make_appicon.swift <out.icns>
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AILimits-\(getpid()).iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // Сетка иконок macOS: тело 824/1024, скругление ~185/1024
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.set()
    NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.16, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(starting: NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.26, alpha: 1),
               ending: NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.11, alpha: 1))!
        .draw(in: path, angle: -90)

    // Три полоски: Claude, Codex, Antigravity
    let bars: [(NSColor, CGFloat)] = [
        (NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1), 0.72),
        (NSColor(calibratedRed: 0.30, green: 0.62, blue: 0.95, alpha: 1), 0.45),
        (NSColor(calibratedRed: 0.60, green: 0.45, blue: 0.95, alpha: 1), 0.88),
    ]
    let left = body.minX + body.width * 0.17
    let width = body.width * 0.66
    let h = body.height * 0.115
    let gap = body.height * 0.085
    let total = CGFloat(bars.count) * h + CGFloat(bars.count - 1) * gap
    var y = body.midY + total / 2 - h
    for (color, frac) in bars {
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: NSRect(x: left, y: y, width: width, height: h), xRadius: h / 2, yRadius: h / 2).fill()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: left, y: y, width: width * frac, height: h), xRadius: h / 2, yRadius: h / 2).fill()
        y -= h + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", outPath]
try! p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "  ✓ AppIcon.icns" : "  ! iconutil failed")
