import Testing
@testable import KeyScribeKit

struct ReleaseVersionTests {
    @Test(arguments: ["0.9.5", "v0.9.5", "0.10.0-beta.1", "v0.10.0-beta.12", "0.9.5+3", "0.10.0-beta.2+1"])
    func releaseAndBetaFormsParse(_ text: String) {
        #expect(ReleaseVersion(text) != nil)
    }

    @Test(arguments: ["0.9.4-93-gc24f67f", "0.9.4-dirty", "0.10", "0.10.0-rc.1", "0.10.0-beta", "0.10.0-beta.0", "0.9.5+x", ""])
    func otherFormsDoNotParse(_ text: String) {
        #expect(ReleaseVersion(text) == nil)
    }

    @Test func aBetaComesBeforeItsRelease() {
        #expect(v("0.10.0-beta.1") < v("0.10.0-beta.2"))
        #expect(v("0.10.0-beta.2") < v("0.10.0"))
        #expect(v("0.9.5") < v("0.10.0-beta.1"))
    }

    @Test func betaNumbersCompareAsNumbers() {
        #expect(v("0.10.0-beta.9") < v("0.10.0-beta.10"))
    }

    @Test func aDownstreamIterationOrdersWithinItsVersion() {
        #expect(v("0.9.5") < v("0.9.5+1"))
        #expect(v("0.9.5+3") < v("0.9.5+4"))
        #expect(v("0.9.5+9") < v("0.9.6"))
        #expect(v("0.10.0-beta.1+2") < v("0.10.0-beta.2"))
    }

    @Test func aBetaIsRecognized() {
        #expect(v("0.10.0-beta.1").isBeta)
        #expect(!v("0.10.0").isBeta)
    }

    private func v(_ text: String) -> ReleaseVersion { ReleaseVersion(text)! }
}

struct UpdateOfferTests {
    @Test func aNewerReleaseIsOfferedWhetherOrNotBetasAreOn() {
        #expect(UpdateOffer.shouldOffer(installed: "0.9.5", candidate: "0.10.0", betaOn: false))
        #expect(UpdateOffer.shouldOffer(installed: "0.10.0-beta.3", candidate: "0.10.0", betaOn: false))
        #expect(UpdateOffer.shouldOffer(installed: "0.10.0-beta.3", candidate: "0.10.0", betaOn: true))
    }

    @Test func aNewerBetaIsOfferedOnlyWithBetasOn() {
        #expect(UpdateOffer.shouldOffer(installed: "0.9.5", candidate: "0.10.0-beta.1", betaOn: true))
        #expect(!UpdateOffer.shouldOffer(installed: "0.9.5", candidate: "0.10.0-beta.1", betaOn: false))
    }

    @Test func turningBetasOffKeepsTheBetaUntilANewerReleaseArrives() {
        #expect(!UpdateOffer.shouldOffer(installed: "0.10.0-beta.3", candidate: "0.9.5", betaOn: false))
        #expect(!UpdateOffer.shouldOffer(installed: "0.10.0-beta.3", candidate: "0.9.6", betaOn: false))
    }

    @Test func nothingOlderOrEqualIsOffered() {
        #expect(!UpdateOffer.shouldOffer(installed: "0.10.0", candidate: "0.10.0", betaOn: true))
        #expect(!UpdateOffer.shouldOffer(installed: "0.10.0", candidate: "0.10.0-beta.3", betaOn: true))
    }

    @Test func aDownstreamIterationIsANewerVersion() {
        #expect(UpdateOffer.shouldOffer(installed: "0.9.5+1", candidate: "0.9.5+2", betaOn: false))
    }

    @Test func aVersionThatIsNotAReleaseOrBetaIsNeverOffered() {
        #expect(!UpdateOffer.shouldOffer(installed: "0.9.5", candidate: "0.10.0-rc.1", betaOn: true))
        #expect(!UpdateOffer.shouldOffer(installed: "0.9.4-93-gc24f67f", candidate: "0.9.5", betaOn: false))
    }
}
