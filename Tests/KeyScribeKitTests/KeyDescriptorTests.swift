import Testing
@testable import KeyScribeKit

struct KeyDescriptorTests {
    private func mods(_ members: SidedModifier...) -> KeyDescriptor {
        .modifiers(try! ModifierKeySet(Set(members)))
    }

    @Test func parsesModifierOnlyTriggers() throws {
        #expect(try KeyDescriptor(parsing: "fn") == mods(.init(.fn)))
        #expect(try KeyDescriptor(parsing: "globe") == mods(.init(.fn)))
        #expect(try KeyDescriptor(parsing: "right_option") == mods(.init(.option, .right)))
        #expect(try KeyDescriptor(parsing: "right_command") == mods(.init(.command, .right)))
        #expect(try KeyDescriptor(parsing: "right_control") == mods(.init(.control, .right)))
    }

    @Test func parsesSidedAndSidelessModifierSets() throws {
        #expect(try KeyDescriptor(parsing: "left_command") == mods(.init(.command, .left)))
        #expect(try KeyDescriptor(parsing: "left_command+left_control")
            == mods(.init(.command, .left), .init(.control, .left)))
        #expect(try KeyDescriptor(parsing: "command+control") == mods(.init(.command), .init(.control)))
        #expect(try KeyDescriptor(parsing: "fn+left_command") == mods(.init(.fn), .init(.command, .left)))
        #expect(try KeyDescriptor(parsing: "left_ctrl") == mods(.init(.control, .left)))
        #expect(try KeyDescriptor(parsing: "right_alt") == mods(.init(.option, .right)))
        #expect(try KeyDescriptor(parsing: "left_cmd") == mods(.init(.command, .left)))
    }

    @Test func hyperIsAParseAliasForTheFourModifierSet() throws {
        let hyper = try KeyDescriptor(parsing: "hyper")
        #expect(hyper == mods(.init(.control), .init(.option), .init(.shift), .init(.command)))
        #expect(hyper == (try KeyDescriptor(parsing: "control+option+shift+command")))
        #expect(hyper.canonical == "control+option+shift+command")
        #expect(hyper.collides(with: try KeyDescriptor(parsing: "shift+command+control+option")))
    }

    @Test func modifierSetTokenOrderIsIrrelevantAndCanonicalizes() throws {
        #expect(try KeyDescriptor(parsing: "left_control+left_command").canonical
            == "left_control+left_command")
        #expect(try KeyDescriptor(parsing: "left_command+left_control").canonical
            == "left_control+left_command")
        #expect(try KeyDescriptor(parsing: "left_command+fn").canonical == "left_command+fn")
    }

    @Test func modifierSetsCanonicalRoundTrip() throws {
        for s in ["fn", "right_option", "right_command", "right_control", "left_command",
                  "left_control+left_command", "control+option+shift+command", "left_command+fn"] {
            #expect(try KeyDescriptor(parsing: s).canonical == s)
        }
    }

    @Test func bothSidesOfOneModifierAreRejected() {
        #expect(throws: TriggerKeyError.duplicateModifier("command")) {
            try KeyDescriptor(parsing: "left_command+right_command")
        }
        #expect(throws: TriggerKeyError.duplicateModifier("command")) {
            try KeyDescriptor(parsing: "command+left_command")
        }
    }

    @Test func moreThanFourModifiersAreRejected() {
        #expect(throws: TriggerKeyError.tooManyModifiers) {
            try KeyDescriptor(parsing: "control+option+shift+command+fn")
        }
    }

    // A set dedupes these into something valid-looking, so they are caught per token instead: `hyper+control`
    // would silently BE Hyper, and `hyper+left_control` would blame the size rather than the clash.
    @Test func aModifierRepeatedAcrossTokensIsRejected() {
        #expect(throws: TriggerKeyError.duplicateModifier("control")) {
            try KeyDescriptor(parsing: "hyper+control")
        }
        #expect(throws: TriggerKeyError.duplicateModifier("control")) {
            try KeyDescriptor(parsing: "hyper+left_control")
        }
        #expect(throws: TriggerKeyError.duplicateModifier("command")) {
            try KeyDescriptor(parsing: "command+cmd")
        }
    }

    @Test func aSidedModifierInsideAChordIsRejected() {
        #expect(throws: TriggerKeyError.modifierNotAllowedInChord("left_command")) {
            try KeyDescriptor(parsing: "left_command+k")
        }
        #expect(throws: TriggerKeyError.modifierNotAllowedInChord("fn")) {
            try KeyDescriptor(parsing: "fn+k")
        }
        #expect(throws: TriggerKeyError.modifierNotAllowedInChord("hyper")) {
            try KeyDescriptor(parsing: "hyper+k")
        }
    }

    @Test func fnIsNeverSided() {
        #expect(throws: TriggerKeyError.unknownToken("left_fn")) { try KeyDescriptor(parsing: "left_fn") }
        #expect(throws: TriggerKeyError.unknownToken("right_globe")) { try KeyDescriptor(parsing: "right_globe") }
    }

    @Test func keycapTokensForModifierSets() throws {
        #expect(try KeyDescriptor(parsing: "fn").keycapTokens == ["fn"])
        #expect(try KeyDescriptor(parsing: "hyper").keycapTokens == ["⌃", "⌥", "⇧", "⌘"])
        #expect(try KeyDescriptor(parsing: "right_option").keycapTokens == ["right ⌥"])
        #expect(try KeyDescriptor(parsing: "right_command").keycapTokens == ["right ⌘"])
        #expect(try KeyDescriptor(parsing: "right_control").keycapTokens == ["right ⌃"])
        #expect(try KeyDescriptor(parsing: "left_command+left_control").keycapTokens == ["left ⌃", "left ⌘"])
        #expect(try KeyDescriptor(parsing: "fn+left_command").keycapTokens == ["left ⌘", "fn"])
    }

    @Test func rightControlDescriptorProperties() throws {
        let d = try KeyDescriptor(parsing: "right_control")
        #expect(d.displayString == "Right-⌃")
        #expect(ModifierKeyCodes.sidedModifier(forKeyCode: 62) == SidedModifier(.control, .right))
        #expect(d.requiredModifiers == [.control])
        #expect(d.carriesChordModifier)
        #expect(d.canonical == "right_control")
    }

    // An `fn`-only trigger keys off the Fn flag, which no chord carries, so nothing can shadow it.
    @Test func onlySetsCarryingAChordModifierCanBeShadowed() throws {
        #expect(try !KeyDescriptor(parsing: "fn").carriesChordModifier)
        #expect(try KeyDescriptor(parsing: "fn+left_command").carriesChordModifier)
        #expect(try KeyDescriptor(parsing: "left_command").carriesChordModifier)
        #expect(try !KeyDescriptor(parsing: "control+option+e").carriesChordModifier)
        #expect(try !KeyDescriptor(parsing: "mouse3").carriesChordModifier)
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

    // Chords are unchanged by the sided grammar: `option+a` still means either Option key, and still
    // resolves to the same Carbon registration it always did.
    @Test func aChordsModifiersAreSidelessAndUnchanged() throws {
        let chord = try KeyDescriptor(parsing: "option+a")
        #expect(chord == .chord(modifiers: [.option], key: .character("a")))
        #expect(chord.canonical == "option+a")
        #expect(chord.requiredModifiers == [.option])
        #expect(chord.requiredModifierMask == ModifierSet([.option]))
        #expect(chord.chordKeyCode(in: .ansiUS) == 0)
        #expect(!chord.carriesChordModifier)   // a chord is not a modifier-only trigger
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

    @Test func aModifierOnlySpellingIsASetNotAChord() throws {
        #expect(try KeyDescriptor(parsing: "control+option")
            == .modifiers(ModifierKeySet([SidedModifier(.control), SidedModifier(.option)])))
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
        for s in ["fn", "right_option", "right_command", "control+option+a", "f5",
                  "control+`", "command+[", "control+space", "command+up", "control+keypad_0",
                  "option+f13", "control+option+é"] {
            #expect(try KeyDescriptor(parsing: s).canonical == s)
        }
    }

    @Test func canonicalNormalizesModifierOrder() throws {
        #expect(try KeyDescriptor(parsing: "command+shift+option+control+k").canonical
            == "control+option+shift+command+k")
    }

    @Test func modifierKeyCodesMatchSpikeFindings() {
        #expect(ModifierKeyCodes.sidedModifier(forKeyCode: 63) == SidedModifier(.fn))
        #expect(ModifierKeyCodes.sidedModifier(forKeyCode: 61) == SidedModifier(.option, .right))
        #expect(ModifierKeyCodes.sidedModifier(forKeyCode: 54) == SidedModifier(.command, .right))
        #expect(ModifierKeyCodes.sidedModifier(forKeyCode: 55) == SidedModifier(.command, .left))
        #expect(ModifierKeyCodes.sidedModifier(forKeyCode: 58) == SidedModifier(.option, .left))
        #expect(ModifierKeyCodes.sidedModifier(forKeyCode: 59) == SidedModifier(.control, .left))
        #expect(ModifierKeyCodes.sidedModifier(forKeyCode: 62) == SidedModifier(.control, .right))
        #expect(ModifierKeyCodes.sidedModifier(forKeyCode: 56) == SidedModifier(.shift, .left))
        #expect(ModifierKeyCodes.sidedModifier(forKeyCode: 60) == SidedModifier(.shift, .right))
        #expect(ModifierKeyCodes.sidedModifier(forKeyCode: 0) == nil)
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

    @Test func nonChordsHaveNoChordKeyCode() throws {
        #expect(try KeyDescriptor(parsing: "fn").chordKeyCode(in: .ansiUS) == nil)
        #expect(KeyDescriptor.mouseButton(3).chordKeyCode(in: .ansiUS) == nil)
    }

    @Test func hyperExpandsToFourModifiers() throws {
        #expect(try KeyDescriptor(parsing: "hyper").requiredModifiers == [.control, .option, .shift, .command])
        #expect(try KeyDescriptor(parsing: "fn").requiredModifiers.isEmpty)
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
        #expect(try KeyDescriptor(parsing: "fn").displayString == "Fn (Globe)")
        #expect(try KeyDescriptor(parsing: "right_option").displayString == "Right-⌥")
        #expect(try KeyDescriptor(parsing: "right_command").displayString == "Right-⌘")
        #expect(try KeyDescriptor(parsing: "hyper").displayString == "⌃⌥⇧⌘")
    }

    @Test func displayStringForNewModifierSets() throws {
        #expect(try KeyDescriptor(parsing: "left_command+left_control").displayString == "Left-⌃ + Left-⌘")
        #expect(try KeyDescriptor(parsing: "command+control").displayString == "⌃⌘")
        #expect(try KeyDescriptor(parsing: "left_command").displayString == "Left-⌘")
        #expect(try KeyDescriptor(parsing: "fn+left_command").displayString == "Left-⌘ + Fn")
    }

    @Test func collidesWhenSamePhysicalEvent() throws {
        let a = try KeyDescriptor(parsing: "option+control+a")
        let b = try KeyDescriptor(parsing: "control+option+a")
        #expect(a.collides(with: b))
        #expect(try !a.collides(with: KeyDescriptor(parsing: "control+option+b")))
        #expect(try !KeyDescriptor(parsing: "fn").collides(with: KeyDescriptor(parsing: "right_option")))
        #expect(try KeyDescriptor(parsing: "fn").collides(with: KeyDescriptor(parsing: "fn")))
    }

    // Collision is "one press engages both", not set equality: a sideless member accepts either key, so
    // `command` and `right_command` are the same press and must not both stay registered.
    @Test func modifierSetsCollideWhenOnePressEngagesBoth() throws {
        #expect(try KeyDescriptor(parsing: "left_command+left_control")
            .collides(with: KeyDescriptor(parsing: "left_control+left_command")))
        #expect(try KeyDescriptor(parsing: "left_command")
            .collides(with: KeyDescriptor(parsing: "command")))
        #expect(try KeyDescriptor(parsing: "command")
            .collides(with: KeyDescriptor(parsing: "right_command")))
        #expect(try KeyDescriptor(parsing: "command+control")
            .collides(with: KeyDescriptor(parsing: "left_command+left_control")))
        // Opposite sides of the same modifier are never one press, so they are two usable triggers.
        #expect(try !KeyDescriptor(parsing: "left_command")
            .collides(with: KeyDescriptor(parsing: "right_command")))
        #expect(try !KeyDescriptor(parsing: "left_command+left_control")
            .collides(with: KeyDescriptor(parsing: "left_command+right_control")))
        #expect(try !KeyDescriptor(parsing: "left_command")
            .collides(with: KeyDescriptor(parsing: "left_command+left_control")))
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
        #expect(try !m3.collides(with: KeyDescriptor(parsing: "fn")))
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
