import Foundation
import KeyScribeKit
import Testing

struct OpencodeSessionsTests {
    let service = "http://127.0.0.1:49374"

    func list(_ sessions: String) -> Data { Data(#"{"data":[\#(sessions)],"cursor":{}}"#.utf8) }

    let pong = #"""
        {"id":"ses_pong","projectID":"p1","title":"Pong response request","outcome":"succeeded",
         "time":{"created":1795104277032,"updated":1795104291111,"busy":1795104277060,"idle":1795104279713},
         "location":{"directory":"/work/demo"}}
        """#

    @Test func aListedSessionGivesItsIdTitleFolderAndStart() throws {
        let sessions = try #require(OpencodeSessions.parse(list(pong)))
        #expect(sessions == [
            OpencodeSession(id: "ses_pong", title: "Pong response request", directory: "/work/demo", createdAt: 1795104277032),
        ])
    }

    @Test func childArchivedAndUnplacedSessionsAreLeftOut() throws {
        let child = #"{"id":"ses_c","parentID":"ses_pong","projectID":"p","time":{"created":1,"updated":1},"location":{"directory":"/w"}}"#
        let archived = #"{"id":"ses_a","projectID":"p","time":{"created":1,"updated":1,"archived":2},"location":{"directory":"/w"}}"#
        let nowhere = #"{"id":"ses_n","projectID":"p","time":{"created":1,"updated":1},"location":{}}"#
        let sessions = try #require(OpencodeSessions.parse(list([pong, child, archived, nowhere].joined(separator: ","))))
        #expect(sessions.map(\.id) == ["ses_pong"])
    }

    @Test func anUnreadableListIsNotAnEmptyOne() {
        #expect(OpencodeSessions.parse(Data("oops".utf8)) == nil)
        #expect(OpencodeSessions.parse(Data(#"{"error":"x"}"#.utf8)) == nil)
        #expect(OpencodeSessions.parse(list("")) == [])
    }

    @Test func theActiveMapNamesTheRunningSessions() {
        let active = Data(#"{"data":{"ses_a":{"type":"running"},"ses_b":{"type":"retry"}}}"#.utf8)
        #expect(OpencodeSessions.active(active) == ["ses_a", "ses_b"])
        #expect(OpencodeSessions.active(Data(#"{"data":{}}"#.utf8)) == [])
        #expect(OpencodeSessions.active(Data("x".utf8)) == nil)
    }

    @Test func aSessionIsWorkingWhileRunningAndWaitingWhileItAsks() {
        let session = OpencodeSession(id: "ses_pong", title: "T", directory: "/work/demo", createdAt: 5)
        let idle = session.agentSession(instance: service, running: false, asking: nil)
        #expect(idle.state == .idle)
        #expect(idle.agent == "opencode")
        #expect(idle.id == "ses_pong")
        #expect(idle.cwd == "/work/demo")
        #expect(idle.startedAt == 5)
        #expect(idle.host == AgentHostLocation(host: "opencode", instance: service, native: "ses_pong"))
        #expect(session.agentSession(instance: service, running: true, asking: nil).state == .working)
        #expect(session.agentSession(instance: service, running: true, asking: AgentPrompt(kind: "confirm")).state == .waitingApproval)
        #expect(session.agentSession(instance: service, running: true, asking: AgentPrompt(kind: "select")).state == .waitingQuestion)
    }

    @Test func aBlankTitleIsNoTitle() {
        #expect(OpencodeSession(id: "s", title: "  ", directory: "/w", createdAt: nil).shownTitle == nil)
        #expect(OpencodeSession(id: "s", title: " Fix it ", directory: "/w", createdAt: nil).shownTitle == "Fix it")
    }
}
