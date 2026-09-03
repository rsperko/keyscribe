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
        #expect(stroke.keyCode(in: .ansiUS) == 9)
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

    @Test func theChordResolvesThroughTheActiveLayout() {
        let dvorakish = KeyboardLayoutIndex { keyCode, modifiers in
            guard modifiers.isEmpty else { return nil }
            return keyCode == 46 ? "v" : nil
        }
        #expect(ClipboardKeystroke.paste.keyCode(in: .ansiUS) == 9)
        #expect(ClipboardKeystroke.paste.keyCode(in: dvorakish) == 46)
    }

    @Test func aLayoutWithoutTheCharacterDoesNotResolve() {
        let cyrillicOnly = KeyboardLayoutIndex { keyCode, _ in
            switch keyCode {
            case 9: return "м"
            case 8: return "с"
            case 46: return "ь"
            default: return nil
            }
        }
        #expect(ClipboardKeystroke.paste.keyCode(in: cyrillicOnly) == nil)
        #expect(ClipboardKeystroke.copy.keyCode(in: cyrillicOnly) == nil)
    }

    @Test func aChordAbsentFromTheLayoutDoesNotResolve() throws {
        #expect(try ClipboardKeystroke(parsing: "control+é").keyCode(in: .ansiUS) == nil)
    }

    @Test func pasteAndCopyResolveOnANonLatinLayout() {
        let russianish = KeyboardLayoutIndex { keyCode, modifiers in
            switch (keyCode, modifiers) {
            case (9, []): return "м"
            case (9, [.command]): return "v"
            case (8, []): return "с"
            case (8, [.command]): return "c"
            default: return nil
            }
        }
        #expect(ClipboardKeystroke.paste.keyCode(in: russianish) == 9)
        #expect(ClipboardKeystroke.copy.keyCode(in: russianish) == 8)
    }

    @Test func aSpecialKeyChordResolvesWithoutTheLayout() throws {
        #expect(try ClipboardKeystroke(parsing: "shift+forward_delete").keyCode(in: .ansiUS) == 117)
    }
}
