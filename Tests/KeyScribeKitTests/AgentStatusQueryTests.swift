import Testing
@testable import KeyScribeKit

struct AgentStatusQueryTests {
    let names = ["architect", "backend", "the big one", "tests"]

    func query(_ text: String) -> AgentStatusQuery? {
        AgentStatusQuery.parse(text, names: names)
    }

    @Test(arguments: [
        ("check on architect", AgentAddress.name("architect", body: "")),
        ("Check on Architect.", .name("architect", body: "")),
        ("Please check on backend", .name("backend", body: "")),
        ("check on backend, please", .name("backend", body: "")),
        ("check on conversation two", .row(2, body: "")),
        ("Check on session 2?", .row(2, body: "")),
        ("check on the big one", .name("the big one", body: "")),
        ("check on archetect", .nearMiss(spoken: "archetect", name: "architect", body: "", unaddressed: nil)),
        ("check on tests", .name("tests", body: "")),
        ("check on the architect", .name("architect", body: "")),
        ("Okay, check on backend.", .name("backend", body: "")),
        ("So check on backend", .name("backend", body: "")),
        ("hey check on architect please", .name("architect", body: "")),
    ])
    func checkOnANamedConversation(text: String, address: AgentAddress) {
        #expect(query(text) == .check(address))
    }

    @Test(arguments: ["check on this conversation", "Check on this session.", "please check on this conversation"])
    func checkOnThisConversationChecksTheTakesRecipient(text: String) {
        #expect(query(text) == .check(nil))
    }

    @Test(arguments: ["check on all conversations", "Check on all sessions.", "Who needs me?", "who needs me please"])
    func checkOnAllConversations(text: String) {
        #expect(query(text) == .all)
    }

    @Test(arguments: [
        ("check on frontend", "frontend"),
        ("check on the CI run", "the ci run"),
        ("check on conversation nine", "conversation nine"),
    ])
    func checkOnSomethingThatIsNoConversationIsStillAStatusCheck(text: String, spoken: String) throws {
        let query = try #require(query(text))
        guard case .check(let address?) = query else { Issue.record("\(query)"); return }
        switch address {
        case .unresolved(let heard, ""): #expect(heard == spoken)
        case .row(9, ""): #expect(spoken == "conversation nine")
        default: Issue.record("\(address)")
        }
    }

    @Test(arguments: [
        "Do you need anything from me?",
        "What are you waiting for?",
        "what do you need from me",
        "What is architect waiting for?",
        "What does backend need from me?",
        "Why is backend stuck?",
        "What's blocking architect?",
        "What does backend need from me before we merge?",
        "Who's stuck?",
        "Is anyone waiting for me?",
        "What is everyone waiting for?",
        "tell architect check on backend",
        "ask architect to check on backend",
        "Before making changes, check on backend and explain what it needs.",
        "check on backend and then run the tests",
        "check on the deploy before we merge today",
        "check on",
        "check",
        "",
    ])
    func everythingElseIsAMessage(text: String) {
        #expect(query(text) == nil)
    }

    @Test func anUnknownTargetNoLongerThanANameIsStillAStatusCheck() {
        let longest = Array(repeating: "word", count: AgentRename.nameWords).joined(separator: " ")
        #expect(query("check on \(longest)") == .check(.unresolved(spoken: longest, body: "")))
        #expect(query("check on \(longest) more") == nil)
    }

    @Test func withoutKnownNamesANameIsUnresolvedAndANumberStillWorks() {
        #expect(AgentStatusQuery.parse("check on architect", names: [], namesKnown: false) == .check(.unresolved(spoken: "architect", body: "")))
        #expect(AgentStatusQuery.parse("check on session two", names: [], namesKnown: false) == .check(.row(2, body: "")))
        #expect(AgentStatusQuery.parse("check on this conversation", names: [], namesKnown: false) == .check(nil))
    }

    @Test func aNameReachableOnlyAfterAVerbIsReachedAfterCheckOn() {
        #expect(AgentStatusQuery.parse("check on review the auth flow", names: ["backend"], afterVerb: ["review the auth flow"])
            == .check(.name("review the auth flow", body: "")))
    }
}

struct AgentStatusAnswerTests {
    private func status(
        _ state: AgentLiveState, connected: Bool = true, current: Bool = true, prompt: AgentPrompt? = nil, description: String? = nil
    ) -> String {
        AgentStatusAnswer.status(handle: "architect", state: state, connected: connected, current: current, prompt: prompt, description: description)
    }

    @Test(arguments: [
        (AgentLiveState.idle, "Status for architect: idle. No pending input request is reported. Nothing sent."),
        (.working, "Status for architect: working. No pending input request is reported. Nothing sent."),
        (.waitingApproval, "Status for architect: waiting for approval. Nothing sent."),
        (.waitingQuestion, "Status for architect: waiting for an answer. Nothing sent."),
        (.userDialog, "Status for architect: a dialog is open. Nothing sent."),
    ])
    func theStateAloneSaysOnlyWhatIsReported(state: AgentLiveState, line: String) {
        #expect(status(state) == line)
    }

    @Test func everyAnswerSaysItIsAStatusCheckAndThatNothingWasSent() {
        let states: [AgentLiveState] = [.idle, .working, .waitingApproval, .waitingQuestion, .userDialog, .disconnected]
        for state in states {
            for (connected, current) in [(true, true), (true, false), (false, true)] {
                let line = status(state, connected: connected, current: current)
                #expect(line.hasPrefix("Status for architect: "))
                #expect(line.hasSuffix(" Nothing sent."))
                #expect(!line.contains("ready for another message"))
                #expect(!line.contains("isn\u{2019}t waiting"))
            }
        }
    }

    @Test(arguments: [
        (AgentLiveState.waitingApproval, "Status for architect: last seen waiting for approval. Its current status is unavailable. Nothing sent."),
        (.working, "Status for architect: last seen working. Its current status is unavailable. Nothing sent."),
        (.idle, "Status for architect: last seen idle. Its current status is unavailable. Nothing sent."),
    ])
    func aStateCarriedFromAnEarlierCheckIsLastReported(state: AgentLiveState, line: String) {
        #expect(status(state, current: false, prompt: AgentPrompt(title: "Keep the schema?"), description: "Asks.") == line)
        #expect(AgentStatusAnswer.hint(handle: "architect", state: state, connected: true, current: false) == nil)
    }

    @Test func onlyAConnectedConversationWaitingOnTheUserGetsTheOpenHint() {
        #expect(AgentStatusAnswer.hint(handle: "Architect", state: .waitingApproval, connected: true, current: true) == "Say \u{201C}open Architect\u{201D} to see it.")
        #expect(AgentStatusAnswer.hint(handle: "Architect", state: .waitingApproval, connected: false, current: true) == nil)
        #expect(AgentStatusAnswer.hint(handle: "Architect", state: .working, connected: true, current: true) == nil)
    }

    @Test func aQuestionReadAsAskedHidesWhatRedactionHides() {
        let prompt = AgentPrompt(title: "Use the key sk-abcdefghijklmnopqrstuvwxyz1234 for staging?")
        #expect(AgentStatusAnswer.question(in: prompt) == "Use the key a hidden value for staging?")
    }

    @Test func theActualQuestionWinsOverADescription() {
        let prompt = AgentPrompt(kind: "select", title: "Keep the existing schema or add a migration?")
        #expect(AgentStatusAnswer.question(in: prompt) == "Keep the existing schema or add a migration?")
        #expect(status(.userDialog, prompt: prompt, description: "Asks something else.")
            == "Status for architect: waiting for your answer to \u{201C}Keep the existing schema or add a migration?\u{201D} Nothing sent.")
    }

    @Test func aQuestionWithoutClosingPunctuationStillEndsItsSentence() {
        #expect(status(.waitingQuestion, prompt: AgentPrompt(title: "Pick a branch"))
            == "Status for architect: waiting for your answer to \u{201C}Pick a branch\u{201D}. Nothing sent.")
    }

    @Test func aDescriptionIsUsedWhenThereIsNoUsableQuestion() {
        let prompt = AgentPrompt(kind: "confirm", tool: "bash", detail: "git push origin main")
        #expect(AgentStatusAnswer.question(in: prompt) == nil)
        #expect(status(.userDialog, prompt: prompt, description: "Asks whether to allow pushing to main.")
            == "Status for architect: Asks whether to allow pushing to main. Nothing sent.")
    }

    @Test func aLongTitleIsNotReadAsTheQuestion() {
        let title = Array(repeating: "word", count: AgentStatusAnswer.questionWordLimit + 1).joined(separator: " ")
        #expect(AgentStatusAnswer.question(in: AgentPrompt(title: title)) == nil)
        #expect(AgentStatusAnswer.question(in: AgentPrompt(title: "   ")) == nil)
    }

    @Test func aConversationThatIsNotConnectedHasNoCurrentStatus() {
        #expect(status(.waitingApproval, connected: false)
            == "Status for architect: not connected. Its current status is unavailable. Last seen waiting for approval. Nothing sent.")
        #expect(status(.disconnected) == "Status for architect: not connected. Its current status is unavailable. Nothing sent.")
        #expect(status(.working, connected: false)
            == "Status for architect: not connected. Its current status is unavailable. Last seen working. Nothing sent.")
    }

    @Test(arguments: [
        ([String](), true, "Status for all conversations: no pending input requests are reported. Nothing sent."),
        ([], false, "Status for all conversations: no pending input requests are reported, but some conversations couldn\u{2019}t be checked. Nothing sent."),
        (["Architect"], true, "Status for all conversations: one needs you: Architect. Nothing sent."),
        (["Architect", "Backend"], true, "Status for all conversations: two need you: Architect and Backend. Nothing sent."),
        (["A", "B", "C"], true, "Status for all conversations: three need you: A, B and C. Nothing sent."),
        (["Architect"], false, "Status for all conversations: one needs you: Architect. Some conversations couldn\u{2019}t be checked. Nothing sent."),
    ])
    func allConversationsCountsThenNames(handles: [String], complete: Bool, line: String) {
        #expect(AgentStatusAnswer.all(handles, complete: complete) == line)
    }
}
