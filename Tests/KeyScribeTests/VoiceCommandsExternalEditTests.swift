import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
@Suite(.serialized)
struct VoiceCommandsExternalEditTests {
    private struct Harness {
        let dir: URL
        let repository: ConfigRepository
        let model: VoiceCommandsSettingsModel
        let watcher: ConfigWatcher
        var file: URL { dir.appendingPathComponent(VoiceCommandStore.fileName) }
    }

    private let mail = VoiceCommandPlace(id: "mail", name: "Mail", target: .app(bundleId: "com.apple.mail"))
    private let note = VoiceCommandScript(id: "note", name: "Note", run: ["/bin/echo", "{text}"])
    private let deploy = VoiceCommandScript(id: "deploy", name: "Deploy", run: ["/bin/echo"])

    private func makeHarness(_ config: VoiceCommandConfig) throws -> Harness {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-vc-external-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try VoiceCommandStore.write(config, to: dir)
        let cache = ConfigCache(supportDir: dir)
        let gate = ConfigSelfWriteGate(baseline: ConfigTreeSnapshot.capture(supportDir: dir))
        let repository = ConfigRepository(supportDir: dir, config: cache, selfWriteGate: gate)
        let model = VoiceCommandsSettingsModel(
            repository: repository, system: LiveVoiceCommandSystem(roots: [], handlers: { [] }))
        let onChange: @Sendable () -> Void = { [gate] in
            guard gate.shouldReload(current: ConfigTreeSnapshot.capture(supportDir: dir)) else { return }
            Task { @MainActor in
                gate.adopt(ConfigTreeSnapshot.capture(supportDir: dir))
                cache.invalidate()
                repository.notifyExternalChange()
            }
        }
        let made: ConfigWatcher? = ConfigWatcher(path: dir.path, onChange: onChange)
        let watcher = try #require(made)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return Harness(dir: dir, repository: repository, model: model, watcher: watcher)
    }

    private func writeInPlace(_ config: VoiceCommandConfig, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        handle.write(Data(try VoiceCommandStore.encode(config).utf8))
        try handle.close()
    }

    private func replaceAtomically(_ text: String, at url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".voice_commands.toml.tmp")
        try text.write(to: temp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    private func eventually(_ h: Harness, names expected: [String]) async -> Bool {
        for _ in 0..<60 {
            if h.model.commands.map(\.name) == expected { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test func commandsAddedThenRemovedOutsideTheAppComeAndGoInTheList() async throws {
        let h = try makeHarness(VoiceCommandConfig(places: [mail]))
        defer { try? FileManager.default.removeItem(at: h.dir) }
        try writeInPlace(VoiceCommandConfig(places: [mail], scripts: [note, deploy]), to: h.file)
        #expect(await eventually(h, names: ["Mail", "Note", "Deploy"]))
        try writeInPlace(VoiceCommandConfig(places: [mail]), to: h.file)
        #expect(await eventually(h, names: ["Mail"]))
    }

    @Test func aToolThatReplacesTheWholeFileIsPickedUp() async throws {
        let h = try makeHarness(VoiceCommandConfig(places: [mail], scripts: [note]))
        defer { try? FileManager.default.removeItem(at: h.dir) }
        try replaceAtomically(
            """
            schema_version = 1

            [[command]]
            id = 'mail'
            name = 'Mail'
            app = 'com.apple.mail'
            """, at: h.file)
        #expect(await eventually(h, names: ["Mail"]))
    }

    @Test func deletingTheFileEmptiesTheList() async throws {
        let h = try makeHarness(VoiceCommandConfig(places: [mail], scripts: [note]))
        defer { try? FileManager.default.removeItem(at: h.dir) }
        try FileManager.default.removeItem(at: h.file)
        #expect(await eventually(h, names: []))
    }

    @Test func savingAfterAnOutsideRemovalKeepsItRemoved() async throws {
        let h = try makeHarness(VoiceCommandConfig(places: [mail], scripts: [note, deploy]))
        defer { try? FileManager.default.removeItem(at: h.dir) }
        try writeInPlace(VoiceCommandConfig(places: [mail]), to: h.file)
        #expect(await eventually(h, names: ["Mail"]))
        var renamed = mail
        renamed.name = "Email"
        #expect(h.model.save(renamed, replacing: "Mail") == nil)
        #expect(VoiceCommandStore.loadOrDefault(supportDir: h.dir).commands.map(\.name) == ["Email"])
    }

    @Test func savingBeforeTheListCaughtUpStillKeepsAnOutsideRemoval() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-vc-external-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try VoiceCommandStore.write(VoiceCommandConfig(places: [mail], scripts: [note, deploy]), to: dir)
        let repository = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        let model = VoiceCommandsSettingsModel(
            repository: repository, system: LiveVoiceCommandSystem(roots: [], handlers: { [] }))
        try VoiceCommandStore.write(VoiceCommandConfig(places: [mail]), to: dir)
        #expect(model.commands.map(\.name) == ["Mail", "Note", "Deploy"])
        var renamed = mail
        renamed.name = "Email"
        #expect(model.save(renamed, replacing: "Mail") == nil)
        #expect(VoiceCommandStore.loadOrDefault(supportDir: dir).commands.map(\.name) == ["Email"])
        #expect(model.commands.map(\.name) == ["Email"])
        var editedNote = note
        editedNote.say = ["jot"]
        #expect(model.saveScript(editedNote, replacing: "Note") == VoiceCommandsSettingsModel.staleEditMessage)
        #expect(VoiceCommandStore.loadOrDefault(supportDir: dir).commands.map(\.name) == ["Email"])
    }

    @Test func settingsOpenedAfterAnOutsideEditShowsTheFile() async throws {
        let h = try makeHarness(VoiceCommandConfig(places: [mail], scripts: [note]))
        defer { try? FileManager.default.removeItem(at: h.dir) }
        try writeInPlace(VoiceCommandConfig(places: [mail]), to: h.file)
        #expect(await eventually(h, names: ["Mail"]))
        let reopened = VoiceCommandsSettingsModel(
            repository: h.repository, system: LiveVoiceCommandSystem(roots: [], handlers: { [] }))
        #expect(reopened.commands.map(\.name) == ["Mail"])
    }
}
