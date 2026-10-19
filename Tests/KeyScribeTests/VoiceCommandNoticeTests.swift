import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct VoiceCommandNoticeTests {
    @Test func acknowledgmentsPersistIndependentlyForEachConfiguration() throws {
        let suite = "keyscribe-notices-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let notices = VoiceCommandNotices(supportDir: dir, defaults: defaults)
        #expect(notices.needsAcknowledgment(.apps))
        #expect(notices.needsAcknowledgment(.scripts))

        notices.acknowledge(.apps)

        let reopened = VoiceCommandNotices(supportDir: dir, defaults: defaults)
        #expect(!reopened.needsAcknowledgment(.apps))
        #expect(reopened.needsAcknowledgment(.scripts))
        let other = VoiceCommandNotices(supportDir: dir.appendingPathComponent("other"), defaults: defaults)
        #expect(other.needsAcknowledgment(.apps))
    }

    @Test func enablingCommandsWaitsForAcknowledgmentAndCancelKeepsThemOff() throws {
        let suite = "keyscribe-notices-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let notices = VoiceCommandNotices(supportDir: URL(fileURLWithPath: "/test"), defaults: defaults)
        var saved: [Settings] = []
        let model = SettingsModel(
            settings: .defaults, onChange: { saved.append($0) }, onReload: {}, onResetHUDPosition: {},
            voiceCommandNotices: notices)

        model.binding(for: .voiceCommands).wrappedValue = true
        #expect(model.confirmingVoiceCommands)
        #expect(!model.binding(for: .voiceCommands).wrappedValue)
        #expect(saved.isEmpty)

        model.confirmingVoiceCommands = false
        #expect(notices.needsAcknowledgment(.apps))
        #expect(saved.isEmpty)

        model.binding(for: .voiceCommands).wrappedValue = true
        model.confirmVoiceCommands()
        #expect(!model.confirmingVoiceCommands)
        #expect(saved.last?.features.isEnabled(.voiceCommands) == true)
        #expect(!notices.needsAcknowledgment(.apps))
        #expect(notices.needsAcknowledgment(.scripts))

        model.binding(for: .voiceCommands).wrappedValue = false
        model.binding(for: .voiceCommands).wrappedValue = true
        #expect(!model.confirmingVoiceCommands)
        #expect(saved.last?.features.isEnabled(.voiceCommands) == true)
    }

    @Test func resettingConfigurationRestoresBothNotices() throws {
        let suite = "keyscribe-notices-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let notices = VoiceCommandNotices(supportDir: dir, defaults: defaults)
        notices.acknowledge(.apps)
        notices.acknowledge(.scripts)

        ResetTool(supportDir: dir, defaults: defaults).run(.config)

        #expect(notices.needsAcknowledgment(.apps))
        #expect(notices.needsAcknowledgment(.scripts))
    }
}
