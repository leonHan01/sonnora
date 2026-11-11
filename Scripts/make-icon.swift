import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let rect = NSRect(x: 66, y: 66, width: 892, height: 892)
    let base = NSBezierPath(roundedRect: rect, xRadius: 208, yRadius: 208)
    NSColor(red: 0.075, green: 0.095, blue: 0.10, alpha: 1).setFill()
    base.fill()
    NSGradient(starting: NSColor(red: 0.18, green: 0.23, blue: 0.18, alpha: 1), ending: NSColor(red: 0.055, green: 0.07, blue: 0.08, alpha: 1))!.draw(in: base, angle: -65)
    NSColor.white.withAlphaComponent(0.07).setStroke()
    base.lineWidth = 3
    base.stroke()
    for i in 0..<8 {
        let inset = CGFloat(i) * 27
        let ring = NSBezierPath(ovalIn: NSRect(x: 176 + inset, y: 176 + inset, width: 672 - inset * 2, height: 672 - inset * 2))
        NSColor(red: 0.77, green: 0.94, blue: 0.43, alpha: i % 2 == 0 ? 0.11 : 0.05).setStroke()
        ring.lineWidth = 2
        ring.stroke()
    }
    let lime = NSColor(red: 0.77, green: 0.94, blue: 0.43, alpha: 1)
    lime.setFill()
    let heights: [CGFloat] = [90, 190, 300, 390, 245, 150, 70]
    for (i, height) in heights.enumerated() {
        NSBezierPath(roundedRect: NSRect(x: 299 + CGFloat(i) * 62, y: 512 - height / 2, width: 37, height: height), xRadius: 18.5, yRadius: 18.5).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: destination.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: destination.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

// An ICNS container can hold PNG representations directly. Creating it here
// also works on Command Line Tools installations without iconutil services.
func appendLength(_ length: Int, to data: inout Data) {
    var value = UInt32(length).bigEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}
var payload = Data()
for (type, pixels) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024), ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)] {
    let png = render(pixels: pixels)
    payload.append(contentsOf: type.utf8)
    appendLength(png.count + 8, to: &payload)
    payload.append(png)
}
var icns = Data("icns".utf8)
appendLength(payload.count + 8, to: &icns)
icns.append(payload)
try icns.write(to: destination.deletingLastPathComponent().appendingPathComponent("AppIcon.icns"))
