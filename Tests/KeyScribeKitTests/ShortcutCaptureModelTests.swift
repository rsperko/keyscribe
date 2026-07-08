import Testing
@testable import KeyScribeKit

@Suite struct ShortcutCaptureModelTests {
    private func chord(_ mods: Set<Modifier>, _ key: BaseKey) -> KeyDescriptor {
        .chord(modifiers: mods, key: key)
    }

    @Test func storedNamedKeyParsesToValue() {
        let model = ShortcutCaptureModel(profile: .modeTrigger, stored: "hyper")
        #expect(model.value == .named(.hyper))
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
        let committed = model.keyEvent(keyCode: 9, modifiers: [.control, .option])
        #expect(committed == chord([.control, .option], .letter("v")))
        #expect(model.value == chord([.control, .option], .letter("v")))
        #expect(model.phase == .idle)
        #expect(model.hint == nil)
    }

    @Test func bareLetterStaysRecordingWithHint() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        let committed = model.keyEvent(keyCode: 9, modifiers: [])
        #expect(committed == nil)
        #expect(model.phase == .recording)
        #expect(model.hint == "Hold a modifier (⌃⌥⇧⌘) with the key")
        #expect(model.value == nil)
    }

    @Test func bareFunctionKeyIsValidChord() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        let committed = model.keyEvent(keyCode: 122, modifiers: [])
        #expect(committed == chord([], .function(1)))
        #expect(model.phase == .idle)
    }

    @Test func unknownKeyCodeWithModifierHints() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.beginRecording()
        let committed = model.keyEvent(keyCode: 9999, modifiers: [.command])
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
        #expect(model.value == .named(.fn))
        #expect(model.phase == .idle)
        #expect(model.hint == nil)
    }

    @Test func cancelRevertsFromChord() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "control+option+v")
        model.beginRecording()
        _ = model.keyEvent(keyCode: 9999, modifiers: [.command])
        model.cancel()
        #expect(model.value == chord([.control, .option], .letter("v")))
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
        #expect(model.value == .named(.fn))
        #expect(model.phase == .idle)
    }

    @Test func selectNamedWhileIdleSetsValue() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
        model.select(.named(.rightOption))
        #expect(model.value == .named(.rightOption))
        #expect(model.phase == .idle)
    }

    @Test func selectNamedWhileRecordingCancelsThenSets() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "fn")
        model.beginRecording()
        model.select(.named(.hyper))
        #expect(model.value == .named(.hyper))
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
        model.select(.named(.fn))
        #expect(model.value == .named(.fn))
        #expect(model.rawFallback == nil)
    }

    @Test func recordFromRawFallbackCommitsAndClearsFallback() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "wat+nonsense")
        model.beginRecording()
        let committed = model.keyEvent(keyCode: 9, modifiers: [.control, .option, .shift])
        #expect(committed == chord([.control, .option, .shift], .letter("v")))
        #expect(model.rawFallback == nil)
    }

    @Test func cancelFromRawFallbackKeepsFallback() {
        var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "wat+nonsense")
        model.beginRecording()
        model.cancel()
        #expect(model.value == nil)
        #expect(model.rawFallback == "wat+nonsense")
    }

    @Test func actionChordProfileOffersNoNamedKeys() {
        #expect(ShortcutProfile.actionChord.namedKeyOptions.isEmpty)
        #expect(ShortcutProfile.modeTrigger.namedKeyOptions == [.fn, .rightOption, .rightCommand, .hyper])
    }
}
