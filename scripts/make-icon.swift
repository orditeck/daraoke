import AppKit

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot draw icon") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let factor = CGFloat(pixels) / 1024
        context.cgContext.scaleBy(x: factor, y: factor)
        let background = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 210, yRadius: 210)
        NSColor(calibratedRed: 0.11, green: 0.09, blue: 0.15, alpha: 1).setFill()
        background.fill()
        NSColor(calibratedRed: 1, green: 0.43, blue: 0.53, alpha: 1).setStroke()
        let microphone = NSBezierPath(roundedRect: NSRect(x: 390, y: 390, width: 244, height: 360), xRadius: 122, yRadius: 122)
        microphone.lineWidth = 40
        microphone.stroke()
        let cradle = NSBezierPath()
        cradle.move(to: NSPoint(x: 322, y: 490))
        cradle.line(to: NSPoint(x: 322, y: 412))
        cradle.curve(to: NSPoint(x: 702, y: 412), controlPoint1: NSPoint(x: 322, y: 168), controlPoint2: NSPoint(x: 702, y: 168))
        cradle.line(to: NSPoint(x: 702, y: 490))
        cradle.lineWidth = 40
        cradle.lineCapStyle = .round
        cradle.stroke()
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: 512, y: 230)); stand.line(to: NSPoint(x: 512, y: 144))
        stand.move(to: NSPoint(x: 430, y: 144)); stand.line(to: NSPoint(x: 594, y: 144))
        stand.lineWidth = 36; stand.lineCapStyle = .round; stand.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
        try png.write(to: URL(fileURLWithPath: "\(destination)/icon_\(size)x\(size)\(suffix).png"))
    }
}
