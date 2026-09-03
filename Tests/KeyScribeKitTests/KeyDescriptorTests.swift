import Testing
@testable import KeyScribeKit

struct KeyDescriptorTests {
    @Test func parsesNamedTriggers() throws {
        #expect(try KeyDescriptor(parsing: "fn") == .named(.fn))
        #expect(try KeyDescriptor(parsing: "globe") == .named(.fn))
        #expect(try KeyDescriptor(parsing: "hyper") == .named(.hyper))
        #expect(try KeyDescriptor(parsing: "right_option") == .named(.rightOption))
        #expect(try KeyDescriptor(parsing: "right_command") == .named(.rightCommand))
        #expect(try KeyDescriptor(parsing: "right_control") == .named(.rightControl))
    }

    @Test func keycapTokensForNamedKeys() {
        #expect(KeyDescriptor.named(.fn).keycapTokens == ["fn"])
        #expect(KeyDescriptor.named(.hyper).keycapTokens == ["⌃", "⌥", "⇧", "⌘"])
        #expect(KeyDescriptor.named(.rightOption).keycapTokens == ["right ⌥"])
        #expect(KeyDescriptor.named(.rightCommand).keycapTokens == ["right ⌘"])
        #expect(KeyDescriptor.named(.rightControl).keycapTokens == ["right ⌃"])
    }

    @Test func rightControlDescriptorProperties() {
        #expect(KeyDescriptor.named(.rightControl).displayString == "Right-⌃")
        #expect(NamedKey.rightControl.keyCode == 62)
        #expect(KeyDescriptor.named(.rightControl).requiredModifiers == [.control])
        #expect(KeyDescriptor.named(.rightControl).isModifierOnly)
        #expect(KeyDescriptor.named(.rightControl).canonical == "right_control")
    }

    @Test func keycapTokensForChordsAreModifiersThenKeyInCanonicalOrder() {
        #expect(KeyDescriptor.chord(modifiers: [.command], key: .character("k")).keycapTokens == ["⌘", "K"])
        // canonical ⌃⌥⇧⌘ order regardless of set iteration order
        // Set iteration order is unspecified; tokens must still come out in canonical ⌃⌥⇧⌘ order.
        #expect(KeyDescriptor.chord(modifiers: [.command, .shift, .control, .option], key: .character("e")).keycapTokens
            == ["⌃", "⌥", "⇧", "⌘", "E"])
        #expect(KeyDescriptor.chord(modifiers: [], key: .key(.f5)).keycapTokens == ["F5"])
    }

    @Test func keycapTokensForMouseButtonAreEmpty() {
        #expect(KeyDescriptor.mouseButton(4).keycapTokens.isEmpty)
    }

    @Test func parsesChords() throws {
        let d = try KeyDescriptor(parsing: "control+option+a")
        #expect(d == .chord(modifiers: [.control, .option], key: .character("a")))
    }

    @Test func chordTokenOrderIsIrrelevant() throws {
        #expect(try KeyDescriptor(parsing: "option+control+a")
            == KeyDescriptor(parsing: "control+option+a"))
    }

    @Test func functionKeyAloneIsValid() throws {
        #expect(try KeyDescriptor(parsing: "f5") == .chord(modifiers: [], key: .key(.f5)))
    }

    @Test func bareLetterIsRejected() {
        #expect(throws: TriggerKeyError.bareNonFunctionKey) {
            try KeyDescriptor(parsing: "a")
        }
    }

    @Test(arguments: ["space", "left", "return", "escape", "keypad_5"])
    func bareSpecialKeyIsRejected(_ token: String) {
        #expect(throws: TriggerKeyError.bareNonFunctionKey) { try KeyDescriptor(parsing: token) }
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

    @Test func nonAsciiCharacterKeysAreAccepted() throws {
        #expect(try KeyDescriptor(parsing: "control+é") == .chord(modifiers: [.control], key: .character("é")))
        #expect(try KeyDescriptor(parsing: "control+ß") == .chord(modifiers: [.control], key: .character("ß")))
        #expect(try KeyDescriptor(parsing: "control+٣") == .chord(modifiers: [.control], key: .character("٣")))
    }

    @Test func punctuationKeysAreAccepted() throws {
        #expect(try KeyDescriptor(parsing: "control+`") == .chord(modifiers: [.control], key: .character("`")))
        #expect(try KeyDescriptor(parsing: "command+[") == .chord(modifiers: [.command], key: .character("[")))
        #expect(try KeyDescriptor(parsing: "control+option+/") == .chord(modifiers: [.control, .option], key: .character("/")))
    }

    // `plus` is the one spelling the grammar cannot do without: parsing splits on "+", so the character
    // can only be named, and it must canonicalize back to the word rather than to a "+" that re-splits.
    @Test func plusIsWrittenAsAWordAndRoundTrips() throws {
        let descriptor = try KeyDescriptor(parsing: "control+plus")
        #expect(descriptor == .chord(modifiers: [.control], key: .character("+")))
        #expect(descriptor.canonical == "control+plus")
        #expect(try KeyDescriptor(parsing: descriptor.canonical) == descriptor)
    }

    @Test func aRawPlusCharacterCannotBeParsed() {
        #expect(throws: TriggerKeyError.empty) { try KeyDescriptor(parsing: "control++") }
    }

    @Test func specialKeysParseByName() throws {
        #expect(try KeyDescriptor(parsing: "control+space") == .chord(modifiers: [.control], key: .key(.space)))
        #expect(try KeyDescriptor(parsing: "command+up") == .chord(modifiers: [.command], key: .key(.up)))
        #expect(try KeyDescriptor(parsing: "option+forward_delete")
            == .chord(modifiers: [.option], key: .key(.forwardDelete)))
        #expect(try KeyDescriptor(parsing: "control+keypad_enter")
            == .chord(modifiers: [.control], key: .key(.keypadEnter)))
    }

    @Test func letterKeysCanonicalizeLowercase() throws {
        #expect(try KeyDescriptor(parsing: "control+A").canonical == "control+a")
    }

    @Test func canonicalRoundTrips() throws {
        for s in ["fn", "hyper", "right_option", "right_command", "control+option+a", "f5",
                  "control+`", "command+[", "control+space", "command+up", "control+keypad_0",
                  "option+f13", "control+option+é"] {
            #expect(try KeyDescriptor(parsing: s).canonical == s)
        }
    }

    @Test func canonicalNormalizesModifierOrder() throws {
        #expect(try KeyDescriptor(parsing: "command+shift+option+control+k").canonical
            == "control+option+shift+command+k")
    }

    @Test func namedKeyCodesMatchSpikeFindings() {
        #expect(NamedKey.fn.keyCode == 63)
        #expect(NamedKey.rightOption.keyCode == 61)
        #expect(NamedKey.rightCommand.keyCode == 54)
    }

    @Test func characterChordResolvesThroughTheLayout() throws {
        #expect(try KeyDescriptor(parsing: "control+option+a").chordKeyCode(in: .ansiUS) == 0)
        #expect(try KeyDescriptor(parsing: "control+`").chordKeyCode(in: .ansiUS) == 50)
        #expect(try KeyDescriptor(parsing: "command+[").chordKeyCode(in: .ansiUS) == 33)
        #expect(try KeyDescriptor(parsing: "control+7").chordKeyCode(in: .ansiUS) == 26)
    }

    @Test func characterChordAbsentFromTheLayoutDoesNotResolve() throws {
        #expect(try KeyDescriptor(parsing: "control+é").chordKeyCode(in: .ansiUS) == nil)
    }

    @Test func aChordOnANonLatinLayoutResolvesThroughTheCommandLayer() throws {
        let russianish = KeyboardLayoutIndex { keyCode, modifiers in
            switch (keyCode, modifiers) {
            case (9, []): return "м"
            case (9, [.command]): return "v"
            case (14, []): return "у"
            case (14, [.command]): return "e"
            default: return nil
            }
        }
        #expect(try KeyDescriptor(parsing: "command+v").chordKeyCode(in: russianish) == 9)
        #expect(try KeyDescriptor(parsing: "control+option+e").chordKeyCode(in: russianish) == 14)
    }

    @Test func aCharacterReachableOnlyWithShiftDoesNotResolve() {
        let layout = KeyboardLayoutIndex { keyCode, modifiers in
            switch (keyCode, modifiers) {
            case (50, []): return "`"
            case (50, [.shift]): return "~"
            default: return nil
            }
        }
        #expect(KeyDescriptor.chord(modifiers: [.control], key: .character("`")).chordKeyCode(in: layout) == 50)
        #expect(KeyDescriptor.chord(modifiers: [.control], key: .character("~")).chordKeyCode(in: layout) == nil)
    }

    @Test func specialKeyChordResolvesWithoutTheLayout() throws {
        let empty = KeyboardLayoutIndex { _, _ in nil }
        #expect(try KeyDescriptor(parsing: "f5").chordKeyCode(in: empty) == 96)
        #expect(try KeyDescriptor(parsing: "control+space").chordKeyCode(in: empty) == 49)
        #expect(try KeyDescriptor(parsing: "command+up").chordKeyCode(in: empty) == 126)
        #expect(try KeyDescriptor(parsing: "control+keypad_plus").chordKeyCode(in: empty) == 69)
    }

    @Test func theSameCharacterResolvesToDifferentPositionsOnDifferentLayouts() {
        let swapped = KeyboardLayoutIndex { keyCode, modifiers in
            guard modifiers.isEmpty else { return nil }
            return keyCode == 10 ? "`" : nil
        }
        let chord = KeyDescriptor.chord(modifiers: [.control], key: .character("`"))
        #expect(chord.chordKeyCode(in: .ansiUS) == 50)
        #expect(chord.chordKeyCode(in: swapped) == 10)
    }

    @Test func nonChordsHaveNoChordKeyCode() {
        #expect(KeyDescriptor.named(.fn).chordKeyCode(in: .ansiUS) == nil)
        #expect(KeyDescriptor.mouseButton(3).chordKeyCode(in: .ansiUS) == nil)
    }

    @Test func hyperExpandsToFourModifiers() {
        #expect(KeyDescriptor.named(.hyper).requiredModifiers == [.control, .option, .shift, .command])
    }

    @Test func buildsChordFromCapturedEvent() {
        #expect(KeyDescriptor(eventKeyCode: 0, shortcutCharacter: "a", modifiers: [.control, .option])
            == .chord(modifiers: [.control, .option], key: .character("a")))
        #expect(KeyDescriptor(eventKeyCode: 96, shortcutCharacter: nil, modifiers: [])
            == .chord(modifiers: [], key: .key(.f5)))
        #expect(KeyDescriptor(eventKeyCode: 50, shortcutCharacter: "`", modifiers: [.control])
            == .chord(modifiers: [.control], key: .character("`")))
    }

    @Test func capturedSpecialKeyWinsOverItsCharacter() {
        #expect(KeyDescriptor(eventKeyCode: 49, shortcutCharacter: " ", modifiers: [.control])
            == .chord(modifiers: [.control], key: .key(.space)))
        #expect(KeyDescriptor(eventKeyCode: 36, shortcutCharacter: "\r", modifiers: [.command])
            == .chord(modifiers: [.command], key: .key(.return)))
    }

    @Test func capturedShiftedKeyStoresTheUnshiftedCharacter() {
        #expect(KeyDescriptor(eventKeyCode: 50, shortcutCharacter: "`", modifiers: [.control, .shift])
            == .chord(modifiers: [.control, .shift], key: .character("`")))
    }

    @Test func capturedLetterIsStoredLowercase() {
        #expect(KeyDescriptor(eventKeyCode: 0, shortcutCharacter: "A", modifiers: [.command])
            == .chord(modifiers: [.command], key: .character("a")))
    }

    @Test func capturedBareNonFunctionKeyIsRejected() {
        #expect(KeyDescriptor(eventKeyCode: 0, shortcutCharacter: "a", modifiers: []) == nil)
        #expect(KeyDescriptor(eventKeyCode: 49, shortcutCharacter: " ", modifiers: []) == nil)
    }

    @Test func capturedUnknownKeyCodeIsRejected() {
        #expect(KeyDescriptor(eventKeyCode: 999, shortcutCharacter: nil, modifiers: [.command]) == nil)
    }

    @Test func displayStringUsesGlyphs() throws {
        #expect(try KeyDescriptor(parsing: "control+option+shift+command+k").displayString == "⌃⌥⇧⌘K")
        #expect(try KeyDescriptor(parsing: "f5").displayString == "F5")
        #expect(try KeyDescriptor(parsing: "control+`").displayString == "⌃`")
        #expect(try KeyDescriptor(parsing: "control+space").displayString == "⌃␣")
        #expect(try KeyDescriptor(parsing: "command+up").displayString == "⌘↑")
        #expect(try KeyDescriptor(parsing: "control+keypad_0").displayString == "⌃Keypad 0")
        #expect(KeyDescriptor.named(.fn).displayString == "Fn (Globe)")
        #expect(KeyDescriptor.named(.rightOption).displayString == "Right-⌥")
        #expect(KeyDescriptor.named(.rightCommand).displayString == "Right-⌘")
        #expect(KeyDescriptor.named(.hyper).displayString == "⌃⌥⇧⌘")
    }

    @Test func collidesWhenSamePhysicalEvent() throws {
        let a = try KeyDescriptor(parsing: "option+control+a")
        let b = try KeyDescriptor(parsing: "control+option+a")
        #expect(a.collides(with: b))
        #expect(try !a.collides(with: KeyDescriptor(parsing: "control+option+b")))
        #expect(!KeyDescriptor.named(.fn).collides(with: .named(.rightOption)))
        #expect(KeyDescriptor.named(.fn).collides(with: .named(.fn)))
    }

    @Test func aCharacterNeverCollidesWithASpecialKey() throws {
        #expect(try !KeyDescriptor(parsing: "control+5").collides(with: KeyDescriptor(parsing: "control+keypad_5")))
    }

    @Test func parsesMouseButtons() throws {
        #expect(try KeyDescriptor(parsing: "mouse2") == .mouseButton(2))
        #expect(try KeyDescriptor(parsing: "mouse3") == .mouseButton(3))
        #expect(try KeyDescriptor(parsing: "mouse4") == .mouseButton(4))
    }

    @Test func primaryMouseButtonsAreRejected() {
        #expect(throws: TriggerKeyError.unknownToken("mouse0")) { try KeyDescriptor(parsing: "mouse0") }
        #expect(throws: TriggerKeyError.unknownToken("mouse1")) { try KeyDescriptor(parsing: "mouse1") }
    }

    @Test func mouseButtonCanonicalRoundTrips() throws {
        for s in ["mouse2", "mouse3", "mouse4", "mouse10"] {
            #expect(try KeyDescriptor(parsing: s).canonical == s)
        }
    }

    @Test func mouseButtonDisplayString() throws {
        #expect(try KeyDescriptor(parsing: "mouse3").displayString == "Mouse Button 3")
    }

    @Test func mouseButtonHasNoModifiers() throws {
        #expect(try KeyDescriptor(parsing: "mouse4").requiredModifiers.isEmpty)
        #expect(try KeyDescriptor(parsing: "mouse4").requiredModifierMask.isEmpty)
    }

    @Test func buildsMouseButtonFromCapturedEvent() {
        #expect(KeyDescriptor(eventButtonNumber: 3) == .mouseButton(3))
        #expect(KeyDescriptor(eventButtonNumber: 1) == nil)
        #expect(KeyDescriptor(eventButtonNumber: 0) == nil)
    }

    @Test func mouseButtonsCollideOnlyWithSameButton() throws {
        let m3 = try KeyDescriptor(parsing: "mouse3")
        #expect(try m3.collides(with: KeyDescriptor(parsing: "mouse3")))
        #expect(try !m3.collides(with: KeyDescriptor(parsing: "mouse4")))
        #expect(!m3.collides(with: .named(.fn)))
        #expect(try !m3.collides(with: KeyDescriptor(parsing: "control+option+c")))
    }
}

struct SpecialKeyTests {
    @Test func everyKeyCodeIsUnique() {
        let codes = SpecialKey.allCases.map(\.keyCode)
        #expect(Set(codes).count == codes.count)
    }

    @Test func everyTokenRoundTripsThroughItsKeyCode() {
        for key in SpecialKey.allCases {
            #expect(SpecialKey(keyCode: key.keyCode) == key)
            #expect(SpecialKey(rawValue: key.rawValue) == key)
        }
    }

    @Test func onlyFunctionKeysAreBareable() {
        #expect(SpecialKey.f1.isFunctionKey)
        #expect(SpecialKey.f20.isFunctionKey)
        #expect(!SpecialKey.space.isFunctionKey)
        #expect(!SpecialKey.up.isFunctionKey)
        #expect(!SpecialKey.keypadEnter.isFunctionKey)
    }
}
