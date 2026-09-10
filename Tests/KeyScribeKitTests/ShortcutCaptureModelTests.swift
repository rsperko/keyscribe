import Testing
@testable import KeyScribeKit

@Suite struct ShortcutCaptureModelTests {
    private func chord(_ mods: Set<Modifier>, _ key: BaseKey) -> KeyDescriptor {
        .chord(modifiers: mods, key: key)
    }

    private func mods(_ members: SidedModifier...) -> KeyDescriptor {
        .modifiers(try! ModifierKeySet(Set(members)))
    }

    @Test func storedModifierOnlyKeyParsesToValue() {
        let model = ShortcutCaptureModel(profile: .modeTrigger, stored: "hyper")
        #expect(model.value == mods(.init(.control), .init(.option), .init(.shift), .init(.command)))
        #expect(model.rawFallback == nil)
        #expect(model.phase == .idle)
    }

    @Test func storedEmptyIsNone() {
        let model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        #expect(model.value == nil)
        #expect(model.rawFallback == nil)
    }

    @Test func storedUnparseableSetsRawFallback() {
        let model = ShortcutCaptureModel(profile: .modeTrigger, stored: "wat+nonsense")
        #expect(model.value == nil)
        #expect(model.rawFallback == "wat+nonsense")
    }

    @Test func beginRecordingEntersRecordingAndClearsHint() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "fn")
        model.beginRecording()
        #expect(model.phase == .recording)
        #expect(model.hint == nil)
    }

    @Test func validKeyCaptureCommitsAndClearsHint() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        let committed = model.keyEvent(keyCode: 9, shortcutCharacter: "v", modifiers: [.control, .option])
        #expect(committed == chord([.control, .option], .character("v")))
        #expect(model.value == chord([.control, .option], .character("v")))
        #expect(model.phase == .idle)
        #expect(model.hint == nil)
    }

    @Test func tappingRightCommandRecordsModifierOnlyTrigger() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "hyper")
        model.beginRecording()
        #expect(model.modifierEvent(keyCode: 54, modifiers: [.command]) == nil)
        #expect(model.modifierEvent(keyCode: 54, modifiers: []) == mods(.init(.command, .right)))
        #expect(model.value == mods(.init(.command, .right)))
        #expect(model.phase == .idle)
    }

    @Test func tappingRightOptionReplacesHyperTrigger() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "hyper")
        model.beginRecording()
        #expect(model.modifierEvent(keyCode: 61, modifiers: [.option]) == nil)
        #expect(model.modifierEvent(keyCode: 61, modifiers: []) == mods(.init(.option, .right)))
        #expect(model.value == mods(.init(.option, .right)))
        #expect(model.phase == .idle)
    }

    @Test func aSingleModifierRecordsSided() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        #expect(model.modifierEvent(keyCode: 55, modifiers: [.command]) == nil)
        #expect(model.modifierEvent(keyCode: 55, modifiers: []) == mods(.init(.command, .left)))
        #expect(model.value?.canonical == "left_command")
    }

    // A pair keeps the keys it was pressed on, so Left-⌘ + Left-⌃ binds those keys and not the other pair.
    @Test func aModifierPairRecordsBothMembersSided() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        #expect(model.modifierEvent(keyCode: 55, modifiers: [.command]) == nil)
        #expect(model.modifierEvent(keyCode: 59, modifiers: [.command, .control]) == nil)
        #expect(model.modifierEvent(keyCode: 59, modifiers: [.command]) == nil)
        #expect(model.modifierEvent(keyCode: 55, modifiers: []) != nil)
        #expect(model.value?.canonical == "left_control+left_command")
    }

    // The release of a multi-modifier press is staggered, so the set at the final release is a subset of
    // what the user actually held. Recording the peak union is what makes ⌃⌥⇧⌘ record as ⌃⌥⇧⌘ and not ⌘.
    @Test func aStaggeredReleaseRecordsThePeakSetNotTheLastKeyDown() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        _ = model.modifierEvent(keyCode: 59, modifiers: [.control])
        _ = model.modifierEvent(keyCode: 58, modifiers: [.control, .option])
        _ = model.modifierEvent(keyCode: 56, modifiers: [.control, .option, .shift])
        _ = model.modifierEvent(keyCode: 55, modifiers: [.control, .option, .shift, .command])
        _ = model.modifierEvent(keyCode: 59, modifiers: [.option, .shift, .command])
        _ = model.modifierEvent(keyCode: 58, modifiers: [.shift, .command])
        _ = model.modifierEvent(keyCode: 56, modifiers: [.command])
        #expect(model.modifierEvent(keyCode: 55, modifiers: []) != nil)
        #expect(model.value?.canonical == "left_control+left_option+left_shift+left_command")
    }

    @Test func fnRecordsAsAModifierOnlyTrigger() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        #expect(model.modifierEvent(keyCode: 63, modifiers: [.fn]) == nil)
        #expect(model.modifierEvent(keyCode: 63, modifiers: []) == mods(.init(.fn)))
        #expect(model.value?.canonical == "fn")
    }

    @Test func bothSidesOfOneModifierHintsInsteadOfRecording() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        _ = model.modifierEvent(keyCode: 55, modifiers: [.command])   // left ⌘ down
        _ = model.modifierEvent(keyCode: 54, modifiers: [.command])   // right ⌘ down, left still held
        _ = model.modifierEvent(keyCode: 54, modifiers: [.command])   // right ⌘ up, left still held
        #expect(model.modifierEvent(keyCode: 55, modifiers: []) == nil)
        #expect(model.value == nil)
        #expect(model.phase == .recording)
        #expect(model.hint == "Left and right ⌘ can't be combined")
    }

    @Test func tooManyModifiersHintsInsteadOfRecording() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        _ = model.modifierEvent(keyCode: 59, modifiers: [.control])
        _ = model.modifierEvent(keyCode: 58, modifiers: [.control, .option])
        _ = model.modifierEvent(keyCode: 56, modifiers: [.control, .option, .shift])
        _ = model.modifierEvent(keyCode: 55, modifiers: [.control, .option, .shift, .command])
        _ = model.modifierEvent(keyCode: 63, modifiers: [.control, .option, .shift, .command, .fn])
        _ = model.modifierEvent(keyCode: 63, modifiers: [.control, .option, .shift, .command])
        _ = model.modifierEvent(keyCode: 59, modifiers: [.option, .shift, .command])
        _ = model.modifierEvent(keyCode: 58, modifiers: [.shift, .command])
        _ = model.modifierEvent(keyCode: 56, modifiers: [.command])
        #expect(model.modifierEvent(keyCode: 55, modifiers: []) == nil)
        #expect(model.value == nil)
        #expect(model.hint == "Use at most four modifiers")
    }

    // A CHORD never carries a side, however the user typed it: recording ⌥A on the left Option stores the
    // sideless `option+a`, which fires on either Option key. Sides exist only for modifier-ONLY triggers,
    // because Carbon cannot distinguish them for a registered chord.
    @Test func aChordRecordedOnOneSideIsStillSideless() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        #expect(model.modifierEvent(keyCode: 58, modifiers: [.option]) == nil)   // LEFT Option down
        let committed = model.keyEvent(keyCode: 0, shortcutCharacter: "a", modifiers: [.option])
        #expect(committed == chord([.option], .character("a")))
        #expect(model.value?.canonical == "option+a")
    }

    @Test func commandXRecordsChordInsteadOfPendingRightCommand() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        #expect(model.modifierEvent(keyCode: 54, modifiers: [.command]) == nil)
        #expect(model.keyEvent(keyCode: 7, shortcutCharacter: "x", modifiers: [.command]) == chord([.command], .character("x")))
        #expect(model.value == chord([.command], .character("x")))
        #expect(model.phase == .idle)
    }

    // A key that failed to record still consumes the held modifiers, so releasing them afterwards must
    // not quietly commit a modifier-only trigger the user never meant to bind.
    @Test func aRejectedKeyClearsThePendingModifierSet() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        _ = model.modifierEvent(keyCode: 55, modifiers: [.command])
        _ = model.keyEvent(keyCode: 9999, shortcutCharacter: nil, modifiers: [.command])
        #expect(model.modifierEvent(keyCode: 55, modifiers: []) == nil)
        #expect(model.value == nil)
    }

    // The action-chord profile takes chords only, so a modifier press it can't use must say why rather
    // than record a trigger the Carbon path could never register.
    @Test func actionChordProfileRejectsModifierOnlyWithTheNoKeyHint() {
        var model = ShortcutCaptureModel(profile: .actionChord, stored: "")
        model.beginRecording()
        _ = model.modifierEvent(keyCode: 59, modifiers: [.control])
        _ = model.modifierEvent(keyCode: 58, modifiers: [.control, .option])
        #expect(model.modifierEvent(keyCode: 58, modifiers: []) == nil)
        #expect(model.value == nil)
        #expect(model.phase == .recording)
        #expect(model.hint == "No key received — another app may already use this shortcut.")
    }

    @Test func bareLetterStaysRecordingWithHint() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        let committed = model.keyEvent(keyCode: 9, shortcutCharacter: "v", modifiers: [])
        #expect(committed == nil)
        #expect(model.phase == .recording)
        #expect(model.hint == "Hold a modifier (⌃⌥⇧⌘) with the key")
        #expect(model.value == nil)
    }

    @Test func bareFunctionKeyIsValidChord() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        let committed = model.keyEvent(keyCode: 122, shortcutCharacter: nil, modifiers: [])
        #expect(committed == chord([], .key(.f1)))
        #expect(model.phase == .idle)
    }

    @Test func punctuationKeyRecordsAsItsCharacter() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        #expect(model.keyEvent(keyCode: 50, shortcutCharacter: "`", modifiers: [.control])
            == chord([.control], .character("`")))
        #expect(model.phase == .idle)
        #expect(model.hint == nil)
    }

    @Test func specialKeyRecordsByPositionNotByTheCharacterItTypes() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        #expect(model.keyEvent(keyCode: 49, shortcutCharacter: " ", modifiers: [.option])
            == chord([.option], .key(.space)))
    }

    @Test func aKeyTheLayoutCannotNameHints() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        #expect(model.keyEvent(keyCode: 10, shortcutCharacter: nil, modifiers: [.command]) == nil)
        #expect(model.phase == .recording)
        #expect(model.hint == "That key can't be recorded")
    }

    @Test func unknownKeyCodeWithModifierHints() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        let committed = model.keyEvent(keyCode: 9999, shortcutCharacter: nil, modifiers: [.command])
        #expect(committed == nil)
        #expect(model.phase == .recording)
        #expect(model.hint == "That key can't be recorded")
    }

    @Test func validMouseCaptureCommitsInModeTrigger() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        let committed = model.mouseEvent(buttonNumber: 3)
        #expect(committed == .mouseButton(3))
        #expect(model.value == .mouseButton(3))
        #expect(model.phase == .idle)
    }

    @Test func mousePrimaryButtonsRejected() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        #expect(model.mouseEvent(buttonNumber: 0) == nil)
        #expect(model.mouseEvent(buttonNumber: 1) == nil)
        #expect(model.phase == .recording)
    }

    @Test func mouseRejectedInActionChordProfileWithHint() {
        var model = ShortcutCaptureModel(profile: .actionChord, stored: "")
        model.beginRecording()
        let committed = model.mouseEvent(buttonNumber: 4)
        #expect(committed == nil)
        #expect(model.phase == .recording)
        #expect(model.hint == "Mouse buttons can't be used for this shortcut")
        #expect(model.value == nil)
    }

    @Test func cancelRevertsFromNamed() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "fn")
        model.beginRecording()
        model.cancel()
        #expect(model.value?.canonical == "fn")
        #expect(model.phase == .idle)
        #expect(model.hint == nil)
    }

    @Test func cancelRevertsFromChord() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "control+option+v")
        model.beginRecording()
        _ = model.keyEvent(keyCode: 9999, shortcutCharacter: nil, modifiers: [.command])
        model.cancel()
        #expect(model.value == chord([.control, .option], .character("v")))
        #expect(model.hint == nil)
    }

    @Test func cancelRevertsFromNone() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        model.cancel()
        #expect(model.value == nil)
        #expect(model.phase == .idle)
    }

    @Test func cancelWhileIdleIsNoOp() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "fn")
        model.cancel()
        #expect(model.value?.canonical == "fn")
        #expect(model.phase == .idle)
    }

    @Test func selectModifierOnlyWhileIdleSetsValue() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.select(mods(.init(.option, .right)))
        #expect(model.value?.canonical == "right_option")
        #expect(model.phase == .idle)
    }

    @Test func selectModifierOnlyWhileRecordingCancelsThenSets() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "fn")
        model.beginRecording()
        model.select(try! KeyDescriptor(parsing: "hyper"))
        #expect(model.value?.canonical == "control+option+shift+command")
        #expect(model.phase == .idle)
        #expect(model.hint == nil)
    }

    @Test func selectNilClearsWithoutTouchingIdlePhase() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "fn")
        model.select(nil)
        #expect(model.value == nil)
        #expect(model.phase == .idle)
    }

    @Test func selectClearsRawFallback() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "wat+nonsense")
        #expect(model.rawFallback == "wat+nonsense")
        model.select(mods(.init(.fn)))
        #expect(model.value?.canonical == "fn")
        #expect(model.rawFallback == nil)
    }

    @Test func recordFromRawFallbackCommitsAndClearsFallback() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "wat+nonsense")
        model.beginRecording()
        let committed = model.keyEvent(keyCode: 9, shortcutCharacter: "v", modifiers: [.control, .option, .shift])
        #expect(committed == chord([.control, .option, .shift], .character("v")))
        #expect(model.rawFallback == nil)
    }

    @Test func cancelFromRawFallbackKeepsFallback() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "wat+nonsense")
        model.beginRecording()
        model.cancel()
        #expect(model.value == nil)
        #expect(model.rawFallback == "wat+nonsense")
    }

    @Test func noKeyOnModifierReleaseSetsHintWhileRecording() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        model.noKeyOnModifierRelease()
        #expect(model.hint == "No key received — another app may already use this shortcut.")
        #expect(model.phase == .recording)
        #expect(model.value == nil)
    }

    @Test func noKeyOnModifierReleaseIsNoOpWhenIdle() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "fn")
        model.noKeyOnModifierRelease()
        #expect(model.hint == nil)
    }

    @Test func captureClearsNoKeyHint() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        model.noKeyOnModifierRelease()
        #expect(model.hint != nil)
        _ = model.keyEvent(keyCode: 9, shortcutCharacter: "v", modifiers: [.control, .option])
        #expect(model.hint == nil)
    }

    @Test func actionChordProfileOffersNoModifierOnlyTriggers() {
        #expect(ShortcutProfile.actionChord.suggestedModifierTriggers.isEmpty)
        #expect(ShortcutProfile.modeTrigger.suggestedModifierTriggers.map(\.canonical)
            == ["fn", "right_option", "right_command", "right_control", "control+option+shift+command"])
    }
}
