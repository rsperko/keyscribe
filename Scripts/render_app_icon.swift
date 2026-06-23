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
    for (x, lower, upper) in [(244.0, 458.0, 566.0), (397.0, 374.0, 650.0), (550.0, 286.0, 738.0)] {
        let path = NSBezierPath()
        path.lineWidth = 86
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: x, y: lower))
        path.line(to: NSPoint(x: x, y: upper))
        path.stroke()
    }

    for (y, endX) in [(458.0, 818.0), (634.0, 878.0)] {
        let path = NSBezierPath()
        path.lineWidth = 86
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: 664, y: y))
        path.line(to: NSPoint(x: endX, y: y))
        path.stroke()
    }

    return true
}

let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
