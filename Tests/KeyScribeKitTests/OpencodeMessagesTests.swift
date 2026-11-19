import Foundation
import KeyScribeKit
import Testing

struct OpencodeMessagesTests {
    func newestFirst(_ messages: String) -> Data { Data(#"{"data":[\#(messages)]}"#.utf8) }

    let ended = #"{"id":"msg_i","type":"idle","outcome":"succeeded"}"#
    let reply = #"""
        {"id":"msg_a","type":"assistant","content":[{"type":"reasoning","text":"thinking"},{"type":"text","text":"first part"},{"type":"tool"},{"type":"text","text":"after"}]}
        """#
    let asked = #"{"id":"msg_keyscribe1","type":"user","text":"do it"}"#

    @Test func aTurnThatEndedGivesItsOutcomeAndLastText() {
        #expect(OpencodeMessages.lastTurn(newestFirst([ended, reply, asked].joined(separator: ","))) == OpencodeTurnEnd(reason: "complete", answer: "after"))
    }

    @Test func anInterruptedOrFailedTurnHasNoAnswer() {
        let interrupted = #"{"id":"msg_i","type":"idle","outcome":"interrupted"}"#
        let failed = #"{"id":"msg_i","type":"idle","outcome":"failed"}"#
        #expect(OpencodeMessages.lastTurn(newestFirst([interrupted, reply].joined(separator: ","))) == OpencodeTurnEnd(reason: "aborted", answer: ""))
        #expect(OpencodeMessages.lastTurn(newestFirst([failed, reply].joined(separator: ","))) == OpencodeTurnEnd(reason: "error", answer: ""))
    }

    @Test func aTurnStillRunningHasNotEnded() {
        #expect(OpencodeMessages.lastTurn(newestFirst([reply, asked].joined(separator: ","))) == nil)
        #expect(OpencodeMessages.lastTurn(newestFirst(asked)) == nil)
    }

    @Test func aReplyFromAnEarlierTurnIsNeverThisTurnsAnswer() {
        let older = #"{"id":"msg_o","type":"assistant","content":[{"type":"text","text":"old"}]}"#
        #expect(OpencodeMessages.lastTurn(newestFirst([ended, asked, older].joined(separator: ","))) == OpencodeTurnEnd(reason: "complete", answer: ""))
    }

    @Test func anUnreadableListIsUnknown() {
        #expect(OpencodeMessages.lastTurn(Data("x".utf8)) == nil)
        #expect(OpencodeMessages.lastTurn(newestFirst("")) == nil)
    }

    @Test func aLongAnswerIsCutToTheReplyLimit() {
        let long = String(repeating: "b", count: OpencodeTurns.answerLimit + 10)
        let reply = #"{"id":"msg_a","type":"assistant","content":[{"type":"text","text":"\#(long)"}]}"#
        #expect(OpencodeMessages.lastTurn(newestFirst([ended, reply].joined(separator: ",")))?.answer.count == OpencodeTurns.answerLimit)
    }

    @Test func ourOwnMessageIsFoundByItsId() {
        let found = Data(#"{"data":{"id":"msg_keyscribe1","type":"user","text":"do it"}}"#.utf8)
        #expect(OpencodeMessages.isMessage(found, id: "msg_keyscribe1"))
        #expect(!OpencodeMessages.isMessage(Data(#"{"_tag":"MessageNotFoundError"}"#.utf8), id: "msg_keyscribe1"))
        #expect(!OpencodeMessages.isMessage(found, id: "msg_other"))
    }

    @Test func aRequestBecomesAMessageIdOpencodeAccepts() {
        #expect(OpencodeMessages.messageId(request: "2F6A-77") == "msg_keyscribe_2F6A-77")
        #expect(OpencodeMessages.messageId(request: "a b/c") == "msg_keyscribe_abc")
    }
}
