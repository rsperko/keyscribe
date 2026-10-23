import AppKit
import SwiftUI
import Testing
@testable import KeyScribeApp

@MainActor
struct DictionaryRowsLayoutTests {
    @Test func longWordsPutTheHistoryActionBelowTheWord() throws {
        let image = try render("PostgreSQLConnectionPoolConfigurationAndConnectionLifecycleManagement", width: 420)
        let word = try bounds(in: image) { $0.redComponent < 0.45 && $0.greenComponent < 0.45 && $0.blueComponent < 0.45 }
        let action = try bounds(in: image) { $0.blueComponent > 0.6 && $0.blueComponent > $0.redComponent * 1.5 }
        let delete = try bounds(in: image) { $0.redComponent > 0.65 && $0.redComponent > $0.greenComponent * 1.5 && $0.redComponent > $0.blueComponent * 1.5 }
        #expect(action.minY > word.maxY)
        #expect(delete.minX > action.maxX)
    }

    @Test func shortWordsKeepTheHistoryActionOnTheSameLine() throws {
        let image = try render("Postgres", width: 420)
        let word = try bounds(in: image) { $0.redComponent < 0.45 && $0.greenComponent < 0.45 && $0.blueComponent < 0.45 }
        let action = try bounds(in: image) { $0.blueComponent > 0.6 && $0.blueComponent > $0.redComponent * 1.5 }
        #expect(action.minY <= word.maxY && action.maxY >= word.minY)
    }

    private func render(_ word: String, width: CGFloat) throws -> NSBitmapImageRep {
        let content = DictionaryRows(
            words: [word], removeID: { "delete.\($0)" }, deletionScope: .global,
            deleteConfirmConfirmID: "delete.confirm", deleteConfirmCancelID: "delete.cancel",
            onFindReplacements: { _ in }, onRemove: { _ in })
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .tint(.blue)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        return image
    }

    private func bounds(in image: NSBitmapImageRep, matching: (NSColor) -> Bool) throws -> CGRect {
        let pixels = (0..<image.pixelsHigh).flatMap { y in
            (0..<image.pixelsWide).compactMap { x -> CGPoint? in
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), matching(color) else { return nil }
                return CGPoint(x: x, y: y)
            }
        }
        let minX = try #require(pixels.map(\.x).min())
        let minY = try #require(pixels.map(\.y).min())
        let maxX = try #require(pixels.map(\.x).max())
        let maxY = try #require(pixels.map(\.y).max())
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
