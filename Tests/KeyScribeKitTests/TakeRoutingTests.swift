import Foundation
import Testing
@testable import KeyScribeKit

struct TakeRoutingTests {
    private var notes: Mode { Mode(id: "notes", name: "Notes") }
    private var html: Mode {
        var mode = Mode(id: "html", name: "HTML")
        mode.triggerPhrases = ["as html"]
        return mode
    }

    @Test func aTriggerPhraseSuffixRoutesToItsModeAndIsStripped() {
        let route = TakeRouting.phaseB(raw: "make a table as html", eligible: [notes, html], context: RoutingContext(), pressMode: notes)
        #expect(route.mode?.id == "html")
        #expect(route.routedByPhrase)
        #expect(route.result.matchedPhrase == "as html")
        #expect(route.result.transcript == "make a table")
    }

    @Test func withoutAPhraseThePressModeStands() {
        let route = TakeRouting.phaseB(raw: "make a table", eligible: [notes, html], context: RoutingContext(), pressMode: notes)
        #expect(route.mode?.id == "notes")
        #expect(!route.routedByPhrase)
        #expect(route.result.transcript == "make a table")
    }

    @Test func aPhraseForAModeThatIsNotEligibleRoutesNowhere() {
        let route = TakeRouting.phaseB(raw: "make a table as html", eligible: [notes], context: RoutingContext(), pressMode: notes)
        #expect(route.mode?.id == "notes")
        #expect(!route.routedByPhrase)
    }

    @Test func anUnterminatedVerbatimSpanStillRoutes() {
        let route = TakeRouting.phaseB(
            raw: "begin verbatim write this as html", eligible: [notes, html], context: RoutingContext(), pressMode: notes)
        #expect(route.mode?.id == "html")
    }
}
