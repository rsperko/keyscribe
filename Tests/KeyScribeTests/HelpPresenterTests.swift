import Testing
@testable import KeyScribeApp

@MainActor
struct EscapeClaimTests {
    @Test func claimingRegistersBareEscapeAndReleasingDropsIt() {
        let registrar = FakeChordRegistrar()
        let claim = EscapeClaim(registrar: registrar)
        var presses = 0
        #expect(claim.claim { presses += 1 })
        #expect(registrar.lastRegistrations.map(\.keyCode) == [EscapeClaim.keyCode])
        #expect(registrar.lastRegistrations.first?.modifiers == [])
        registrar.lastRegistrations.first?.onPressed()
        #expect(presses == 1)
        claim.release()
        #expect(registrar.lastRegistrations.isEmpty)
    }

    @Test func aRefusedClaimSaysSo() {
        let registrar = FakeChordRegistrar()
        registrar.refuses = true
        #expect(!EscapeClaim(registrar: registrar).claim {})
    }
}

@MainActor
struct HelpPresenterTests {
    private func presenter(_ registrar: FakeChordRegistrar = FakeChordRegistrar(), hides: @escaping () -> Void = {}) -> HelpPresenter {
        let help = HelpPresenter(escape: EscapeClaim(registrar: registrar), hide: hides)
        help.seconds = 0.05
        help.voiceOverRunning = { false }
        return help
    }

    private func waitUntil(_ done: () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func itClosesOnItsOwnAndReleasesEscape() async throws {
        let registrar = FakeChordRegistrar()
        var hides = 0
        let help = presenter(registrar) { hides += 1 }
        help.shown()
        #expect(registrar.lastRegistrations.count == 1)
        try await waitUntil { hides > 0 }
        #expect(hides == 1)
        #expect(!help.showing)
        #expect(registrar.lastRegistrations.isEmpty)
    }

    @Test func thePointerHoldsItOpenAndLeavingRestartsTheTimer() async throws {
        var hides = 0
        let help = presenter { hides += 1 }
        help.shown()
        help.hover(true)
        try await Task.sleep(for: .milliseconds(150))
        #expect(hides == 0)
        help.hover(false)
        try await waitUntil { hides > 0 }
        #expect(hides == 1)
    }

    @Test func voiceOverKeepsItOpenUntilClosed() async throws {
        var hides = 0
        let help = presenter { hides += 1 }
        help.voiceOverRunning = { true }
        help.shown()
        try await Task.sleep(for: .milliseconds(150))
        #expect(hides == 0)
        help.dismiss()
        #expect(hides == 1)
    }

    @Test func escapeClosesItAndReleasingWithoutDrawingLeavesNothingBehind() async throws {
        let registrar = FakeChordRegistrar()
        var hides = 0
        let help = presenter(registrar) { hides += 1 }
        help.shown()
        registrar.lastRegistrations.first?.onPressed()
        #expect(hides == 1)
        #expect(registrar.lastRegistrations.isEmpty)
        help.shown()
        help.release()
        try await Task.sleep(for: .milliseconds(150))
        #expect(hides == 1)
        #expect(registrar.lastRegistrations.isEmpty)
        help.hover(false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(hides == 1)
    }
}
