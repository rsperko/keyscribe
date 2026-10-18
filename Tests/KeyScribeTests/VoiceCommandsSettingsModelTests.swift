import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct VoiceCommandsSettingsModelTests {
    private func make() -> (VoiceCommandsSettingsModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-vcsettings-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repository = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        return (VoiceCommandsSettingsModel(repository: repository), dir)
    }

    private let mail = VoiceCommandPlace(name: "Mail", say: ["inbox"], target: .url("https://mail.google.com/"))

    @Test func addingAPlaceWritesTheFile() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(model.save(mail, replacing: nil) == nil)
        #expect(model.places == [mail])
        #expect(VoiceCommandStore.loadOrDefault(supportDir: dir).places == [mail])
    }

    @Test func editingReplacesInPlaceAndCanRename() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let code = VoiceCommandPlace(name: "Code", target: .app(bundleId: "com.microsoft.VSCode"))
        _ = model.save(mail, replacing: nil)
        _ = model.save(code, replacing: nil)
        var renamed = mail
        renamed.name = "Gmail"
        #expect(model.save(renamed, replacing: "Mail") == nil)
        #expect(model.places.map(\.name) == ["Gmail", "Code"])
    }

    @Test func aDuplicateNameIsRefused() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = model.save(mail, replacing: nil)
        let other = VoiceCommandPlace(name: "mail", target: .app(bundleId: "com.apple.mail"))
        #expect(model.save(other, replacing: nil) == "Another place already uses this name.")
        #expect(model.places == [mail])
    }

    @Test func anInvalidPlaceIsRefusedWithItsIssue() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = VoiceCommandPlace(name: "Web", target: .url("mail.google.com"))
        #expect(model.save(bad, replacing: nil) != nil)
        #expect(model.places.isEmpty)
    }

    @Test func deleteRemovesThePlace() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = model.save(mail, replacing: nil)
        #expect(model.delete(named: "MAIL") == nil)
        #expect(model.places.isEmpty)
    }

    @Test func aMalformedFileBlocksEditingAndExplainsWhy() throws {
        let (model, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "schema_version = 1\n[[place]]\nname = \"Nowhere\"\n"
            .write(to: dir.appendingPathComponent(VoiceCommandStore.fileName), atomically: true, encoding: .utf8)
        model.reload()
        #expect(model.loadError != nil)
        #expect(model.save(mail, replacing: nil) != nil)
    }

    @Test func tryItDescribesWithoutRunning() {
        let summary = VoiceCommandsSettingsModel.describe(.noMatch("banana"), heard: "go to banana", appName: { _ in nil })
        #expect(!summary.resolved)
        #expect(summary.summary == "No match")
        let action = VoiceCommandsSettingsModel.describe(
            .action(.app(.init(name: "Ghostty", bundleId: "com.mitchellh.ghostty"))), heard: "switch to ghostty", appName: { _ in nil })
        #expect(action.resolved)
        #expect(action.summary == "Ghostty")
    }

    @Test func tryItReadsWithTheVocabularyLiveCommandsUse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-vcsettings-\(UUID().uuidString)")
        let modesDir = dir.appendingPathComponent("modes", isDirectory: true)
        try FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var commands = Mode.voiceCommands
        commands.dictionary.words = ["herdr"]
        try ModeStore.write(commands, to: modesDir)
        let config = ConfigCache(supportDir: dir)
        config.voiceCommandsEnabled = true
        let model = VoiceCommandsSettingsModel(repository: ConfigRepository(supportDir: dir, config: config))
        _ = config.resolved

        try "not toml".write(to: modesDir.appendingPathComponent("\(Mode.voiceCommandsId).toml"), atomically: true, encoding: .utf8)

        #expect(model.readAs("switch to herder") == "switch to herdr")
    }

    @Test func tryItShowsWhatTheVocabularyChanged() {
        let cleaned = VoiceCommandsSettingsModel.describe(
            .noMatch("herdr"), heard: "bitch to herder", readAs: "switch to herdr", appName: { _ in nil })
        #expect(cleaned.readAs == "switch to herdr")
        let unchanged = VoiceCommandsSettingsModel.describe(
            .noMatch("herdr"), heard: "go to herdr", readAs: "go to herdr", appName: { _ in nil })
        #expect(unchanged.readAs == nil)
    }

    @Test func suggestedPlaceNameComesFromTheTabTitle() {
        #expect(VoiceCommandsEditorView.suggestedName(title: "Inbox - me@example.com - Gmail", url: "https://mail.google.com/") == "Inbox")
        #expect(VoiceCommandsEditorView.suggestedName(title: "", url: "https://www.github.com/x") == "github.com")
    }
}
