import Foundation
import KeyScribeKit
import Testing

struct CodexThreadTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    private let readResult = #"""
        {"thread": {"id": "01a1ef47-fd49-7a13-9b70-f7b2e7fbf8c3", "environments": [{"environmentId": "local", "cwd": "/src/project",
         "runtimeWorkspaceRoots": ["/src/project"]}], "extra": null, "sessionId": "01a1ef47-fd49-7a13-9b70-f7b2e7fbf8c3", "forkedFromId": null,
         "attachedToThreadId": null, "parentThreadId": null, "preview": "I want to add a greeting file.", "ephemeral": false, "section": null,
         "sectionEnteredAt": null, "projectId": null, "historyMode": "paginated", "modelProvider": "openai", "model": "gpt-6-luna",
         "reasoningEffort": "medium", "createdAt": 1795015834, "updatedAt": 1795015884, "recencyAt": 1795015880, "status": {"type": "idle"},
         "path": null, "cwd": "/src/project", "cliVersion": "0.170.0", "originator": "codex-tui", "source": "vscode",
         "canAcceptDirectInput": true, "threadSource": "user", "agentNickname": null, "agentRole": null,
         "gitInfo": {"sha": "b3c9764", "branch": "main", "originUrl": null}, "name": "Ask greeting file language", "daybreakEnabled": null,
         "turns": []}, "readState": {"firstUnread": null, "revision": "aac44e4e"}}
        """#

    private func thread(_ fields: String) -> CodexThread? {
        CodexDaemon.thread(data(#"{"thread":{"# + fields + "}}"))
    }

    @Test func aReadThreadKeepsWhatKeyScribeUsesAndIgnoresTheRest() {
        #expect(
            CodexDaemon.thread(data(readResult))
                == CodexThread(
                    id: "01a1ef47-fd49-7a13-9b70-f7b2e7fbf8c3", cwd: "/src/project", name: "Ask greeting file language", ephemeral: false,
                    threadSource: "user", status: .idle, createdAt: 1795015834))
    }

    @Test func forksAndSubagentsKeepWhereTheyCameFrom() {
        let read = thread(#""id":"t-2","cwd":"/a","status":{"type":"idle"},"forkedFromId":"t-1","parentThreadId":"t-0""#)
        #expect(read?.forkedFromId == "t-1")
        #expect(read?.parentThreadId == "t-0")
    }

    @Test func missingOptionalsAreTolerated() {
        #expect(thread(#""id":"t-1","cwd":"/a","status":{"type":"idle"}"#) == CodexThread(id: "t-1", cwd: "/a", status: .idle))
        #expect(thread(#""id":"t-1","cwd":"/a","status":{"type":"idle"},"createdAt":1.5"#)?.createdAt == nil)
    }

    @Test func aThreadWithoutIdOrFolderIsUnreadable() {
        #expect(thread(#""cwd":"/a","status":{"type":"idle"}"#) == nil)
        #expect(thread(#""id":"t-1","status":{"type":"idle"}"#) == nil)
        #expect(CodexDaemon.thread(data(#"{"readState":null}"#)) == nil)
        #expect(CodexDaemon.thread(data("garbage")) == nil)
    }

    @Test func statusesAreReadAndAnUnlistedStatusOrFlagIsKept() {
        func status(_ json: String) -> CodexThreadStatus? { thread(#""id":"t","cwd":"/a","status":"# + json)?.status }
        #expect(status(#"{"type":"notLoaded"}"#) == .notLoaded)
        #expect(status(#"{"type":"idle"}"#) == .idle)
        #expect(status(#"{"type":"systemError"}"#) == .systemError)
        #expect(status(#"{"type":"active","activeFlags":[]}"#) == .active([]))
        #expect(status(#"{"type":"active","activeFlags":["waitingOnApproval","waitingOnUserInput","waitingOnSomethingNew"]}"#)
            == .active([.waitingOnApproval, .waitingOnUserInput, .unknown("waitingOnSomethingNew")]))
        #expect(status(#"{"type":"compacting"}"#) == .unknown("compacting"))
        #expect(thread(#""id":"t","cwd":"/a""#)?.status == .unknown(""))
    }

    @Test func statusesMapToLiveStatesAndNothingUnknownReadsAsIdle() {
        #expect(CodexThreadStatus.idle.liveState == .idle)
        #expect(CodexThreadStatus.active([]).liveState == .working)
        #expect(CodexThreadStatus.active([.waitingOnApproval]).liveState == .waitingApproval)
        #expect(CodexThreadStatus.active([.waitingOnUserInput]).liveState == .waitingQuestion)
        #expect(CodexThreadStatus.active([.waitingOnApproval, .unknown("new")]).liveState == .userDialog)
        #expect(CodexThreadStatus.systemError.liveState == .userDialog)
        #expect(CodexThreadStatus.unknown("compacting").liveState == .userDialog)
        #expect(CodexThreadStatus.notLoaded.liveState == nil)
    }

    @Test func onlyLoadedLastingThreadsTheUserStartedAreListed() {
        #expect(CodexThread(id: "t", cwd: "/a", status: .idle).isListed)
        #expect(CodexThread(id: "t", cwd: "/a", threadSource: "user", status: .active([])).isListed)
        #expect(CodexThread(id: "t", cwd: "/a", status: .unknown("x")).isListed)
        #expect(!CodexThread(id: "t", cwd: "/a", status: .notLoaded).isListed)
        #expect(!CodexThread(id: "t", cwd: "/a", ephemeral: true, threadSource: "thread_title", status: .idle).isListed)
        #expect(!CodexThread(id: "t", cwd: "/a", ephemeral: true, status: .idle).isListed)
        #expect(!CodexThread(id: "t", cwd: "/a", threadSource: "subagent", status: .idle).isListed)
    }

    @Test func aListedThreadBecomesASessionAtItsCodexHomeAndItsNameIsOnlyATitle() {
        let read = CodexThread(id: "t-1", cwd: "/src/app", name: " Fix the build ", status: .active([.waitingOnUserInput]), createdAt: 1795015834)
        #expect(
            read.session(instance: "/home/.codex")
                == AgentSession(
                    agent: "codex", id: "t-1", pid: nil, cwd: "/src/app", state: .waitingQuestion, startedAt: 1795015834,
                    host: AgentHostLocation(host: "codex", instance: "/home/.codex", native: "t-1")))
        #expect(read.session(instance: "/home/.codex")?.explicitName == nil)
        #expect(read.title == "Fix the build")
        #expect(CodexThread(id: "t", cwd: "/a", name: "  ", status: .idle).title == nil)
        #expect(CodexThread(id: "t", cwd: "/a", status: .notLoaded).session(instance: "/home/.codex") == nil)
        #expect(CodexThread(id: "t", cwd: "/a", ephemeral: true, threadSource: "thread_title", status: .idle).session(instance: "/h") == nil)
    }
}
