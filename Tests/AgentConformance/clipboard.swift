import AppKit
import Foundation

let args = CommandLine.arguments
let board = NSPasteboard.general
switch args[1] {
case "save":
    let items = (board.pasteboardItems ?? []).map { item in
        Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } })
    }
    try PropertyListEncoder().encode(items).write(to: URL(fileURLWithPath: args[2]))
case "restore":
    let items = try PropertyListDecoder().decode([[String: Data]].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
    board.clearContents()
    board.writeObjects(items.map { values in
        let item = NSPasteboardItem()
        for (type, data) in values { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
        return item
    })
case "same":
    let saved = try PropertyListDecoder().decode([[String: Data]].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
    let now = (board.pasteboardItems ?? []).map { item in
        Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } })
    }
    exit(now == saved ? 0 : 3)
case "text":
    board.clearContents()
    board.setString(args[2], forType: .string)
case "image":
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)!
    for x in 0..<32 { for y in 0..<32 { image.setColor(.red, atX: x, y: y) } }
    board.clearContents()
    board.setData(image.representation(using: .png, properties: [:])!, forType: .png)
default:
    fatalError("unknown clipboard operation")
}
