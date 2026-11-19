import KeyScribeKit
import Testing

struct OpencodePaneTitleTests {
    let sessions = [
        OpencodeSession(id: "ses_pong", title: "Pong response request", directory: "/w", createdAt: nil),
        OpencodeSession(id: "ses_fix", title: "Fix the login bug", directory: "/w", createdAt: nil),
    ]

    @Test func theTerminalTitleNamesTheSessionTheTUIShows() {
        #expect(OpencodePaneTitle.session(in: "OC | Pong response request", among: sessions) == "ses_pong")
        #expect(OpencodePaneTitle.session(in: "⠋ OC | Fix the login bug", among: sessions) == "ses_fix")
    }

    @Test func aTitleThatIsNotOpencodesNamesNoSession() {
        #expect(OpencodePaneTitle.session(in: "Pong response request", among: sessions) == nil)
        #expect(OpencodePaneTitle.session(in: "OC", among: sessions) == nil)
        #expect(OpencodePaneTitle.session(in: "OC | ", among: sessions) == nil)
        #expect(OpencodePaneTitle.session(in: "vim OC | Pong response request.txt", among: sessions) == nil)
    }

    @Test func aShortenedTitleNamesTheOneSessionItStarts() {
        #expect(OpencodePaneTitle.session(in: "OC | Fix the lo…", among: sessions) == "ses_fix")
        #expect(OpencodePaneTitle.session(in: "OC | Fix the lo...", among: sessions) == "ses_fix")
        #expect(OpencodePaneTitle.session(in: "OC | Fix the lo", among: sessions) == nil)
    }

    @Test func theTitleOfTheHomePageSaysNoSessionIsShown() {
        #expect(OpencodePaneTitle.showsHome("OpenCode"))
        #expect(OpencodePaneTitle.showsHome(" OpenCode "))
        #expect(!OpencodePaneTitle.showsHome("OC | Pong response request"))
        #expect(!OpencodePaneTitle.showsHome("OpenCode docs — Safari"))
        #expect(OpencodePaneTitle.session(in: "OpenCode", among: sessions) == nil)
    }

    @Test func twoSessionsWithTheShownTitleNameNeither() {
        let twins = sessions + [OpencodeSession(id: "ses_twin", title: "Pong response request", directory: "/w", createdAt: nil)]
        #expect(OpencodePaneTitle.session(in: "OC | Pong response request", among: twins) == nil)
        #expect(OpencodePaneTitle.session(in: "OC | Pong…", among: twins) == nil)
    }
}
