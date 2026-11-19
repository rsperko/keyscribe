import Foundation
import KeyScribeKit
import Testing

struct CodexHookReportTests {
    private let instance = "/home/.codex"
    private let sessionId = "01a1ef41-5fd4-7f81-a216-ebcfb6f18f84"
    private var session: String { AgentHostLocation(host: "codex", instance: instance, native: sessionId).conversationKey }

    private func events(_ json: String) -> [AgentEvent]? { CodexHookReport.events(Data(json.utf8), instance: instance) }

    private func hook(_ name: String, _ fields: String = "") -> String {
        """
        {"session_id":"\(sessionId)","turn_id":"01a1ef41-68df-7cf0-a907-99c4cddf9cc1","transcript_path":"/tmp/rollout.jsonl",
         "cwd":"/src/project","hook_event_name":"\(name)","model":"gpt-6.2-sol","permission_mode":"default"\(fields.isEmpty ? "" : "," + fields)}
        """
    }

    @Test func aSubmittedPromptStartsATurnCarryingItsDigest() {
        let prompt = "Tell me out loud when you are done. How many lines are in README.md?"
        #expect(
            events(hook("UserPromptSubmit", #""prompt":"\#(prompt)""#))
                == [.turnStarted(session: session, turn: "01a1ef41-68df-7cf0-a907-99c4cddf9cc1", prompt: AgentPromptDigest.of(prompt))])
        #expect(events(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","prompt":"x"}"#) == nil)
    }

    @Test func stopCompletesTheTurnWithTheLastAnswer() {
        #expect(
            events(hook("Stop", #""stop_hook_active":false,"last_assistant_message":"`README.md` has 1 line.""#))
                == [.turnComplete(session: session, reason: "complete", answer: "`README.md` has 1 line.", turn: "01a1ef41-68df-7cf0-a907-99c4cddf9cc1")])
        #expect(events(hook("Stop", #""last_assistant_message":null"#)) == [.turnComplete(session: session, reason: "complete", answer: "", turn: "01a1ef41-68df-7cf0-a907-99c4cddf9cc1")])
        #expect(events(hook("Stop")) == [.turnComplete(session: session, reason: "complete", answer: "", turn: "01a1ef41-68df-7cf0-a907-99c4cddf9cc1")])
    }

    @Test func anInterruptEndsTheTurnAsAborted() {
        #expect(events(hook("Interrupt")) == [.turnComplete(session: session, reason: "aborted", answer: "", turn: "01a1ef41-68df-7cf0-a907-99c4cddf9cc1")])
    }

    @Test func aPermissionRequestWaitsOnAConfirmNamingTheToolAndItsCommand() {
        let request = hook("PermissionRequest", #""tool_name":"Bash","tool_input":{"command":"/usr/bin/say 'Done.'","description":"May I?"}"#)
        #expect(events(request) == [.waiting(session: session, prompt: AgentPrompt(kind: "confirm", tool: "Bash", detail: "/usr/bin/say 'Done.'"))])
        let patch = hook("PermissionRequest", #""tool_name":"apply_patch","tool_input":{"patch":"x"}"#)
        #expect(events(patch) == [.waiting(session: session, prompt: AgentPrompt(kind: "confirm", tool: "apply_patch"))])
        #expect(events(hook("PermissionRequest")) == [.waiting(session: session, prompt: AgentPrompt(kind: "confirm"))])
    }

    @Test func aLongCommandIsCappedAndBlankOnesDropped() {
        let long = String(repeating: "a", count: 1500)
        let report = events(hook("PermissionRequest", #""tool_name":"Bash","tool_input":{"command":"  \#(long)  "}"#))
        #expect(report == [.waiting(session: session, prompt: AgentPrompt(kind: "confirm", tool: "Bash", detail: String(repeating: "a", count: 1000)))])
        #expect(
            events(hook("PermissionRequest", #""tool_name":"  ","tool_input":{"command":"   "}"#))
                == [.waiting(session: session, prompt: AgentPrompt(kind: "confirm"))])
    }

    @Test func askingTheUserWaitsOnASelectTitledByTheFirstQuestion() {
        let questions = #""tool_name":"request_user_input","tool_input":{"questions":[{"id":"lang","header":"Language","question":"Which language?"},{"question":"Second?"}]}"#
        #expect(events(hook("PreToolUse", questions)) == [.waiting(session: session, prompt: AgentPrompt(kind: "select", title: "Which language?"))])
        let single = #""tool_name":"request_user_input","tool_input":{"question":"Proceed?"}"#
        #expect(events(hook("PreToolUse", single)) == [.waiting(session: session, prompt: AgentPrompt(kind: "select", title: "Proceed?"))])
        let bare = #""tool_name":"request_user_input","tool_input":{"questions":["Plain?"]}"#
        #expect(events(hook("PreToolUse", bare)) == [.waiting(session: session, prompt: AgentPrompt(kind: "select", title: "Plain?"))])
        let odd = #""tool_name":"request_user_input","tool_input":{"questions":7}"#
        #expect(events(hook("PreToolUse", odd)) == [.waiting(session: session, prompt: AgentPrompt(kind: "select"))])
        #expect(events(hook("PreToolUse", #""tool_name":"request_user_input""#)) == [.waiting(session: session, prompt: AgentPrompt(kind: "select"))])
    }

    @Test func anyOtherToolUseReportsNothing() {
        #expect(events(hook("PreToolUse", #""tool_name":"Bash","tool_input":{"command":"ls"}"#)) == [])
    }

    @Test func keyScribesOwnToolTurnsOnTheTurnsSpokenResult() {
        let notify = #"{"hook_event_name":"KeyScribeNotify","session_id":"\#(sessionId)","turn_id":"01a1ef40-90d9"}"#
        #expect(events(notify) == [.notify(session: session, turn: "01a1ef40-90d9", on: true)])
        #expect(events(#"{"hook_event_name":"KeyScribeNotify","session_id":"\#(sessionId)"}"#) == nil)
    }

    @Test func aSessionStartAndAnUnknownEventReportNothing() {
        #expect(events(hook("SessionStart", #""source":"startup""#)) == [])
        #expect(events(hook("PostToolUse")) == [])
        #expect(events(#"{"hook_event_name":"SomethingNew"}"#) == [])
    }

    @Test func aBodyThatIsNotAHookIsMalformed() {
        #expect(events("not json") == nil)
        #expect(events("[]") == nil)
        #expect(events(#"{"session_id":"s"}"#) == nil)
        #expect(events(#"{"hook_event_name":7,"session_id":"s"}"#) == nil)
        #expect(events(#"{"hook_event_name":"Stop"}"#) == nil)
        #expect(events(#"{"hook_event_name":"SessionStart"}"#) == nil)
        #expect(events(#"{"hook_event_name":"Stop","session_id":""}"#) == nil)
    }

    @Test func theSessionIsTheNativeIdAtThisCodexHome() {
        let other = CodexHookReport.events(Data(hook("Interrupt").utf8), instance: "/other/.codex")
        #expect(other == [.turnComplete(session: "\(sessionId)@/other/.codex", reason: "aborted", answer: "", turn: "01a1ef41-68df-7cf0-a907-99c4cddf9cc1")])
    }
}
