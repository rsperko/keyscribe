import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

struct ShortcutsToolTests {
    private func script(_ body: String) throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-shortcuts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("tool.sh")
        try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return (dir, file)
    }

    @Test func aShortcutGivenInputIsToldToReadItFromStandardInput() {
        let shortcut = VoiceCommandShortcut(name: "Add Reminder", identifier: "ABC-123")
        #expect(LiveVoiceCommandSystem.shortcutArguments(shortcut, input: "buy milk") == ["run", "ABC-123", "--input-path", "-"])
        #expect(LiveVoiceCommandSystem.shortcutArguments(shortcut, input: nil) == ["run", "ABC-123"])
    }

    @Test func theListIsReadFromTheToolsOutput() throws {
        let (dir, file) = try script("printf 'Add Reminder (ABC-123)\\n'")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LiveVoiceCommandSystem.readOutput(program: file.path, arguments: [], within: 10) == "Add Reminder (ABC-123)\n")
    }

    @Test func aListThatNeverFinishesGivesUpAtTheDeadline() throws {
        let (dir, file) = try script("sleep 30")
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date()
        #expect(LiveVoiceCommandSystem.readOutput(program: file.path, arguments: [], within: 0.5) == nil)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func aFailingListGivesNothing() throws {
        let (dir, file) = try script("exit 1")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LiveVoiceCommandSystem.readOutput(program: file.path, arguments: [], within: 10) == nil)
    }
}
