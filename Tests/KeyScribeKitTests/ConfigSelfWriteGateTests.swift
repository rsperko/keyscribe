import Foundation
import Testing
@testable import KeyScribeKit

struct ConfigSelfWriteGateTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-selfwrite-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func matchingBaselineDoesNotReload() {
        let gate = ConfigSelfWriteGate(baseline: .init(stamps: ["settings.toml": "10:5"]))
        #expect(gate.shouldReload(current: .init(stamps: ["settings.toml": "10:5"])) == false)
    }

    @Test func differingBaselineReloads() {
        let gate = ConfigSelfWriteGate(baseline: .init(stamps: ["settings.toml": "10:5"]))
        #expect(gate.shouldReload(current: .init(stamps: ["settings.toml": "11:6"])) == true)
    }

    @Test func recordSelfWriteSuppressesTheEcho() {
        let gate = ConfigSelfWriteGate(baseline: .init(stamps: ["settings.toml": "10:5"]))
        gate.recordSelfWrite(relativePath: "settings.toml", stamp: "12:9")
        #expect(gate.shouldReload(current: .init(stamps: ["settings.toml": "12:9"])) == false)
    }

    // A self-write to one file must not mask an external edit to another.
    @Test func externalEditToAnotherFileStillReloadsAfterASelfWrite() {
        let gate = ConfigSelfWriteGate(baseline: .init(stamps: ["settings.toml": "10:5", "modes/a.toml": "3:1"]))
        gate.recordSelfWrite(relativePath: "settings.toml", stamp: "12:9")
        #expect(gate.shouldReload(current: .init(stamps: ["settings.toml": "12:9", "modes/a.toml": "4:2"])) == true)
    }

    @Test func recordingARemovalTracksDeletes() {
        let gate = ConfigSelfWriteGate(baseline: .init(stamps: ["modes/old.toml": "3:1"]))
        gate.recordSelfWrite(relativePath: "modes/old.toml", stamp: nil)
        #expect(gate.shouldReload(current: .init(stamps: [:])) == false)
        #expect(gate.shouldReload(current: .init(stamps: ["modes/old.toml": "3:1"])) == true)
    }

    @Test func adoptResetsTheBaseline() {
        let gate = ConfigSelfWriteGate(baseline: .init(stamps: ["settings.toml": "10:5"]))
        gate.adopt(.init(stamps: ["settings.toml": "99:99", "connections.toml": "1:1"]))
        #expect(gate.shouldReload(current: .init(stamps: ["settings.toml": "99:99", "connections.toml": "1:1"])) == false)
        #expect(gate.shouldReload(current: .init(stamps: ["settings.toml": "10:5"])) == true)
    }

    @Test func captureStampsTopLevelAndNestedConfigFiles() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        write("a", to: dir.appendingPathComponent("settings.toml"))
        write("b", to: dir.appendingPathComponent("modes/direct.toml"))
        write("c", to: dir.appendingPathComponent("fragments/voice.md"))

        let snap = ConfigTreeSnapshot.capture(supportDir: dir)
        #expect(snap.stamps.keys.contains("settings.toml"))
        #expect(snap.stamps.keys.contains("modes/direct.toml"))
        #expect(snap.stamps.keys.contains("fragments/voice.md"))
    }

    @Test func capturePrunesHistoryLkgAndModels() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        write("x", to: dir.appendingPathComponent("settings.toml"))
        write("h", to: dir.appendingPathComponent("history/2026-07-02.jsonl"))
        write("l", to: dir.appendingPathComponent("lkg/modes/direct.toml"))
        write("m", to: dir.appendingPathComponent("models/whisper/model.bin"))

        let snap = ConfigTreeSnapshot.capture(supportDir: dir)
        #expect(snap.stamps.keys.contains("settings.toml"))
        #expect(!snap.stamps.keys.contains { $0.hasPrefix("history/") })
        #expect(!snap.stamps.keys.contains { $0.hasPrefix("lkg/") })
        #expect(!snap.stamps.keys.contains { $0.hasPrefix("models/") })
    }

    @Test func captureChangesWhenAConfigFileIsEdited() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.toml")
        write("original", to: file)
        let before = ConfigTreeSnapshot.capture(supportDir: dir)
        write("edited-longer-content", to: file)
        let after = ConfigTreeSnapshot.capture(supportDir: dir)
        #expect(before != after)
    }

    @Test func selfWriteIsSuppressedButExternalEditReloads() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("settings.toml")
        write("v1", to: settings)

        let gate = ConfigSelfWriteGate(baseline: ConfigTreeSnapshot.capture(supportDir: dir))

        write("v2-in-app", to: settings)
        gate.recordSelfWrite(url: settings, supportDir: dir)
        #expect(gate.shouldReload(current: ConfigTreeSnapshot.capture(supportDir: dir)) == false)

        write("v3-external-longer", to: settings)   // not recorded as a self-write
        #expect(gate.shouldReload(current: ConfigTreeSnapshot.capture(supportDir: dir)) == true)
    }
}
