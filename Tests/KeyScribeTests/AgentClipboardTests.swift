import AppKit
import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct AgentClipboardTests {
    private func clipboard(_ fill: (NSPasteboard) -> Void, now: Date = Date()) -> (AgentClipboard, URL) {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        fill(pasteboard)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-clipboard-\(UUID().uuidString)")
        return (AgentClipboard(pasteboard: pasteboard, folder: folder, now: { now }, restorePending: {}), folder)
    }

    private func pixel(_ type: NSBitmapImageRep.FileType) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: type, properties: [:])!
    }

    @Test func textIsTheTextAsToday() {
        let (reader, folder) = clipboard { $0.setString("x = 1", forType: .string) }
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(reader.read() == ClipboardTokenizer.Clip(text: "x = 1"))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func copiedFilesAreTheirPathsNotTheirNames() {
        let (reader, folder) = clipboard {
            $0.writeObjects([URL(fileURLWithPath: "/tmp/a.png") as NSURL, URL(fileURLWithPath: "/tmp/My Notes.pdf") as NSURL])
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(reader.read() == .files(["/tmp/a.png", "/tmp/My Notes.pdf"]))
        #expect(reader.images(in: "/tmp/a.png").isEmpty)
    }

    @Test func anImageIsSavedAsAPNGTheAgentCanOpen() throws {
        let (reader, folder) = clipboard { $0.setData(pixel(.tiff), forType: .tiff) }
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try #require(reader.read())
        #expect(clip.isFiles)
        #expect(clip.text.hasPrefix(folder.path + "/") && clip.text.hasSuffix(".png"))
        let saved = try Data(contentsOf: URL(fileURLWithPath: clip.text))
        #expect(saved.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(reader.images(in: "look at \(clip.text) now") == [clip.text])
        #expect(reader.images(in: "nothing here").isEmpty)
    }

    @Test func theSameClipboardSaidTwiceIsSavedOnce() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setData(pixel(.png), forType: .png)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-clipboard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let reader = AgentClipboard(pasteboard: pasteboard, folder: folder, restorePending: {})
        let first = try #require(reader.read())
        #expect(reader.read() == first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
        try FileManager.default.removeItem(atPath: first.text)
        let again = try #require(reader.read())
        #expect(again != first && FileManager.default.fileExists(atPath: again.text))
        pasteboard.clearContents()
        pasteboard.setData(pixel(.png), forType: .png)
        #expect(try #require(reader.read()) != again)
    }

    @Test func aBrowsersImageCopyIsTheImageNotItsAddress() throws {
        let (reader, folder) = clipboard {
            $0.declareTypes([.string, .png], owner: nil)
            $0.setString("https://example.com/cat.png", forType: .string)
            $0.setData(pixel(.png), forType: .png)
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try #require(reader.read())
        #expect(clip.isFiles && clip.text.hasSuffix(".png"))
        let (prose, proseFolder) = clipboard {
            $0.declareTypes([.string, .png], owner: nil)
            $0.setString("see https://example.com/cat.png", forType: .string)
            $0.setData(pixel(.png), forType: .png)
        }
        defer { try? FileManager.default.removeItem(at: proseFolder) }
        #expect(prose.read() == ClipboardTokenizer.Clip(text: "see https://example.com/cat.png"))
    }

    @Test func whatTheClipboardHeldIsCountedAndAnEmptyOneIsNoticed() throws {
        let (reader, folder) = clipboard { $0.setData(pixel(.png), forType: .png) }
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try #require(reader.read()).text
        #expect(reader.note(for: "see \(image)", attached: true) == AgentOutput.ClipboardNote(images: 1, files: 0, attached: true))
        let (empty, emptyFolder) = clipboard { _ in }
        defer { try? FileManager.default.removeItem(at: emptyFolder) }
        #expect(empty.read() == nil)
        #expect(empty.note(for: "insert clipboard contents", attached: false) == AgentOutput.ClipboardNote(missed: true))
        empty.beginTake()
        #expect(empty.note(for: "insert clipboard contents", attached: false) == AgentOutput.ClipboardNote())
    }

    @Test func aPNGIsKeptAsItIs() throws {
        let png = pixel(.png)
        let (reader, folder) = clipboard { $0.setData(png, forType: .png) }
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try #require(reader.read())
        #expect(try Data(contentsOf: URL(fileURLWithPath: clip.text)) == png)
    }

    @Test func aPDFIsSavedAsAFileButIsNoImage() throws {
        let pdf = Data("%PDF-1.4\n%%EOF\n".utf8)
        let (reader, folder) = clipboard { $0.setData(pdf, forType: .pdf) }
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try #require(reader.read())
        #expect(clip.isFiles && clip.text.hasSuffix(".pdf"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: clip.text)) == pdf)
        #expect(reader.images(in: clip.text).isEmpty)
    }

    @Test func anEmptyClipboardIsNothing() {
        let (reader, folder) = clipboard { _ in }
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(reader.read() == nil)
    }

    @Test func expiredFilesAreRemovedWithoutAnotherSave() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-clipboard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let old = folder.appendingPathComponent("clipboard-1-a.png")
        let recent = folder.appendingPathComponent("clipboard-2-b.png")
        for (url, date) in [(old, start), (recent, start + 3600)] {
            try Data("png".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        #expect(AgentClipboard.removeExpired(in: folder, now: start + AgentClipboard.keptFor + 1) == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(AgentClipboard.removeExpired(in: folder.appendingPathComponent("missing"), now: start) == 0)
    }

    @Test func aFolderLeftOpenToOthersIsClosedAgainOnTheNextSave() throws {
        let (reader, folder) = clipboard { $0.setData(pixel(.png), forType: .png) }
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        _ = try #require(reader.read())
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
    }

    @Test func savingRemovesWhatWasSavedLongAgoAndKeepsTheRest() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var now = start
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setData(pixel(.png), forType: .png)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-clipboard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let reader = AgentClipboard(pasteboard: pasteboard, folder: folder, now: { now }, restorePending: {})
        let copyAgain = {
            pasteboard.clearContents()
            pasteboard.setData(self.pixel(.png), forType: .png)
        }
        let old = try #require(reader.read()).text
        try FileManager.default.setAttributes([.modificationDate: start], ofItemAtPath: old)
        now = start + AgentClipboard.keptFor - 60
        copyAgain()
        let recent = try #require(reader.read()).text
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: recent)
        now = start + AgentClipboard.keptFor + 1
        copyAgain()
        let newest = try #require(reader.read()).text
        #expect(!FileManager.default.fileExists(atPath: old))
        #expect(FileManager.default.fileExists(atPath: recent))
        #expect(FileManager.default.fileExists(atPath: newest))
        #expect(Set([old, recent, newest]).count == 3)
    }
}
