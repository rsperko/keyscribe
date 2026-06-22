import Foundation
import Testing
@testable import KeyScribeKit

struct FragmentStoreTests {
    @Test func parsesBodyAfterYAMLFrontmatter() {
        let s = "---\nschema_version: 1\nname: My Voice\n---\nWrite in my voice: warm, terse, plain."
        #expect(FragmentStore.body(ofFile: s) == "Write in my voice: warm, terse, plain.")
    }

    @Test func noFrontmatterReturnsTrimmedWholeBody() {
        #expect(FragmentStore.body(ofFile: "  Just text.  ") == "Just text.")
    }

    @Test func dashesInsideBodyAreNotTreatedAsFrontmatter() {
        let s = "---\nname: X\n---\nLine one\n--- still body\nLine two"
        #expect(FragmentStore.body(ofFile: s) == "Line one\n--- still body\nLine two")
    }

    @Test func emptyBodyIsEmpty() {
        #expect(FragmentStore.body(ofFile: "---\nname: X\n---\n") == "")
    }

    @Test func slugLowercasesAndHyphenates() {
        #expect(FragmentStore.slug(for: "My Voice") == "my-voice")
        #expect(FragmentStore.slug(for: "  email — style!  ") == "email-style")
        #expect(FragmentStore.slug(for: "already-a-slug") == "already-a-slug")
        #expect(FragmentStore.slug(for: "   ") == "")
    }

    @Test func idsListsMarkdownStemsSorted() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("zeta.md"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        #expect(FragmentStore.ids(in: dir) == ["alpha", "zeta"])
    }

    @Test func idsIsEmptyWhenDirMissing() {
        #expect(FragmentStore.ids(in: tempDir().appendingPathComponent("nope")) == [])
    }

    @Test func createIfNeededWritesAStarterFileAndReturnsTheSlug() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try FragmentStore.createIfNeeded(name: "My Voice", in: dir)
        #expect(id == "my-voice")
        let url = dir.appendingPathComponent("my-voice.md")
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("name: My Voice"))
        #expect(written.contains("schema_version: 1"))
        #expect(FragmentStore.ids(in: dir) == ["my-voice"])
    }

    @Test func createIfNeededDoesNotOverwriteAnExistingFragment() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("my-voice.md")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: Mine\n---\nKeep this.".write(to: url, atomically: true, encoding: .utf8)

        let id = try FragmentStore.createIfNeeded(name: "my-voice", in: dir)
        #expect(id == "my-voice")
        #expect(try String(contentsOf: url, encoding: .utf8) == "---\nname: Mine\n---\nKeep this.")
    }

    @Test func createIfNeededRejectsAnEmptyName() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: (any Error).self) { try FragmentStore.createIfNeeded(name: "   ", in: dir) }
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-frag-\(UUID().uuidString)", isDirectory: true)
    }
}
