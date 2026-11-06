import Foundation
import Testing
@testable import KeyScribeKit

struct ClaudeRegistryTests {
    private func entry(_ json: String) -> ClaudeRegistryEntry? {
        ClaudeRegistryEntry.decode(Data(json.utf8))
    }

    @Test func aRecordIsInteractiveOtherOrInvalid() {
        let interactive = #"{"pid":1,"sessionId":"s","cwd":"/p","kind":"interactive","status":"idle"}"#
        #expect(ClaudeRegistryEntry.read(Data(interactive.utf8)) == .interactive(ClaudeRegistryEntry(pid: 1, sessionId: "s", cwd: "/p", name: nil, status: "idle", waitingFor: nil)))
        #expect(ClaudeRegistryEntry.read(Data(#"{"pid":1,"sessionId":"s","cwd":"/p","kind":"sdk"}"#.utf8)) == .other)
        #expect(ClaudeRegistryEntry.read(Data(#"{"pid":1,"kind":"interactive"}"#.utf8)) == .invalid)
        #expect(ClaudeRegistryEntry.read(Data(#"{"pid":1,"sess"#.utf8)) == .invalid)
        #expect(ClaudeRegistryEntry.read(Data("{}".utf8)) == .invalid)
        #expect(ClaudeRegistryEntry.read(Data(#"{"pid":1,"sessionId":"s","cwd":"/p","kind":null}"#.utf8)) == .invalid)
        #expect(ClaudeRegistryEntry.read(Data(#"{"pid":1,"sessionId":"s","cwd":"/p","kind":""}"#.utf8)) == .invalid)
    }

    @Test func anInteractiveSessionDecodes() {
        let e = entry("""
        {"pid":6521,"sessionId":"f6569352","cwd":"/Users/me/src/keyscribe","kind":"interactive","name":"proj-claude-0e","nameSource":"derived","status":"busy","messagingSocketPath":"/tmp/cc-socks/6521.sock"}
        """)
        #expect(e == ClaudeRegistryEntry(pid: 6521, sessionId: "f6569352", cwd: "/Users/me/src/keyscribe", name: "proj-claude-0e", status: "busy", waitingFor: nil, nameSource: "derived"))
        #expect(e?.folder == "keyscribe")
    }

    @Test func theProcessStartTimeIsKeptToTellAReusedPidApart() {
        #expect(entry(#"{"pid":1,"sessionId":"a","cwd":"/src/api","kind":"interactive","startedAt":1793454517559}"#)?.startedAt == 1793454517559)
        #expect(entry(#"{"pid":1,"sessionId":"a","cwd":"/src/api","kind":"interactive"}"#)?.startedAt == nil)
    }

    @Test(arguments: ["user", "derived", "auto", "unknown"])
    func onlyUserNamesAreExplicit(source: String) {
        let e = entry(#"{"pid":1,"sessionId":"a","cwd":"/src/api","kind":"interactive","name":"Fix authentication retries","nameSource":"\#(source)"}"#)
        #expect(e?.explicitName == (source == "user" ? "Fix authentication retries" : nil))
        #expect(entry(#"{"pid":1,"sessionId":"a","cwd":"/src/api","kind":"interactive","name":"Unclassified"}"#)?.explicitName == nil)
    }

    @Test func nonInteractiveOrIncompleteEntriesAreIgnored() {
        #expect(entry(#"{"pid":1,"sessionId":"a","cwd":"/x","kind":"sdk","status":"idle"}"#) == nil)
        #expect(entry(#"{"pid":1,"cwd":"/x","kind":"interactive","status":"idle"}"#) == nil)
        #expect(entry("not json") == nil)
    }

    @Test(arguments: [
        ("idle", nil as String?, AgentLiveState.idle),
        ("busy", nil, .working),
        ("shell", nil, .working),
        ("waiting", "permission prompt", .waitingApproval),
        ("waiting", "input needed", .waitingQuestion),
        ("waiting", "dialog open", .userDialog),
        ("waiting", "sandbox request", .waitingApproval),
        ("waiting", "something new", .userDialog),
        ("brand-new-status", nil, .working),
    ])
    func statusMapsToALiveState(status: String, waitingFor: String?, expected: AgentLiveState) {
        let e = ClaudeRegistryEntry(pid: 1, sessionId: "s", cwd: "/p", name: nil, status: status, waitingFor: waitingFor)
        #expect(e.liveState == expected)
    }
}
