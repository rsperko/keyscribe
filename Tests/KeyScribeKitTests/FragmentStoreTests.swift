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

    @Test func nameReadsYAMLNameField() {
        let s = "---\nschema_version: 1\nname: My Voice\n---\nWrite in my voice."
        #expect(FragmentStore.name(ofFile: s) == "My Voice")
    }

    @Test func nameNilWhenNoFrontmatter() {
        #expect(FragmentStore.name(ofFile: "Just text.") == nil)
    }

    @Test func nameNilWhenFieldAbsentOrEmpty() {
        #expect(FragmentStore.name(ofFile: "---\nschema_version: 1\n---\nbody") == nil)
        #expect(FragmentStore.name(ofFile: "---\nname:   \n---\nbody") == nil)
    }

    @Test func replacingBodyPreservesFrontmatter() {
        let s = "---\nschema_version: 1\nname: My Voice\n---\nOld body."
        let out = FragmentStore.replacingBody(inFile: s, with: "  New body.  ")
        #expect(out == "---\nschema_version: 1\nname: My Voice\n---\nNew body.\n")
        #expect(FragmentStore.body(ofFile: out) == "New body.")
        #expect(FragmentStore.name(ofFile: out) == "My Voice")
    }

    @Test func replacingBodyKeepsHeaderWhenBodyCleared() {
        let s = "---\nname: X\n---\nold"
        #expect(FragmentStore.replacingBody(inFile: s, with: "  ") == "---\nname: X\n---\n")
    }

    @Test func replacingBodyWithoutFrontmatterReturnsTrimmedBody() {
        #expect(FragmentStore.replacingBody(inFile: "old", with: "  new  ") == "new")
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
        let (id, created) = try FragmentStore.createIfNeeded(name: "My Voice", in: dir)
        #expect(id == "my-voice")
        #expect(created)
        let url = dir.appendingPathComponent("my-voice.md")
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("name: My Voice"))
        #expect(written.contains("schema_version: 1"))
        #expect(FragmentStore.body(ofFile: written) == "")
        #expect(FragmentStore.ids(in: dir) == ["my-voice"])
    }

    @Test func createIfNeededDoesNotOverwriteAnExistingFragment() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("my-voice.md")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: Mine\n---\nKeep this.".write(to: url, atomically: true, encoding: .utf8)

        let (id, created) = try FragmentStore.createIfNeeded(name: "my-voice", in: dir)
        #expect(id == "my-voice")
        #expect(!created)
        #expect(try String(contentsOf: url, encoding: .utf8) == "---\nname: Mine\n---\nKeep this.")
    }

    @Test func createIfNeededRejectsAnEmptyName() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: (any Error).self) { try FragmentStore.createIfNeeded(name: "   ", in: dir) }
    }

    @Test func validIDsAreSingleFilenameStems() {
        #expect(FragmentStore.isValidID("my-voice"))
        #expect(FragmentStore.isValidID("café-notes"))
        #expect(FragmentStore.isValidID("私の声"))
        #expect(FragmentStore.isValidID("my notes"))
        #expect(FragmentStore.isValidID("v1.2"))
    }

    @Test func invalidIDsAreRejected() {
        #expect(!FragmentStore.isValidID(""))
        #expect(!FragmentStore.isValidID("   "))
        #expect(!FragmentStore.isValidID("."))
        #expect(!FragmentStore.isValidID(".."))
        #expect(!FragmentStore.isValidID(".hidden"))
        #expect(!FragmentStore.isValidID("../x"))
        #expect(!FragmentStore.isValidID("../../notes/private"))
        #expect(!FragmentStore.isValidID("/etc/passwd"))
        #expect(!FragmentStore.isValidID("/Users/someone/notes"))
        #expect(!FragmentStore.isValidID("sub/dir"))
        #expect(!FragmentStore.isValidID("sub\\dir"))
        #expect(!FragmentStore.isValidID("a:b"))
        #expect(!FragmentStore.isValidID("..%2F..%2Fsecrets"))
        #expect(!FragmentStore.isValidID("%2e%2e%2fx"))
        #expect(!FragmentStore.isValidID("a\u{0000}b"))
        #expect(!FragmentStore.isValidID("a\nb"))
        #expect(!FragmentStore.isValidID(" leading"))
        #expect(!FragmentStore.isValidID("trailing "))
        #expect(!FragmentStore.isValidID("cafe\u{0301}-notes"))
        #expect(!FragmentStore.isValidID(String(repeating: "a", count: 201)))
    }

    @Test func urlForIDResolvesInsideTheFragmentsDirectory() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = try #require(FragmentStore.url(forID: "my-voice", in: dir))
        #expect(url.lastPathComponent == "my-voice.md")
        #expect(url.deletingLastPathComponent().resolvingSymlinksInPath().path
            == dir.resolvingSymlinksInPath().path)
        #expect(FragmentStore.url(forID: "../escape", in: dir) == nil)
        #expect(FragmentStore.url(forID: "/etc/passwd", in: dir) == nil)
        #expect(FragmentStore.url(forID: "", in: dir) == nil)
    }

    @Test func loadRejectsTraversalIDsInsteadOfReadingOutsideTheDirectory() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("fragments", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let secret = root.appendingPathComponent("private.md")
        try "Secret notes.".write(to: secret, atomically: true, encoding: .utf8)

        #expect(FragmentStore.load(ids: ["../private"], from: dir) == [])
        #expect(FragmentStore.load(ids: [secret.deletingPathExtension().path], from: dir) == [])
        #expect(FragmentStore.load(ids: ["../../etc/hosts"], from: dir) == [])
    }

    @Test func loadRejectsAnInDirectorySymlinkPointingOutside() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("fragments", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let secret = root.appendingPathComponent("private.md")
        try "Secret notes.".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("leak.md"), withDestinationURL: secret)

        #expect(FragmentStore.load(ids: ["leak"], from: dir) == [])
        #expect(FragmentStore.url(forID: "leak", in: dir) == nil)
    }

    @Test func loadReadsAnOrdinaryUnicodeSlugFragment() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: Café\n---\nWrite warmly."
            .write(to: dir.appendingPathComponent("café-notes.md"), atomically: true, encoding: .utf8)
        #expect(FragmentStore.load(ids: ["café-notes"], from: dir) == ["Write warmly."])
        #expect(FragmentStore.name(id: "café-notes", in: dir) == "Café")
    }

    @Test func loadSkipsAFragmentOverTheByteLimit() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let big = String(repeating: "a", count: FragmentStore.maxFragmentBytes + 1)
        try big.write(to: dir.appendingPathComponent("huge.md"), atomically: true, encoding: .utf8)
        try "small".write(to: dir.appendingPathComponent("small.md"), atomically: true, encoding: .utf8)
        #expect(FragmentStore.load(ids: ["huge", "small"], from: dir) == ["small"])
    }

    @Test func idsOmitsFilesWithInvalidStems() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("good.md"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent(".hidden.md"), atomically: true, encoding: .utf8)
        #expect(FragmentStore.ids(in: dir) == ["good"])
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-frag-\(UUID().uuidString)", isDirectory: true)
    }
}
