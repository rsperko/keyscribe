import Foundation
import KeyScribeKit
import Testing

struct CodexDaemonTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    private func object(_ data: Data) -> NSDictionary? {
        (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
    }

    private struct ReadParams: Encodable {
        var threadId: String
        var includeTurns: Bool
    }

    @Test func aRequestCarriesIdMethodAndParamsAndNoProtocolField() throws {
        let encoded = try CodexDaemon.request(id: 7, method: "thread/read", params: ReadParams(threadId: "t-1", includeTurns: false))
        #expect(object(encoded) == ["id": 7, "method": "thread/read", "params": ["threadId": "t-1", "includeTurns": false]] as NSDictionary)
    }

    @Test func theInitializedNotificationIsOnlyItsMethod() {
        #expect(object(CodexDaemon.initialized) == ["method": "initialized"] as NSDictionary)
    }

    @Test func aResponseKeepsItsResultForTheCallerToRead() {
        guard case .response(let id, let result) = CodexDaemon.decode(data(#"{"id":3,"result":{"data":["a"],"nextCursor":null}}"#)) else {
            Issue.record("not a response")
            return
        }
        #expect(id == 3)
        #expect(object(result) == ["data": ["a"], "nextCursor": NSNull()] as NSDictionary)
    }

    @Test func anErrorResponseKeepsCodeAndMessage() {
        #expect(CodexDaemon.decode(data(#"{"id":4,"error":{"code":-32600,"message":"bad"}}"#)) == .error(id: 4, code: -32600, message: "bad"))
        #expect(CodexDaemon.decode(data(#"{"id":4,"error":{}}"#)) == .error(id: 4, code: nil, message: nil))
        #expect(CodexDaemon.decode(data(#"{"id":null,"error":{"code":-32700,"message":"parse"}}"#)) == .error(id: nil, code: -32700, message: "parse"))
    }

    @Test func aRequestFromTheDaemonIsItsOwnCaseAndIsNotAResponse() {
        #expect(
            CodexDaemon.decode(data(#"{"id":9,"method":"item/tool/requestUserInput","params":{}}"#))
                == .serverRequest(id: .number(9), method: "item/tool/requestUserInput"))
        #expect(CodexDaemon.decode(data(#"{"id":"r-1","method":"x","params":{}}"#)) == .serverRequest(id: .text("r-1"), method: "x"))
    }

    @Test func statusChangesNameUpdatesStartsAndClosesAreRead() {
        #expect(
            CodexDaemon.decode(data(#"{"method":"thread/status/changed","params":{"threadId":"t-1","status":{"type":"active","activeFlags":["waitingOnApproval"]}}}"#))
                == .notification(.statusChanged(threadId: "t-1", status: .active([.waitingOnApproval]))))
        #expect(
            CodexDaemon.decode(data(#"{"method":"thread/name/updated","params":{"threadId":"t-1","threadName":"Fix the build"}}"#))
                == .notification(.nameUpdated(threadId: "t-1", name: "Fix the build")))
        #expect(CodexDaemon.decode(data(#"{"method":"thread/name/updated","params":{"threadId":"t-1"}}"#)) == .notification(.nameUpdated(threadId: "t-1", name: nil)))
        #expect(CodexDaemon.decode(data(#"{"method":"thread/closed","params":{"threadId":"t-1"}}"#)) == .notification(.closed(threadId: "t-1")))
        let started = #"{"method":"thread/started","params":{"thread":{"id":"t-2","cwd":"/src/app","ephemeral":false,"status":{"type":"idle"},"createdAt":1795015834}}}"#
        #expect(
            CodexDaemon.decode(data(started))
                == .notification(.started(CodexThread(id: "t-2", cwd: "/src/app", status: .idle, createdAt: 1795015834))))
    }

    @Test func anyOtherNotificationIsOtherAndAKnownOneWithBrokenParamsIsUnreadable() {
        #expect(CodexDaemon.decode(data(#"{"method":"item/agentMessage/delta","params":{"delta":"x"}}"#)) == .notification(.other(method: "item/agentMessage/delta")))
        #expect(CodexDaemon.decode(data(#"{"method":"thread/closed","params":{}}"#)) == .unreadable)
        #expect(CodexDaemon.decode(data(#"{"method":"thread/status/changed","params":{"threadId":"t-1"}}"#)) == .unreadable)
        #expect(CodexDaemon.decode(data(#"{"method":"thread/started","params":{"thread":{"id":"t-2"}}}"#)) == .unreadable)
    }

    @Test func anythingElseIsUnreadable() {
        #expect(CodexDaemon.decode(data("not json")) == .unreadable)
        #expect(CodexDaemon.decode(data("[]")) == .unreadable)
        #expect(CodexDaemon.decode(data(#"{"id":1}"#)) == .unreadable)
        #expect(CodexDaemon.decode(data(#"{"id":true,"result":{}}"#)) == .unreadable)
        #expect(CodexDaemon.decode(data(#"{"id":1.5,"result":{}}"#)) == .unreadable)
    }

    @Test func theLoadedListGivesIdsAndTheNextPage() {
        #expect(CodexDaemon.loadedThreads(data(#"{"data":["a","b"],"nextCursor":"c2"}"#)).map { [$0.ids, [$0.nextCursor ?? "-"]] } == [["a", "b"], ["c2"]])
        #expect(CodexDaemon.loadedThreads(data(#"{"data":[],"nextCursor":null}"#)).map { [$0.ids, [$0.nextCursor ?? "-"]] } == [[], ["-"]])
        #expect(CodexDaemon.loadedThreads(data(#"{"data":[1]}"#)) == nil)
        #expect(CodexDaemon.loadedThreads(data(#"{"nextCursor":null}"#)) == nil)
    }
}
