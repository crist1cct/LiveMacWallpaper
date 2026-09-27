import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else {
    fatalError("Unable to create drawing context")
}

context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)

let canvas = NSRect(x: 44, y: 44, width: 936, height: 936)
let shape = NSBezierPath(roundedRect: canvas, xRadius: 215, yRadius: 215)
NSGradient(colors: [
    NSColor(calibratedRed: 0.06, green: 0.31, blue: 0.92, alpha: 1),
    NSColor(calibratedRed: 0.37, green: 0.16, blue: 0.82, alpha: 1),
    NSColor(calibratedRed: 0.80, green: 0.19, blue: 0.58, alpha: 1)
])?.draw(in: shape, angle: -38)

NSGraphicsContext.saveGraphicsState()
shape.addClip()

let glow = NSBezierPath(ovalIn: NSRect(x: 420, y: 350, width: 760, height: 760))
NSColor.white.withAlphaComponent(0.14).setFill()
glow.fill()

let lowerWave = NSBezierPath()
lowerWave.move(to: NSPoint(x: -30, y: 270))
lowerWave.curve(
    to: NSPoint(x: 1080, y: 400),
    controlPoint1: NSPoint(x: 270, y: 650),
    controlPoint2: NSPoint(x: 690, y: 40)
)
lowerWave.line(to: NSPoint(x: 1080, y: -20))
lowerWave.line(to: NSPoint(x: -30, y: -20))
lowerWave.close()
NSColor.black.withAlphaComponent(0.18).setFill()
lowerWave.fill()

let upperWave = NSBezierPath()
upperWave.move(to: NSPoint(x: -20, y: 500))
upperWave.curve(
    to: NSPoint(x: 1060, y: 520),
    controlPoint1: NSPoint(x: 340, y: 910),
    controlPoint2: NSPoint(x: 730, y: 220)
)
upperWave.line(to: NSPoint(x: 1060, y: 360))
upperWave.curve(
    to: NSPoint(x: -20, y: 355),
    controlPoint1: NSPoint(x: 700, y: 80),
    controlPoint2: NSPoint(x: 300, y: 760)
)
upperWave.close()
NSColor.white.withAlphaComponent(0.22).setFill()
upperWave.fill()

NSGraphicsContext.restoreGraphicsState()

let displayRect = NSRect(x: 230, y: 270, width: 564, height: 430)
let display = NSBezierPath(roundedRect: displayRect, xRadius: 54, yRadius: 54)
display.lineWidth = 34
NSColor.white.withAlphaComponent(0.93).setStroke()
display.stroke()

let stand = NSBezierPath()
stand.lineWidth = 34
stand.lineCapStyle = .round
stand.move(to: NSPoint(x: 420, y: 215))
stand.line(to: NSPoint(x: 604, y: 215))
stand.move(to: NSPoint(x: 512, y: 215))
stand.line(to: NSPoint(x: 512, y: 270))
stand.stroke()

let play = NSBezierPath()
play.move(to: NSPoint(x: 454, y: 392))
play.line(to: NSPoint(x: 454, y: 578))
play.line(to: NSPoint(x: 622, y: 485))
play.close()
NSColor.white.withAlphaComponent(0.93).setFill()
play.fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let representation = NSBitmapImageRep(data: tiff),
      let png = representation.representation(using: .png, properties: [:])
else {
    fatalError("Unable to encode icon")
}
try png.write(to: URL(fileURLWithPath: output))
