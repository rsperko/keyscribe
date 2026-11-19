import Foundation
import KeyScribeKit
import Testing

struct OpencodeEventsTests {
    func event(_ type: String, id: String = "evt_1", _ data: String) -> Data {
        Data(#"{"id":"\#(id)","created":1,"type":"\#(type)","location":{"directory":"/w"},"data":\#(data)}"#.utf8)
    }

    func key(_ native: String) -> String { "opencode:" + native }

    @Test func anExecutionStartingStartsATurnNamedByItsEvent() {
        var turns = OpencodeTurns()
        #expect(turns.apply(event("session.execution.started", id: "evt_9", #"{"sessionID":"ses_a"}"#), key: key) == [
            .event(.turnStarted(session: "opencode:ses_a", turn: "evt_9")),
        ])
    }

    @Test func aSucceededExecutionCompletesWithTheLastTextItEnded() {
        var turns = OpencodeTurns()
        _ = turns.apply(event("session.execution.started", id: "evt_t", #"{"sessionID":"ses_a"}"#), key: key)
        _ = turns.apply(event("session.text.ended", #"{"sessionID":"ses_a","assistantMessageID":"m1","ordinal":0,"text":"Looking."}"#), key: key)
        _ = turns.apply(event("session.text.ended", #"{"sessionID":"ses_a","assistantMessageID":"m2","ordinal":0,"text":"done banana"}"#), key: key)
        #expect(turns.apply(event("session.execution.succeeded", #"{"sessionID":"ses_a"}"#), key: key) == [
            .event(.turnComplete(session: "opencode:ses_a", reason: "complete", answer: "done banana", turn: "evt_t")),
        ])
    }

    @Test func textFromAnotherSessionIsNotThisSessionsAnswer() {
        var turns = OpencodeTurns()
        _ = turns.apply(event("session.text.ended", #"{"sessionID":"ses_b","text":"other"}"#), key: key)
        #expect(turns.apply(event("session.execution.succeeded", #"{"sessionID":"ses_a"}"#), key: key) == [
            .event(.turnComplete(session: "opencode:ses_a", reason: "complete", answer: "")),
        ])
    }

    @Test func anAnswerIsForgottenOnceItsTurnCompletes() {
        var turns = OpencodeTurns()
        _ = turns.apply(event("session.text.ended", #"{"sessionID":"ses_a","text":"first"}"#), key: key)
        _ = turns.apply(event("session.execution.succeeded", #"{"sessionID":"ses_a"}"#), key: key)
        #expect(turns.apply(event("session.execution.succeeded", #"{"sessionID":"ses_a"}"#), key: key) == [
            .event(.turnComplete(session: "opencode:ses_a", reason: "complete", answer: "")),
        ])
    }

    @Test func aLongAnswerIsCutToTheReplyLimit() {
        var turns = OpencodeTurns()
        let long = String(repeating: "a", count: OpencodeTurns.answerLimit + 50)
        _ = turns.apply(event("session.text.ended", #"{"sessionID":"ses_a","text":"\#(long)"}"#), key: key)
        guard case .event(.turnComplete(_, _, let answer, _, _)) = turns.apply(event("session.execution.succeeded", #"{"sessionID":"ses_a"}"#), key: key).first
        else { Issue.record("no completion"); return }
        #expect(answer.count == OpencodeTurns.answerLimit)
    }

    @Test func anInterruptedOrFailedExecutionEndsTheTurnWithoutAnAnswer() {
        var turns = OpencodeTurns()
        _ = turns.apply(event("session.text.ended", #"{"sessionID":"ses_a","text":"half"}"#), key: key)
        #expect(turns.apply(event("session.execution.interrupted", #"{"sessionID":"ses_a"}"#), key: key) == [
            .event(.turnComplete(session: "opencode:ses_a", reason: "aborted", answer: "")),
        ])
        #expect(turns.apply(event("session.execution.failed", #"{"sessionID":"ses_a"}"#), key: key) == [
            .event(.turnComplete(session: "opencode:ses_a", reason: "error", answer: "")),
        ])
    }

    @Test func aPermissionRequestWaitsForApprovalOfItsActionAndResources() {
        var turns = OpencodeTurns()
        let asked = #"{"id":"per_1","sessionID":"ses_a","action":"bash","resources":["rm -rf build","ls"]}"#
        #expect(turns.apply(event("permission.asked", asked), key: key) == [
            .event(.waiting(session: "opencode:ses_a", prompt: AgentPrompt(kind: "confirm", tool: "bash", detail: "rm -rf build\nls"))),
        ])
        #expect(turns.asking("ses_a") == AgentPrompt(kind: "confirm", tool: "bash", detail: "rm -rf build\nls"))
        #expect(turns.apply(event("permission.replied", #"{"sessionID":"ses_a","requestID":"per_1","reply":"once"}"#), key: key) == [
            .event(.waiting(session: "opencode:ses_a", prompt: nil)),
        ])
        #expect(turns.asking("ses_a") == nil)
    }

    @Test func aFormAsksTheQuestionInItsTitle() {
        var turns = OpencodeTurns()
        let created = #"{"form":{"id":"frm_1","sessionID":"ses_a","title":"Pick one","fields":[{"key":"c","type":"string"}]}}"#
        #expect(turns.apply(event("form.created", created), key: key) == [
            .event(.waiting(session: "opencode:ses_a", prompt: AgentPrompt(kind: "select", title: "Pick one"))),
        ])
        #expect(turns.apply(event("form.cancelled", #"{"id":"frm_1","sessionID":"ses_a"}"#), key: key) == [
            .event(.waiting(session: "opencode:ses_a", prompt: nil)),
        ])
    }

    @Test func theAgentsQuestionToolAsksItsFirstQuestionNotTheFormsGenericTitle() {
        var turns = OpencodeTurns()
        let created = #"""
            {"form":{"id":"frm_q","sessionID":"ses_a","title":"Questions","metadata":{"kind":"question"},
             "fields":[{"key":"q0","title":"Color preference","description":"Do you prefer red or blue?","type":"string"},
                       {"key":"q1","title":"Second","type":"string"}]}}
            """#
        #expect(turns.apply(event("form.created", created), key: key) == [
            .event(.waiting(session: "opencode:ses_a", prompt: AgentPrompt(kind: "select", title: "Do you prefer red or blue?"))),
        ])
        let untitled = #"{"form":{"id":"frm_r","sessionID":"ses_b","title":"Questions","metadata":{"kind":"question"},"fields":[{"key":"q0","title":"Color","type":"string"}]}}"#
        #expect(turns.apply(event("form.created", untitled), key: key) == [
            .event(.waiting(session: "opencode:ses_b", prompt: AgentPrompt(kind: "select", title: "Color"))),
        ])
    }

    @Test func answeringOneOfTwoOpenRequestsKeepsTheSessionWaitingOnTheOther() {
        var turns = OpencodeTurns()
        _ = turns.apply(event("permission.asked", #"{"id":"per_1","sessionID":"ses_a","action":"bash","resources":[]}"#), key: key)
        _ = turns.apply(event("form.created", #"{"form":{"id":"frm_1","sessionID":"ses_a","title":"Q","fields":[]}}"#), key: key)
        #expect(turns.apply(event("permission.replied", #"{"sessionID":"ses_a","requestID":"per_1","reply":"once"}"#), key: key) == [
            .event(.waiting(session: "opencode:ses_a", prompt: AgentPrompt(kind: "select", title: "Q"))),
        ])
    }

    @Test func endingATurnClearsWhatItWasAsking() {
        var turns = OpencodeTurns()
        _ = turns.apply(event("permission.asked", #"{"id":"per_1","sessionID":"ses_a","action":"bash","resources":[]}"#), key: key)
        _ = turns.apply(event("session.execution.interrupted", #"{"sessionID":"ses_a"}"#), key: key)
        #expect(turns.asking("ses_a") == nil)
    }

    func enqueued(_ inbox: String, _ text: String, session: String = "ses_a") -> Data {
        event("session.inbox.enqueued", #"{"sessionID":"\#(session)","inboxID":"\#(inbox)","item":{"type":"user","payload":{"text":"\#(text)"},"delivery":"steer"}}"#)
    }

    func delivered(_ inbox: String, session: String = "ses_a") -> Data {
        event("session.inbox.delivered", #"{"sessionID":"\#(session)","inboxID":"\#(inbox)"}"#)
    }

    @Test func aPromptTheTurnTakesInNamesThatTurnByItsDigest() {
        var turns = OpencodeTurns()
        _ = turns.apply(enqueued("msg_keyscribe_r1", "fix the build"), key: key)
        _ = turns.apply(event("session.execution.started", id: "evt_t", #"{"sessionID":"ses_a"}"#), key: key)
        #expect(turns.apply(delivered("msg_keyscribe_r1"), key: key) == [
            .event(.turnStarted(session: "opencode:ses_a", turn: "evt_t", prompt: AgentPromptDigest.of("fix the build"))),
        ])
    }

    @Test func aPromptSteeredIntoTheRunningTurnNamesThatSameTurn() {
        var turns = OpencodeTurns()
        _ = turns.apply(event("session.execution.started", id: "evt_t", #"{"sessionID":"ses_a"}"#), key: key)
        _ = turns.apply(enqueued("msg_keyscribe_r2", "also add tests"), key: key)
        #expect(turns.apply(delivered("msg_keyscribe_r2"), key: key) == [
            .event(.turnStarted(session: "opencode:ses_a", turn: "evt_t", prompt: AgentPromptDigest.of("also add tests"))),
        ])
    }

    @Test func aPromptKeyScribeDidNotSendIsTheUsersTyping() {
        var turns = OpencodeTurns()
        #expect(turns.apply(enqueued("msg_1f48d8224001", "typed here"), key: key) == [.event(.typed(session: "opencode:ses_a"))])
        #expect(turns.apply(enqueued("msg_keyscribe_r3", "dictated"), key: key) == [])
        let synthetic = event("session.inbox.enqueued", #"{"sessionID":"ses_a","inboxID":"msg_2","item":{"type":"compaction"}}"#)
        #expect(turns.apply(synthetic, key: key) == [])
    }

    @Test func aDeliveryWithNoTurnOrUnknownItemNamesNothing() {
        var turns = OpencodeTurns()
        _ = turns.apply(enqueued("msg_keyscribe_r4", "early"), key: key)
        #expect(turns.apply(delivered("msg_keyscribe_r4"), key: key) == [])
        _ = turns.apply(event("session.execution.started", id: "evt_t", #"{"sessionID":"ses_a"}"#), key: key)
        #expect(turns.apply(delivered("msg_unknown"), key: key) == [])
    }

    @Test func remembersOnlyABoundedNumberOfUndeliveredPrompts() {
        var turns = OpencodeTurns()
        _ = turns.apply(event("session.execution.started", id: "evt_t", #"{"sessionID":"ses_a"}"#), key: key)
        _ = turns.apply(enqueued("msg_keyscribe_old", "oldest"), key: key)
        for index in 0..<OpencodeTurns.pendingLimit { _ = turns.apply(enqueued("msg_keyscribe_\(index)", "p\(index)"), key: key) }
        #expect(turns.apply(delivered("msg_keyscribe_old"), key: key) == [])
        #expect(turns.apply(delivered("msg_keyscribe_0"), key: key).count == 1)
    }

    @Test func aRenameWithoutALocationIsTheUsersTitleAndTheGeneratedOneHasALocation() {
        var turns = OpencodeTurns()
        let generated = Data(#"{"id":"e1","type":"session.renamed","location":{"directory":"/w"},"data":{"sessionID":"ses_a","title":"Fix bug"}}"#.utf8)
        let typed = Data(#"{"id":"e2","type":"session.renamed","data":{"sessionID":"ses_a","title":"Login work"}}"#.utf8)
        #expect(!turns.titledByUser("ses_a"))
        #expect(turns.apply(typed, key: key) == [.listing])
        #expect(turns.titledByUser("ses_a"))
        _ = turns.apply(generated, key: key)
        #expect(!turns.titledByUser("ses_a"))
        _ = turns.apply(typed, key: key)
        turns.reset(permissions: nil, forms: nil)
        #expect(turns.titledByUser("ses_a"))
    }

    @Test func theRunningTurnsAreTheExecutionsStartedAndNotEnded() {
        var turns = OpencodeTurns()
        _ = turns.apply(event("session.execution.started", id: "evt_a", #"{"sessionID":"ses_a"}"#), key: key)
        _ = turns.apply(event("session.execution.started", id: "evt_b", #"{"sessionID":"ses_b"}"#), key: key)
        _ = turns.apply(event("session.execution.succeeded", #"{"sessionID":"ses_b"}"#), key: key)
        #expect(turns.running == ["ses_a": "evt_a"])
    }

    @Test func ourOwnPromptsAreRecognizedByTheirMessageId() {
        #expect(OpencodeTurns.isOurs("msg_keyscribe_abc"))
        #expect(!OpencodeTurns.isOurs("msg_1f48d8224001"))
    }

    @Test func sessionsAppearingRenamedOrRemovedChangeTheListing() {
        var turns = OpencodeTurns()
        for type in ["session.created", "session.renamed", "session.deleted", "session.archived", "session.moved"] {
            #expect(turns.apply(event(type, #"{"sessionID":"ses_a"}"#), key: key) == [.listing])
        }
    }

    @Test func unknownOrMalformedEventsChangeNothing() {
        var turns = OpencodeTurns()
        #expect(turns.apply(event("session.text.delta", #"{"sessionID":"ses_a","delta":"x"}"#), key: key) == [])
        #expect(turns.apply(event("permission.asked", #"{"id":"per_1"}"#), key: key) == [])
        #expect(turns.apply(Data("garbage".utf8), key: key) == [])
    }

    @Test func aRequestStillOpenAfterReconnectingIsSeededFromThePendingLists() {
        var turns = OpencodeTurns()
        turns.reset(
            permissions: Data(#"{"data":[{"id":"per_1","sessionID":"ses_a","action":"edit","resources":["a.swift"]}]}"#.utf8),
            forms: Data(#"{"data":[{"id":"frm_1","sessionID":"ses_b","title":"Which?","fields":[],"state":{"status":"pending"}}]}"#.utf8))
        #expect(turns.asking("ses_a") == AgentPrompt(kind: "confirm", tool: "edit", detail: "a.swift"))
        #expect(turns.asking("ses_b") == AgentPrompt(kind: "select", title: "Which?"))
    }
}
