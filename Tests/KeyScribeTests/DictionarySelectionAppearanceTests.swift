import AppKit
import SwiftUI
import Testing
@testable import KeyScribeApp

@MainActor
struct DictionarySelectionAppearanceTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func selectionHighlightsTheWordAreaSeparatelyFromDelete(_ scheme: ColorScheme) throws {
        let unselected = try render(selection: nil, scheme: scheme)
        let selected = try render(selection: "Postgres", scheme: scheme)

        #expect(try difference(unselected, selected, x: 180, y: 22) > 0.05)
        #expect(try difference(unselected, selected, x: 345, y: 22) < 0.01)
    }

    private func render(selection: String?, scheme: ColorScheme) throws -> NSBitmapImageRep {
        let content = DictionaryRows(
            words: ["Postgres"],
            removeID: { "delete.\($0)" },
            deletionScope: .global,
            deleteConfirmConfirmID: "delete.confirm",
            deleteConfirmCancelID: "delete.cancel",
            selection: .constant(selection),
            selectID: { "select.\($0)" },
            onRemove: { _ in })
            .frame(width: 360, height: 44)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }

    private func difference(
        _ before: NSBitmapImageRep, _ after: NSBitmapImageRep, x: Int, y: Int
    ) throws -> CGFloat {
        let first = try #require(before.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        let second = try #require(after.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        return abs(first.redComponent - second.redComponent)
            + abs(first.greenComponent - second.greenComponent)
            + abs(first.blueComponent - second.blueComponent)
    }
}
