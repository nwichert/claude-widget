// Draws the Claude Pulse app icon and writes assets/AppIcon.icns.
//   swift tools/make_icon.swift
// The geometry matches assets/logo.svg: a six-ray burst with a pulse line where the
// horizontal rays would be, on a dark rounded tile inset the way macOS icons are.
import AppKit

func draw(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icons sit inside the canvas with a margin: an 824pt tile on a 1024pt canvas.
    let inset = size * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let scale = tile.width / 512  // the logo is drawn on a 512 grid
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 116 * scale, cornerHeight: 116 * scale, transform: nil))
    ctx.setFillColor(CGColor(red: 0.149, green: 0.149, blue: 0.141, alpha: 1))
    ctx.fillPath()

    // Logo coordinates have y pointing down; flip into this context.
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: tile.minX + x * scale, y: tile.maxY - y * scale)
    }
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    ctx.setStrokeColor(CGColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1))  // clay
    ctx.setLineWidth(36 * scale)
    for degrees in [45.0, 90, 135, 225, 270, 315] {
        let a = degrees * .pi / 180
        ctx.move(to: point(256 + 84 * cos(a), 256 - 84 * sin(a)))
        ctx.addLine(to: point(256 + 158 * cos(a), 256 - 158 * sin(a)))
    }
    ctx.strokePath()

    ctx.setStrokeColor(CGColor(red: 0.980, green: 0.976, blue: 0.961, alpha: 1))  // ivory
    ctx.setLineWidth(24 * scale)
    let pulse: [(CGFloat, CGFloat)] = [(86, 256), (218, 256), (236, 212), (262, 302), (282, 232), (294, 256), (426, 256)]
    ctx.move(to: point(pulse[0].0, pulse[0].1))
    for p in pulse.dropFirst() { ctx.addLine(to: point(p.0, p.1)) }
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("ClaudePulse.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try draw(size: CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(size: CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "assets/AppIcon.icns"]
try task.run()
task.waitUntilExit()
try draw(size: 1024).write(to: URL(fileURLWithPath: "assets/icon-1024.png"))
print(task.terminationStatus == 0 ? "wrote assets/AppIcon.icns" : "iconutil failed")
