import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(
        "PaperPath/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
    )

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

guard let bitmap = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: size * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    throw CocoaError(.fileWriteUnknown)
}

let graphics = NSGraphicsContext(cgContext: bitmap, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
bitmap.setShouldAntialias(true)

NSGradient(colors: [color(0x07111E), color(0x0B2942)])?.draw(
    in: NSRect(x: 0, y: 0, width: size, height: size),
    angle: 55
)

let glow = NSBezierPath(ovalIn: NSRect(x: 510, y: 510, width: 620, height: 620))
color(0x45C7F2, alpha: 0.12).setFill()
glow.fill()

let backPage = NSBezierPath(
    roundedRect: NSRect(x: 238, y: 186, width: 506, height: 650),
    xRadius: 72,
    yRadius: 72
)
color(0x5ED3F1, alpha: 0.18).setFill()
backPage.fill()

let page = NSBezierPath(
    roundedRect: NSRect(x: 286, y: 224, width: 506, height: 650),
    xRadius: 72,
    yRadius: 72
)
color(0xF2F8FC).setFill()
page.fill()

for (y, width) in [(684.0, 306.0), (594.0, 382.0), (504.0, 250.0)] {
    let line = NSBezierPath(
        roundedRect: NSRect(x: 382, y: y, width: width, height: 30),
        xRadius: 15,
        yRadius: 15
    )
    color(0x173B58, alpha: 0.72).setFill()
    line.fill()
}

let path = NSBezierPath()
path.move(to: NSPoint(x: 378, y: 400))
path.curve(
    to: NSPoint(x: 526, y: 352),
    controlPoint1: NSPoint(x: 420, y: 400),
    controlPoint2: NSPoint(x: 454, y: 352)
)
path.curve(
    to: NSPoint(x: 688, y: 416),
    controlPoint1: NSPoint(x: 608, y: 352),
    controlPoint2: NSPoint(x: 616, y: 416)
)
path.lineWidth = 32
path.lineCapStyle = .round
path.lineJoinStyle = .round
color(0x41BFF0).setStroke()
path.stroke()

for point in [
    NSPoint(x: 378, y: 400),
    NSPoint(x: 526, y: 352),
    NSPoint(x: 688, y: 416)
] {
    let node = NSBezierPath(
        ovalIn: NSRect(
            x: point.x - 25,
            y: point.y - 25,
            width: 50,
            height: 50
        )
    )
    color(0x45D5B5).setFill()
    node.fill()
}

NSGraphicsContext.restoreGraphicsState()

try FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
guard let image = bitmap.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        output as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      )
else {
    throw CocoaError(.fileWriteUnknown)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    throw CocoaError(.fileWriteUnknown)
}
