import AppKit

let size = 1024
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
    let colors = [
        NSColor(red: 61.0 / 255, green: 139.0 / 255, blue: 1, alpha: 1).cgColor,
        NSColor(red: 21.0 / 255, green: 81.0 / 255, blue: 184.0 / 255, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    NSGraphicsContext.current!.cgContext.drawLinearGradient(
        gradient,
        start: NSPoint(x: 0, y: size),
        end: NSPoint(x: size, y: 0),
        options: []
    )

    NSColor(red: 0.97, green: 0.98, blue: 1, alpha: 1).setStroke()
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: x * CGFloat(size) / 18, y: y * CGFloat(size) / 18)
    }

    let wave = NSBezierPath()
    wave.lineWidth = 91
    wave.lineCapStyle = .round
    wave.lineJoinStyle = .round
    wave.move(to: point(1.6, 9))
    wave.curve(to: point(3.4, 12.7), controlPoint1: point(2.2, 9.1), controlPoint2: point(2.6, 12.6))
    wave.curve(to: point(5.2, 5), controlPoint1: point(4.3, 12.8), controlPoint2: point(4.3, 5))
    wave.curve(to: point(7, 16.2), controlPoint1: point(6.1, 5), controlPoint2: point(5.9, 16.2))
    wave.curve(to: point(9.2, 2), controlPoint1: point(8.2, 16.2), controlPoint2: point(7.8, 2))
    wave.stroke()

    for (y, endX) in [(11.4, 14.6), (6.6, 15.3)] {
        let path = NSBezierPath()
        path.lineWidth = 86
        path.lineCapStyle = .round
        path.move(to: point(10.5, y))
        path.line(to: point(endX, y))
        path.stroke()
    }

    return true
}

let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
