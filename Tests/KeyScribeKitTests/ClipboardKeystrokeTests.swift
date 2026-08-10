import Testing
@testable import KeyScribeKit

struct ClipboardKeystrokeTests {
    @Test func defaultsAreTheNativeMacOSClipboardChords() {
        #expect(ClipboardKeystroke.paste.canonical == "command+v")
        #expect(ClipboardKeystroke.copy.canonical == "command+c")
        #expect(ClipboardKeystroke.paste.modifiers == [.command])
    }

    @Test func parsesTheTriggerKeyGrammar() throws {
        let stroke = try ClipboardKeystroke(parsing: "control+shift+v")
        #expect(stroke.modifiers == [.control, .shift])
        #expect(stroke.keyCode == 9)
        #expect(stroke.canonical == "control+shift+v")
    }

    @Test func acceptsTheGrammarsAliasesAndSpacing() throws {
        #expect(try ClipboardKeystroke(parsing: "cmd+v") == .paste)
        #expect(try ClipboardKeystroke(parsing: " CTRL + Y ").modifiers == [.control])
    }

    // ⌘ marks a chord the focused macOS app handles itself. A chord without it is aimed at a target that
    // forwards raw keystrokes — a VM guest, a remote session — which is what decides both how the chord is
    // posted and what the clipboard defaults to.
    @Test(arguments: [
        ("command+v", false),
        ("command+shift+v", false),
        ("control+v", true),
        ("control+shift+v", true),
        ("control+y", true),
    ])
    func onlyACommandChordIsHandledByTheFocusedApp(_ key: String, _ foreign: Bool) throws {
        #expect(try ClipboardKeystroke(parsing: key).isForeignTarget == foreign)
    }

    // The grammar also describes triggers, which have no clipboard meaning — a paste key must be a chord.
    @Test(arguments: ["fn", "hyper", "right_option", "mouse3"])
    func rejectsATriggerOnlyDescriptor(_ key: String) {
        #expect(throws: ClipboardKeystrokeError.notAChord(key)) { try ClipboardKeystroke(parsing: key) }
    }

    @Test(arguments: ["v", "cotnrol+v", "command+", ""])
    func rejectsAKeyTheGrammarCannotParse(_ key: String) {
        #expect(throws: (any Error).self) { try ClipboardKeystroke(parsing: key) }
    }
}
