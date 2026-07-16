import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// FragmentStore.url(forID:in:) is the filesystem boundary for fragment ids (KS-03). Decoded modes are
// validated at load, so these paths are not reachable through ordinary config today — but they take an id
// and build a path from it, and one of them DELETES what it builds. Keeping them on the boundary means the
// guarantee does not depend on every caller being reached through a validating decode.
@MainActor
struct FragmentBoundaryTests {
    private func makeModel() throws -> (ModesSettingsModel, URL) {
        let fm = FileManager.default
        let support = fm.temporaryDirectory.appendingPathComponent("keyscribe-fragbound-\(UUID().uuidString)")
        try fm.createDirectory(at: support.appendingPathComponent("modes"), withIntermediateDirectories: true)
        try fm.createDirectory(at: support.appendingPathComponent("fragments"), withIntermediateDirectories: true)
        let repository = ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support))
        return (ModesSettingsModel(repository: repository), support)
    }

    // The destructive one: closeFragment removes the file it builds from `id`, so a traversing id would
    // delete an unrelated Markdown file outside the fragments directory.
    @Test func closingAnEmptyFragmentCannotDeleteOutsideTheFragmentsDirectory() throws {
        let (model, support) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }

        let outsider = support.appendingPathComponent("notes.md")
        try "private notes".write(to: outsider, atomically: true, encoding: .utf8)

        model.closeFragment("../notes", fromMode: "nonexistent")

        #expect(FileManager.default.fileExists(atPath: outsider.path))
        #expect(try String(contentsOf: outsider, encoding: .utf8) == "private notes")
    }

    // revealFragment is deliberately not covered here: its only effect is a Finder reveal with no seam to
    // observe, so any test would pass with or without the boundary. Its id validation is pinned directly on
    // FragmentStore.url(forID:in:) in FragmentStoreTests, which revealFragment now routes through.

    // The boundary must not break ordinary ids — an in-directory fragment still deletes on close.
    @Test func closingAnEmptyOrdinaryFragmentStillDeletesItsFile() throws {
        let (model, support) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }

        let fragment = support.appendingPathComponent("fragments/style.md")
        try "".write(to: fragment, atomically: true, encoding: .utf8)

        model.closeFragment("style", fromMode: "nonexistent")

        #expect(!FileManager.default.fileExists(atPath: fragment.path))
    }
}
