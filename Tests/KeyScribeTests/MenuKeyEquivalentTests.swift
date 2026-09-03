import AppKit
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct MenuKeyEquivalentTests {
    private func equivalent(_ key: String) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        try! KeyDescriptor(parsing: key).menuItemKeyEquivalent
    }

    @Test func aCharacterChordUsesTheLowercasedCharacter() throws {
        let paste = try #require(equivalent("control+option+shift+V"))
        #expect(paste.key == "v")
        #expect(paste.modifiers == [.control, .option, .shift])

        let grave = try #require(equivalent("control+`"))
        #expect(grave.key == "`")
        #expect(grave.modifiers == [.control])
    }

    @Test(arguments: [
        ("option+f1", NSF1FunctionKey), ("option+f5", NSF5FunctionKey),
        ("option+f13", NSF13FunctionKey), ("option+f20", NSF20FunctionKey),
        ("control+up", NSUpArrowFunctionKey), ("control+left", NSLeftArrowFunctionKey),
        ("control+home", NSHomeFunctionKey), ("control+page_down", NSPageDownFunctionKey),
    ])
    func functionAndNavigationKeysUseTheirAppKitScalar(_ key: String, _ scalar: Int) throws {
        let resolved = try #require(equivalent(key))
        #expect(resolved.key == String(Character(Unicode.Scalar(scalar)!)))
    }

    @Test(arguments: [
        ("control+space", " "), ("control+tab", "\t"), ("control+return", "\r"),
        ("control+delete", "\u{8}"), ("control+forward_delete", "\u{7f}"), ("control+escape", "\u{1b}"),
    ])
    func editingKeysUseTheirControlCharacter(_ key: String, _ expected: String) throws {
        #expect(try #require(equivalent(key)).key == expected)
    }

    // ⌤ shares Return's equivalent, so only the numeric-pad flag distinguishes it in a menu.
    @Test func theKeypadIsFlaggedAsNumericPad() throws {
        let keypad5 = try #require(equivalent("control+keypad_5"))
        #expect(keypad5.key == "5")
        #expect(keypad5.modifiers == [.control, .numericPad])

        let enter = try #require(equivalent("control+keypad_enter"))
        #expect(enter.key == "\r")
        #expect(enter.modifiers.contains(.numericPad))

        let mainRow = try #require(equivalent("control+5"))
        #expect(mainRow.key == "5")
        #expect(!mainRow.modifiers.contains(.numericPad))
    }

    @Test func keypadClearHasNoEquivalent() {
        #expect(equivalent("control+keypad_clear") == nil)
    }

    @Test func nonChordDescriptorsHaveNoEquivalent() {
        #expect(KeyDescriptor.named(.fn).menuItemKeyEquivalent == nil)
        #expect(KeyDescriptor.mouseButton(3).menuItemKeyEquivalent == nil)
    }
}
