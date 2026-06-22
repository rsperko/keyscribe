import Testing
@testable import KeyScribeKit

struct KeyDescriptorTests {
    @Test func parsesNamedTriggers() throws {
        #expect(try KeyDescriptor(parsing: "fn") == .named(.fn))
        #expect(try KeyDescriptor(parsing: "globe") == .named(.fn))
        #expect(try KeyDescriptor(parsing: "hyper") == .named(.hyper))
        #expect(try KeyDescriptor(parsing: "right_option") == .named(.rightOption))
        #expect(try KeyDescriptor(parsing: "right_command") == .named(.rightCommand))
    }

    @Test func parsesChords() throws {
        let d = try KeyDescriptor(parsing: "control+option+a")
        #expect(d == .chord(modifiers: [.control, .option], key: .letter("a")))
    }

    @Test func chordTokenOrderIsIrrelevant() throws {
        #expect(try KeyDescriptor(parsing: "option+control+a")
            == KeyDescriptor(parsing: "control+option+a"))
    }

    @Test func functionKeyAloneIsValid() throws {
        #expect(try KeyDescriptor(parsing: "f5") == .chord(modifiers: [], key: .function(5)))
    }

    @Test func bareLetterIsRejected() {
        #expect(throws: TriggerKeyError.bareNonFunctionKey) {
            try KeyDescriptor(parsing: "a")
        }
    }

    @Test func emptyIsRejected() {
        #expect(throws: TriggerKeyError.empty) { try KeyDescriptor(parsing: "  ") }
    }

    @Test func unknownTokenIsRejected() {
        #expect(throws: TriggerKeyError.unknownToken("squirtle")) {
            try KeyDescriptor(parsing: "control+squirtle")
        }
    }

    @Test func modifierOnlyChordIsRejected() {
        #expect(throws: TriggerKeyError.noBaseKey) {
            try KeyDescriptor(parsing: "control+option")
        }
    }

    @Test func canonicalRoundTrips() throws {
        for s in ["fn", "hyper", "right_option", "right_command", "control+option+a", "f5"] {
            #expect(try KeyDescriptor(parsing: s).canonical == s)
        }
    }

    @Test func canonicalNormalizesModifierOrder() throws {
        #expect(try KeyDescriptor(parsing: "command+shift+option+control+k").canonical
            == "control+option+shift+command+k")
    }

    @Test func namedKeyCodesMatchSpikeFindings() {
        #expect(KeyDescriptor.named(.fn).triggerKeyCode == 63)
        #expect(KeyDescriptor.named(.rightOption).triggerKeyCode == 61)
        #expect(KeyDescriptor.named(.rightCommand).triggerKeyCode == 54)
    }

    @Test func chordKeyCodeResolves() throws {
        #expect(try KeyDescriptor(parsing: "control+option+a").triggerKeyCode == 0)
        #expect(try KeyDescriptor(parsing: "f5").triggerKeyCode == 96)
    }

    @Test func hyperExpandsToFourModifiers() {
        #expect(KeyDescriptor.named(.hyper).requiredModifiers == [.control, .option, .shift, .command])
    }

    @Test func buildsChordFromCapturedEvent() {
        #expect(KeyDescriptor(eventKeyCode: 0, modifiers: [.control, .option])
            == .chord(modifiers: [.control, .option], key: .letter("a")))
        #expect(KeyDescriptor(eventKeyCode: 96, modifiers: [])
            == .chord(modifiers: [], key: .function(5)))
    }

    @Test func capturedBareNonFunctionKeyIsRejected() {
        #expect(KeyDescriptor(eventKeyCode: 0, modifiers: []) == nil)
    }

    @Test func capturedUnknownKeyCodeIsRejected() {
        #expect(KeyDescriptor(eventKeyCode: 999, modifiers: [.command]) == nil)
    }

    @Test func displayStringUsesGlyphs() throws {
        #expect(try KeyDescriptor(parsing: "control+option+shift+command+k").displayString == "⌃⌥⇧⌘K")
        #expect(try KeyDescriptor(parsing: "f5").displayString == "F5")
        #expect(KeyDescriptor.named(.fn).displayString == "Fn (Globe)")
        #expect(KeyDescriptor.named(.rightOption).displayString == "Right ⌥")
    }

    @Test func collidesWhenSamePhysicalEvent() throws {
        let a = try KeyDescriptor(parsing: "option+control+a")
        let b = try KeyDescriptor(parsing: "control+option+a")
        #expect(a.collides(with: b))
        #expect(try !a.collides(with: KeyDescriptor(parsing: "control+option+b")))
        #expect(!KeyDescriptor.named(.fn).collides(with: .named(.rightOption)))
    }
}
