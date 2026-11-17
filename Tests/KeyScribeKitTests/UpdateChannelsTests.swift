import Testing
@testable import KeyScribeKit

struct UpdateChannelsTests {
    @Test func stableOnlySearchesTheDefaultChannel() {
        #expect(UpdateChannels.allowed(beta: false).isEmpty)
    }

    @Test func betaAlsoSearchesTheBetaChannel() {
        #expect(UpdateChannels.allowed(beta: true) == ["beta"])
    }

    @Test func theLaunchChoiceIsRecordedWithoutACheck() {
        var selection = UpdateChannelSelection()
        let checks = selection.select(beta: true)
        #expect(!checks)
        #expect(selection.allowed == ["beta"])
    }

    @Test func aLaterChangeAsksForACheck() {
        var selection = UpdateChannelSelection()
        _ = selection.select(beta: false)
        let on = selection.select(beta: true)
        let off = selection.select(beta: false)
        #expect(on && off)
        #expect(selection.allowed.isEmpty)
    }

    @Test func reapplyingTheSameChoiceDoesNotCheck() {
        var selection = UpdateChannelSelection()
        _ = selection.select(beta: true)
        let again = selection.select(beta: true)
        #expect(!again)
    }

    @MainActor @Test func anUpdaterOffersNoBetaOptionUnlessItProvidesOne() {
        #expect(PlainUpdater().betaOption == nil)
    }
}

@MainActor
private final class PlainUpdater: AppUpdater {
    var onUpdateAvailable: (@MainActor () -> Void)?
    func dictationDidFinish() {}
    func performUpdate() {}
}
