import AppKit

// Draws the app icon: one path splitting into two.
// Usage: swift Tools/make-icon.swift <output.png>
let size = 1024
let canvas = CGFloat(size)
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: rep) else {
    exit(1)
}
NSGraphicsContext.current = context
let inset = canvas * 0.1
let body = NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
let tile = NSBezierPath(roundedRect: body, xRadius: canvas * 0.18, yRadius: canvas * 0.18)
NSGradient(
    starting: NSColor(red: 0.07, green: 0.11, blue: 0.20, alpha: 1),
    ending: NSColor(red: 0.05, green: 0.36, blue: 0.42, alpha: 1)
)?.draw(in: tile, angle: -60)

func stroke(_ color: NSColor, _ build: (NSBezierPath) -> Void) {
    let path = NSBezierPath()
    path.lineWidth = canvas * 0.062
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    build(path)
    color.setStroke()
    path.stroke()
}

let start = NSPoint(x: canvas * 0.24, y: canvas * 0.5)
let fork = NSPoint(x: canvas * 0.46, y: canvas * 0.5)
stroke(.white) { path in
    path.move(to: start)
    path.line(to: fork)
}
stroke(NSColor(red: 0.27, green: 0.91, blue: 0.78, alpha: 1)) { path in
    path.move(to: fork)
    path.curve(
        to: NSPoint(x: canvas * 0.76, y: canvas * 0.70),
        controlPoint1: NSPoint(x: canvas * 0.58, y: canvas * 0.5),
        controlPoint2: NSPoint(x: canvas * 0.60, y: canvas * 0.70)
    )
}
stroke(NSColor(red: 1, green: 0.74, blue: 0.30, alpha: 1)) { path in
    path.move(to: fork)
    path.curve(
        to: NSPoint(x: canvas * 0.76, y: canvas * 0.30),
        controlPoint1: NSPoint(x: canvas * 0.58, y: canvas * 0.5),
        controlPoint2: NSPoint(x: canvas * 0.60, y: canvas * 0.30)
    )
}
NSGraphicsContext.current = nil
guard let data = rep.representation(using: .png, properties: [:]) else {
    exit(1)
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
