import Testing
@testable import KeyScribeKit

struct KeyboardLayoutIndexTests {
    private static func miniLayout(_ keyCode: Int, _ modifiers: Set<Modifier>) -> String? {
        switch (keyCode, modifiers) {
        case (0, []): return "a"
        case (0, [.shift]): return "A"
        case (0, [.option]): return "å"
        case (1, []): return "s"
        case (1, [.shift]): return "S"
        case (5, []): return "xy"
        case (18, []): return "1"
        case (18, [.shift]): return "!"
        case (18, [.option]): return "¡"
        case (36, []): return "\r"
        case (48, []): return "\t"
        case (49, []): return " "
        case (51, []): return "\u{8}"
        case (53, []): return "\u{1B}"
        case (99, [.shift]): return "a"
        default: return nil
        }
    }

    private let index = KeyboardLayoutIndex(produce: miniLayout)

    @Test func plainCharactersMapToUnmodifiedKeys() {
        #expect(index.stroke(for: "a") == LayoutKeystroke(keyCode: 0))
        #expect(index.stroke(for: "s") == LayoutKeystroke(keyCode: 1))
        #expect(index.stroke(for: "1") == LayoutKeystroke(keyCode: 18))
        #expect(index.stroke(for: " ") == LayoutKeystroke(keyCode: 49))
    }

    @Test func shiftedCharactersCarryShift() {
        #expect(index.stroke(for: "A") == LayoutKeystroke(keyCode: 0, modifiers: [.shift]))
        #expect(index.stroke(for: "!") == LayoutKeystroke(keyCode: 18, modifiers: [.shift]))
    }

    @Test func optionCharactersCarryOption() {
        #expect(index.stroke(for: "å") == LayoutKeystroke(keyCode: 0, modifiers: [.option]))
        #expect(index.stroke(for: "¡") == LayoutKeystroke(keyCode: 18, modifiers: [.option]))
    }

    @Test func anUnmodifiedKeyWinsOverAShiftedDuplicate() {
        #expect(index.stroke(for: "a") == LayoutKeystroke(keyCode: 0))
    }

    @Test func newlineFallsBackToTheReturnKey() {
        #expect(index.stroke(for: "\n") == LayoutKeystroke(keyCode: 36))
        #expect(index.stroke(for: "\r") == LayoutKeystroke(keyCode: 36))
    }

    @Test func tabIsTypeable() {
        #expect(index.stroke(for: "\t") == LayoutKeystroke(keyCode: 48))
    }

    @Test func controlCharactersAreNeverTypeable() {
        #expect(index.stroke(for: "\u{8}") == nil)
        #expect(index.stroke(for: "\u{1B}") == nil)
    }

    @Test func charactersOffTheLayoutAreNil() {
        #expect(index.stroke(for: "é") == nil)
        #expect(index.stroke(for: "🎤") == nil)
    }

    @Test func aMultiCharacterProductionIsIgnored() {
        #expect(index.stroke(for: "x") == nil)
        #expect(index.stroke(for: "y") == nil)
    }
}

struct AnsiUSLayoutTests {
    @Test func lettersAndDigitsSitAtTheirAnsiPositions() {
        #expect(KeyboardLayoutIndex.ansiUS.stroke(for: "a") == LayoutKeystroke(keyCode: 0))
        #expect(KeyboardLayoutIndex.ansiUS.stroke(for: "v") == LayoutKeystroke(keyCode: 9))
        #expect(KeyboardLayoutIndex.ansiUS.stroke(for: "z") == LayoutKeystroke(keyCode: 6))
        #expect(KeyboardLayoutIndex.ansiUS.stroke(for: "0") == LayoutKeystroke(keyCode: 29))
        #expect(KeyboardLayoutIndex.ansiUS.stroke(for: "7") == LayoutKeystroke(keyCode: 26))
    }

    @Test(arguments: [
        ("`", 50), ("-", 27), ("=", 24), ("[", 33), ("]", 30), ("\\", 42),
        (";", 41), ("'", 39), (",", 43), (".", 47), ("/", 44), ("\u{a7}", 10),
    ])
    func punctuationSitsAtItsAnsiPosition(_ character: String, _ keyCode: Int) {
        #expect(KeyboardLayoutIndex.ansiUS.stroke(for: Character(character)) == LayoutKeystroke(keyCode: keyCode))
    }

    @Test func shiftedAndOffLayoutCharactersAreAbsent() {
        #expect(KeyboardLayoutIndex.ansiUS.stroke(for: "A") == nil)
        #expect(KeyboardLayoutIndex.ansiUS.stroke(for: "~") == nil)
        #expect(KeyboardLayoutIndex.ansiUS.stroke(for: "é") == nil)
    }

    @Test func everyPositionIsClaimedByOneCharacter() {
        let all = "abcdefghijklmnopqrstuvwxyz0123456789`-=[]\\;',./\u{a7}"
        let codes = all.compactMap { KeyboardLayoutIndex.ansiUS.stroke(for: $0)?.keyCode }
        #expect(codes.count == all.count)
        #expect(Set(codes).count == codes.count)
    }
}

struct ShortcutIdentityTests {
    private let russianish = KeyboardLayoutIndex { keyCode, modifiers in
        switch (keyCode, modifiers) {
        case (9, []): return "м"
        case (9, [.command]): return "v"
        case (8, []): return "с"
        case (8, [.command]): return "c"
        case (50, []): return "]"
        case (50, [.command]): return "`"
        default: return nil
        }
    }

    @Test func aLatinShortcutResolvesThroughTheCommandLayer() {
        #expect(russianish.shortcutKeyCode(for: "v") == 9)
        #expect(russianish.shortcutKeyCode(for: "c") == 8)
        #expect(russianish.shortcutKeyCode(for: "`") == 50)
    }

    @Test func theCommandLayerCharacterIsNotReachableUnmodified() {
        #expect(russianish.stroke(for: "v") == nil)
    }

    @Test func theTypingIndexNeverSeesACommandOnlyProduction() {
        #expect(russianish.stroke(for: "v") == nil)
        #expect(russianish.stroke(for: "c") == nil)
        #expect(russianish.stroke(for: "м") == LayoutKeystroke(keyCode: 9))
    }

    @Test func theCommandLayerAlsoNamesThePosition() {
        #expect(russianish.shortcutCharacter(forKeyCode: 9) == "v")
        #expect(russianish.shortcutCharacter(forKeyCode: 50) == "`")
        #expect(russianish.shortcutCharacter(forKeyCode: 99) == nil)
    }

    @Test func shortcutsAndTypingCanDisagreeOnTheSameLayout() {
        let dvorakQwertyCmd = KeyboardLayoutIndex { keyCode, modifiers in
            switch (keyCode, modifiers) {
            case (9, []): return "k"
            case (9, [.command]): return "v"
            case (47, []): return "v"
            case (47, [.command]): return "."
            default: return nil
            }
        }
        #expect(dvorakQwertyCmd.shortcutKeyCode(for: "v") == 9)
        #expect(dvorakQwertyCmd.stroke(for: "v") == LayoutKeystroke(keyCode: 47))
    }

    @Test func aLayoutWithoutACommandLayerFallsBackToTheUnmodifiedKey() {
        #expect(KeyboardLayoutIndex.ansiUS.shortcutKeyCode(for: "a") == 0)
        #expect(KeyboardLayoutIndex.ansiUS.shortcutKeyCode(for: "`") == 50)
        #expect(KeyboardLayoutIndex.ansiUS.shortcutCharacter(forKeyCode: 9) == "v")
    }

    @Test func aShiftedCharacterIsNeverAShortcutIdentity() {
        let us = KeyboardLayoutIndex { keyCode, modifiers in
            switch (keyCode, modifiers) {
            case (50, []): return "`"
            case (50, [.shift]): return "~"
            default: return nil
            }
        }
        #expect(us.shortcutKeyCode(for: "`") == 50)
        #expect(us.shortcutKeyCode(for: "~") == nil)
    }

    @Test func whitespaceAndControlProductionsAreExcluded() {
        let index = KeyboardLayoutIndex { keyCode, modifiers in
            guard modifiers.isEmpty else { return nil }
            switch keyCode {
            case 49: return " "
            case 36: return "\r"
            case 48: return "\t"
            default: return nil
            }
        }
        #expect(index.shortcutKeyCode(for: " ") == nil)
        #expect(index.shortcutCharacter(forKeyCode: 49) == nil)
        #expect(index.shortcutCharacter(forKeyCode: 36) == nil)
    }

    @Test func theKeypadNeverClaimsACharactersShortcutIdentity() {
        let azerty = KeyboardLayoutIndex { keyCode, modifiers in
            switch (keyCode, modifiers) {
            case (23, []), (23, [.command]): return "("
            case (23, [.shift]): return "5"
            case (87, []), (87, [.command]): return "5"
            default: return nil
            }
        }
        #expect(azerty.shortcutKeyCode(for: "5") == nil)
        #expect(azerty.shortcutCharacter(forKeyCode: 87) == nil)
        #expect(azerty.shortcutKeyCode(for: "(") == 23)
    }

    @Test func theTypingIndexStillReachesReturnAndTab() {
        let index = KeyboardLayoutIndex { keyCode, modifiers in
            guard modifiers.isEmpty else { return nil }
            return [36: "\r", 48: "\t"][keyCode]
        }
        #expect(index.stroke(for: "\n") == LayoutKeystroke(keyCode: 36))
        #expect(index.stroke(for: "\t") == LayoutKeystroke(keyCode: 48))
    }
}
