import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribe

@MainActor
final class FakeChordRegistrar: ChordRegistering {
    var lastRegistrations: [CarbonHotKeys.Registration] = []

    func update(_ registrations: [CarbonHotKeys.Registration]) {
        lastRegistrations = registrations
    }

    func stop() { lastRegistrations = [] }
}

@MainActor
struct HotkeyMonitorChordTests {
    private func chordBinding(_ key: String, style: PressStyle = .holdOnly) -> HotkeyMonitor.Binding {
        .init(triggerKey: key, descriptor: try! KeyDescriptor(parsing: key), style: style, tapThreshold: 0.25)
    }

    private func drainMain() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    @Test func chordPressAndReleaseDriveTheGesture() async {
        let fake = FakeChordRegistrar()
        var starts = 0, commits = 0
        let m = HotkeyMonitor(
            bindings: [], onStart: { _ in starts += 1 }, onCommit: { _ in commits += 1 }, carbon: fake)
        m.update(bindings: [chordBinding("control+option+e")])
        #expect(fake.lastRegistrations.count == 1)

        fake.lastRegistrations[0].onPressed()
        await drainMain()
        #expect(starts == 1)
        #expect(commits == 0)

        fake.lastRegistrations[0].onReleased?()
        await drainMain()
        #expect(commits == 1)
    }

    @Test func suspendUnregistersChordsAndResumeRestoresThem() {
        let fake = FakeChordRegistrar()
        let m = HotkeyMonitor(bindings: [], onStart: { _ in }, onCommit: { _ in }, carbon: fake)
        m.update(bindings: [chordBinding("control+option+e")])
        #expect(fake.lastRegistrations.count == 1)

        m.isSuspended = true
        #expect(fake.lastRegistrations.isEmpty)

        m.isSuspended = false
        #expect(fake.lastRegistrations.count == 1)
    }

    @Test func hudHoldsKeyFocusOnlyAcrossCancellableStates() {
        #expect(HUDState.recording(mode: nil, level: 0).holdsKeyFocus)
        #expect(HUDState.transcribing(mode: "m").holdsKeyFocus)
        #expect(HUDState.rewriting(
            connection: "c", redacted: false, contextCategories: [], offerLocalTranscript: false).holdsKeyFocus)
        #expect(!HUDState.ready(mode: "m").holdsKeyFocus)
        #expect(!HUDState.error(message: "x", action: nil).holdsKeyFocus)
        #expect(!HUDState.hidden.holdsKeyFocus)
    }
}
