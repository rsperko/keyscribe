import Foundation
import KeyScribeKit
import Testing

struct CodexDeliveryTests {
    private let now = Date(timeIntervalSince1970: 1_795_015_834)

    private func data(_ json: String) -> Data { Data(json.utf8) }

    @Test func anIdleThreadWithNoPromptJustTypedTakesTheText() {
        #expect(CodexDelivery.precheck(status: .idle, lastForeignPrompt: nil, now: now) == .send)
        #expect(CodexDelivery.precheck(status: .idle, lastForeignPrompt: now.addingTimeInterval(-CodexDelivery.foreignPromptSettle), now: now) == .send)
    }

    @Test func anIdleThreadWithAPromptJustTypedHolds() {
        #expect(CodexDelivery.precheck(status: .idle, lastForeignPrompt: now.addingTimeInterval(-0.1), now: now) == .hold(.typedJustNow))
        #expect(CodexDelivery.precheck(status: .idle, lastForeignPrompt: now, now: now) == .hold(.typedJustNow))
        #expect(CodexDelivery.precheck(status: .idle, lastForeignPrompt: now.addingTimeInterval(1), now: now) == .hold(.typedJustNow))
        #expect(CodexDelivery.foreignPromptSettle == 0.2)
    }

    @Test func aThreadWorkingWithNothingAskedOfTheUserIsSteered() {
        #expect(CodexDelivery.precheck(status: .active([]), lastForeignPrompt: nil, now: now) == .send)
        #expect(CodexDelivery.precheck(status: .active([]), lastForeignPrompt: now, now: now) == .send)
    }

    @Test func aThreadWaitingOnTheUserOrInAnUnknownStateHolds() {
        #expect(CodexDelivery.precheck(status: .active([.waitingOnApproval]), lastForeignPrompt: nil, now: now) == .hold(.waitingApproval))
        #expect(CodexDelivery.precheck(status: .active([.waitingOnUserInput]), lastForeignPrompt: nil, now: now) == .hold(.waitingQuestion))
        #expect(CodexDelivery.precheck(status: .active([.unknown("new")]), lastForeignPrompt: nil, now: now) == .hold(.unknownState))
        #expect(CodexDelivery.precheck(status: .systemError, lastForeignPrompt: nil, now: now) == .hold(.unknownState))
        #expect(CodexDelivery.precheck(status: .unknown("compacting"), lastForeignPrompt: nil, now: now) == .hold(.unknownState))
    }

    @Test func aThreadThatIsNotOpenRefuses() {
        #expect(CodexDelivery.precheck(status: nil, lastForeignPrompt: nil, now: now) == .refuse(.notOpen))
        #expect(CodexDelivery.precheck(status: .notLoaded, lastForeignPrompt: nil, now: now) == .refuse(.notOpen))
    }

    @Test func theStartedTurnIsReadFromTurnStartsResult() {
        #expect(CodexDelivery.startedTurn(data(#"{"turn":{"id":"turn-2","items":[],"status":"inProgress"}}"#)) == "turn-2")
        #expect(CodexDelivery.startedTurn(data(#"{"turn":{}}"#)) == nil)
        #expect(CodexDelivery.startedTurn(data("nope")) == nil)
    }

    private let turnsList = #"""
        {"data":[
          {"id":"turn-2","rootTurnId":null,"itemsView":"full","status":"inProgress","error":null,"startedAt":1795015900,"completedAt":null,"durationMs":null,
           "items":[{"type":"userMessage","id":"i1","clientId":"typed-1","content":[{"type":"text","text":"hi","text_elements":[]}]},
                    {"type":"agentMessage","id":"i2","text":"ok"},
                    {"type":"userMessage","id":"i3","clientId":"ks-2","content":[]}]},
          {"id":"turn-1","itemsView":"full","status":"completed",
           "items":[{"type":"userMessage","id":"i0","clientId":"ks-1","content":[]},{"type":"userMessage","id":"i4","clientId":null,"content":[]}]}
        ],"nextCursor":"c2","backwardsCursor":null}
        """#

    @Test func theTurnsListKeepsEachTurnsUserMessagesInOrder() {
        let page = CodexDelivery.turns(data(turnsList))
        #expect(page?.turns == [
            CodexDelivery.Turn(id: "turn-2", status: "inProgress", clientIds: ["typed-1", "ks-2"]),
            CodexDelivery.Turn(id: "turn-1", status: "completed", clientIds: ["ks-1", nil]),
        ])
        #expect(page?.nextCursor == "c2")
        #expect(CodexDelivery.turns(data(#"{"data":[{"items":[]}]}"#)) == nil)
        #expect(CodexDelivery.turns(data("[]")) == nil)
    }

    @Test func theTurnHoldingOurMessageIsTheOneItOpenedOrJoined() {
        let turns = CodexDelivery.turns(data(turnsList))?.turns ?? []
        #expect(CodexDelivery.turn(in: turns, clientUserMessageId: "ks-1") == "turn-1")
        #expect(CodexDelivery.turn(in: turns, clientUserMessageId: "ks-2") == "turn-2")
        #expect(CodexDelivery.turn(in: turns, clientUserMessageId: "ks-3") == nil)
        #expect(CodexDelivery.placement(in: turns, clientUserMessageId: "ks-2").map { [$0.turn, String($0.position)] } == ["turn-2", "1"])
        #expect(CodexDelivery.placement(in: turns, clientUserMessageId: "ks-1").map { [$0.turn, String($0.position)] } == ["turn-1", "0"])
        #expect(CodexDelivery.placement(in: turns, clientUserMessageId: "ks-3") == nil)
    }

    @Test func theAgentsLastWordsAreItsLatestMessageInTheNewestTurn() {
        #expect(CodexDelivery.lastAgentWords(data(turnsList)) == "ok")
        let later = #"{"data":[{"id":"t","items":[{"type":"agentMessage","text":"first"},{"type":"commandExecution"},{"type":"agentMessage","text":"  then this  "}]}]}"#
        #expect(CodexDelivery.lastAgentWords(data(later)) == "then this")
        #expect(CodexDelivery.lastAgentWords(data(#"{"data":[{"id":"t","items":[{"type":"userMessage"}]}]}"#)) == nil)
        #expect(CodexDelivery.lastAgentWords(data(#"{"data":[]}"#)) == nil)
        #expect(CodexDelivery.lastAgentWords(data("nope")) == nil)
        let long = String(repeating: "a", count: CodexHookReport.detailLimit + 50)
        #expect(CodexDelivery.lastAgentWords(data(#"{"data":[{"id":"t","items":[{"type":"agentMessage","text":"\#(long)"}]}]}"#))?.count
            ?? 0 <= CodexHookReport.detailLimit + 1)
    }
}
