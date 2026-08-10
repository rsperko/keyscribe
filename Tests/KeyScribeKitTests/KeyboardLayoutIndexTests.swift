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
