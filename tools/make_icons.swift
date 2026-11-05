// Извлекает иконки из установленных приложений:
//   <name>.png        — цветная иконка (для окна и виджета)
//   <name>-glyph.png  — монохромный силуэт логотипа (template-изображение для строки меню)
// Использование: swift tools/make_icons.swift <out_dir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

enum MaskMode { case bright, notWhite }

struct Source {
    let name: String
    let paths: [String]
    let mask: MaskMode
}

let sources = [
    Source(name: "claude", paths: ["/Applications/Claude.app/Contents/Resources/electron.icns"], mask: .bright),
    Source(name: "codex", paths: ["/Applications/ChatGPT.app/Contents/Resources/icon-codex-light.png",
                                  "/Applications/Codex.app/Contents/Resources/icon.icns"], mask: .notWhite),
    Source(name: "antigravity", paths: ["/Applications/Antigravity.app/Contents/Resources/icon.icns",
                                        "/Applications/Antigravity IDE.app/Contents/Resources/Antigravity IDE.icns"], mask: .notWhite),
]

func bitmap(_ img: NSImage, size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func clamp(_ v: Double) -> Double { min(1, max(0, v)) }

for src in sources {
    guard let path = src.paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
          let img = NSImage(contentsOfFile: path) else {
        print("  ! \(src.name): приложение не найдено, будет SF Symbol")
        continue
    }

    // Цветная иконка
    writePNG(bitmap(img, size: 128), "\(outDir)/\(src.name).png")

    // Маска логотипа
    let n = 512
    let rep = bitmap(img, size: n)
    let p = rep.bitmapData!
    let bpr = rep.bytesPerRow
    var alpha = [Double](repeating: 0, count: n * n)
    var minX = n, minY = n, maxX = 0, maxY = 0
    for y in 0..<n {
        for x in 0..<n {
            let o = y * bpr + x * 4
            let a = Double(p[o + 3]) / 255
            guard a > 0.5 else { continue }
            // Данные премультиплицированы — делим на альфу.
            let r = Double(p[o]) / 255 / a, g = Double(p[o + 1]) / 255 / a, b = Double(p[o + 2]) / 255 / a
            let mx = max(r, g, b), mn = min(r, g, b)
            let v: Double
            switch src.mask {
            case .bright: v = clamp((mn - 0.62) / 0.25)
            case .notWhite: v = clamp((0.86 - mn) / 0.12) * (mx > 0.97 && mn > 0.9 ? 0 : 1)
            }
            alpha[y * n + x] = v
            if v > 0.3 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        }
    }
    guard maxX > minX else { continue }

    // Обрезка по логотипу и вписывание в квадрат
    let side = max(maxX - minX, maxY - minY) + 1
    let out = 64
    let glyph = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: out, pixelsHigh: out, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gp = glyph.bitmapData!
    let cx = Double(minX + maxX) / 2, cy = Double(minY + maxY) / 2
    let scale = Double(side) / Double(out)
    for y in 0..<out {
        for x in 0..<out {
            // Усреднение по блоку исходных пикселей (сглаживание)
            var sum = 0.0, cnt = 0.0
            let sx0 = cx + (Double(x) - Double(out) / 2) * scale
            let sy0 = cy + (Double(y) - Double(out) / 2) * scale
            var dy = 0.0
            while dy < scale {
                var dx = 0.0
                while dx < scale {
                    let ix = Int(sx0 + dx), iy = Int(sy0 + dy)
                    if ix >= 0, iy >= 0, ix < n, iy < n { sum += alpha[iy * n + ix] }
                    cnt += 1; dx += 1
                }
                dy += 1
            }
            let v = UInt8(clamp(sum / max(cnt, 1)) * 255)
            let o = y * glyph.bytesPerRow + x * 4
            gp[o] = 0; gp[o + 1] = 0; gp[o + 2] = 0; gp[o + 3] = v
        }
    }
    writePNG(glyph, "\(outDir)/\(src.name)-glyph.png")
    print("  ✓ \(src.name) ← \(path)")
}
