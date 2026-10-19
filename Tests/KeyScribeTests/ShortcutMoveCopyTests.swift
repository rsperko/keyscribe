import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

struct ShortcutMoveCopyTests {
    private func commands(_ keys: String...) -> Mode {
        var mode = Mode.voiceCommands
        mode.triggerKeys = keys.map { Mode.TriggerKey(key: $0) }
        return mode
    }

    private func mode(_ name: String, _ keys: String...) -> Mode {
        var mode = Mode(id: name.lowercased(), name: name)
        mode.triggerKeys = keys.map { Mode.TriggerKey(key: $0) }
        return mode
    }

    @Test func movingToVoiceCommandsNamesEveryModeAndWhatThePressWillDo() throws {
        let move = try #require(VoiceCommandTriggers.move(
            commands("right_option"), in: [mode("Polish", "right_option", "f12"), mode("Email", "right_option")]))
        let copy = ShortcutMoveCopy(move, notice: nil)
        #expect(copy.title == "Use Right-\u{2325} for Voice Commands?")
        #expect(copy.message == "Polish and Email use this shortcut. After the move, pressing Right-\u{2325} runs voice commands instead of typing your speech. Email will have no shortcut.")
        #expect(copy.done == "Moved Right-\u{2325} to Voice Commands from Polish and Email.")
    }

    @Test func movingAwayFromVoiceCommandsSaysThePressWillDictate() throws {
        let move = try #require(VoiceCommandTriggers.move(mode("Polish", "f12"), in: [commands("f12", "right_option")]))
        #expect(ShortcutMoveCopy(move, notice: nil).message
                == "Voice Commands uses this shortcut. After the move, pressing F12 types your speech with Polish instead of running voice commands.")
    }

    @Test func anOverlappingKeyIsNamedWhenItIsNotTheOneRecorded() throws {
        let move = try #require(VoiceCommandTriggers.move(commands("command"), in: [mode("Notes", "left_command", "f12")]))
        #expect(ShortcutMoveCopy(move, notice: nil).message
                == "Notes uses this shortcut. After the move, pressing \u{2318} runs voice commands instead of typing your speech. Notes gives up Left-\u{2318}.")
    }

    @Test func theFirstUseNoticeIsFoldedIn() throws {
        let move = try #require(VoiceCommandTriggers.move(commands("f12"), in: [mode("Polish", "f12", "f11")]))
        #expect(ShortcutMoveCopy(move, notice: "Read this.").message.hasSuffix("instead of typing your speech.\n\nRead this."))
    }
}
