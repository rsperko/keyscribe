import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

@MainActor
struct ModesSettingsModelTests {
    private func makeModel() throws -> (ModesSettingsModel, URL, URL) {
        let fm = FileManager.default
        let support = fm.temporaryDirectory.appendingPathComponent("keyscribe-modes-\(UUID().uuidString)")
        let modesDir = support.appendingPathComponent("modes")
        try fm.createDirectory(at: modesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: support.appendingPathComponent("fragments"), withIntermediateDirectories: true)
        return (ModesSettingsModel(modesDir: modesDir, supportDir: support), support, modesDir)
    }

    private func tomls(in dir: URL) -> Set<String> {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return Set(urls.filter { $0.pathExtension == "toml" }.map { $0.deletingPathExtension().lastPathComponent })
    }

    @Test func namingAFreshModeReslugsTheFile() throws {
        let (model, support, modesDir) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }

        model.create()
        #expect(tomls(in: modesDir) == ["new-mode"])

        var renamed = try #require(model.selected)
        renamed.name = "Email Reply"
        model.update(renamed)

        #expect(tomls(in: modesDir) == ["email-reply"])
        #expect(model.modes.map(\.id) == ["email-reply"])
        #expect(model.selectedID == "email-reply")
        #expect(model.selected?.name == "Email Reply")
    }

    @Test func renamingAfterInitialNamingDoesNotReslug() throws {
        let (model, support, modesDir) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }

        model.create()
        var first = try #require(model.selected)
        first.name = "Email"
        model.update(first)
        #expect(tomls(in: modesDir) == ["email"])

        var second = try #require(model.selected)
        second.name = "Slack Reply"
        model.update(second)

        #expect(tomls(in: modesDir) == ["email"])
        #expect(model.selected?.name == "Slack Reply")
        #expect(model.selectedID == "email")
    }

    @Test func editingOtherFieldsBeforeNamingKeepsReslugPending() throws {
        let (model, support, modesDir) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }

        model.create()
        var toggled = try #require(model.selected)
        toggled.enabled = false
        model.update(toggled)
        #expect(tomls(in: modesDir) == ["new-mode"])

        var named = try #require(model.selected)
        named.name = "Notes"
        model.update(named)

        #expect(tomls(in: modesDir) == ["notes"])
        #expect(model.selected?.enabled == false)
    }

    @Test func reslugDedupesAgainstAnExistingMode() throws {
        let (model, support, modesDir) = try makeModel()
        defer { try? FileManager.default.removeItem(at: support) }

        model.create()
        var first = try #require(model.selected)
        first.name = "Email"
        model.update(first)

        model.create()
        var second = try #require(model.selected)
        second.name = "Email"
        model.update(second)

        #expect(tomls(in: modesDir) == ["email", "email-2"])
        #expect(model.selectedID == "email-2")
    }
}
