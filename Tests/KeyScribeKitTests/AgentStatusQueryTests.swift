import Testing
@testable import KeyScribeKit

struct AgentStatusQueryTests {
    let names = ["architect", "backend", "the big one"]

    func query(_ text: String) -> AgentStatusQuery? {
        AgentStatusQuery.parse(text, names: names)
    }

    @Test(arguments: [
        ("What is architect waiting for?", AgentAddress.name("architect", body: "")),
        ("what's architect waiting for from me", .name("architect", body: "")),
        ("What’s the architect waiting on?", .name("architect", body: "")),
        ("What does Architect need from me?", .name("architect", body: "")),
        ("what does backend want", .name("backend", body: "")),
        ("Ask the architect what it is waiting for from me.", .name("architect", body: "")),
        ("ask architect what it's waiting for", .name("architect", body: "")),
        ("Ask backend what it needs from me, please.", .name("backend", body: "")),
        ("Please ask Architect what it wants.", .name("architect", body: "")),
        ("Is backend waiting for me?", .name("backend", body: "")),
        ("What is session two waiting for?", .row(2, body: "")),
        ("What does the big one need?", .name("the big one", body: "")),
        ("What is archetect waiting for?", .nearMiss(spoken: "archetect", name: "architect", body: "", unaddressed: nil)),
        ("What is architect waiting for right now?", .name("architect", body: "")),
        ("what is architect currently waiting for", .name("architect", body: "")),
        ("What is architect blocked on?", .name("architect", body: "")),
        ("Does architect need anything from me?", .name("architect", body: "")),
        ("Ask the architect what is it waiting for?", .name("architect", body: "")),
        ("Is architect still waiting for me?", .name("architect", body: "")),
        ("Hey, what does architect need from me?", .name("architect", body: "")),
        ("Okay so what is architect waiting for", .name("architect", body: "")),
        ("Why is architect waiting?", .name("architect", body: "")),
        ("why is architect stuck", .name("architect", body: "")),
        ("What's blocking architect?", .name("architect", body: "")),
    ])
    func aWaitingQuestionAboutANamedConversation(text: String, address: AgentAddress) {
        #expect(query(text) == .waiting(address))
    }

    @Test(arguments: [
        "What are you waiting for?",
        "what do you need from me",
        "What is it waiting for?",
        "Are you waiting for me?",
        "What do you want?",
    ])
    func aWaitingQuestionWithoutANameAsksTheTakesRecipient(text: String) {
        #expect(query(text) == .waiting(nil))
    }

    @Test(arguments: ["Who needs me?", "who's waiting for me", "Which conversations are waiting?", "which sessions are waiting for me", "who needs me right now", "Is anyone waiting for me?", "who is blocked", "Who's stuck?", "is anybody waiting", "What is everyone waiting for?"])
    func whoNeedsMe(text: String) {
        #expect(query(text) == .whoNeedsMe)
    }

    @Test(arguments: [
        "Ask architect what it needs, then review the changes.",
        "What is the build waiting for?",
        "What does the parser need to handle nested quotes?",
        "What does the parser need?",
        "Tell architect what it is waiting for from me",
        "Architect, what are you waiting for?",
        "What are you waiting for before merging?",
        "Ask architect to review the changes.",
        "What did I miss?",
        "Is the deploy waiting for review?",
        "",
    ])
    func anythingElseIsNotAStatusQuestion(text: String) {
        #expect(query(text) == nil)
    }

    @Test(arguments: [
        ("What does architect need from me to continue?", AgentAddress.name("architect", body: "")),
        ("what is architect waiting for before it merges", .name("architect", body: "")),
        ("Is session two waiting for the build?", .row(2, body: "")),
        ("Does backend need anything else from me?", .name("backend", body: "")),
        ("What is architect waiting for and what is backend waiting for?", .name("architect", body: "")),
        ("Why is architect waiting on the tests?", .name("architect", body: "")),
        ("What's blocking architect from finishing?", .name("architect", body: "")),
    ])
    func aWaitingQuestionAboutANamedConversationWithMoreWordsIsHeld(text: String, address: AgentAddress) {
        #expect(query(text) == .moreThanAQuestion(address))
    }

    @Test func withoutKnownNamesOnlyTheUnnamedFormsAreQuestions() {
        #expect(AgentStatusQuery.parse("What is architect waiting for?", names: [], namesKnown: false) == nil)
        #expect(AgentStatusQuery.parse("What are you waiting for?", names: [], namesKnown: false) == .waiting(nil))
        #expect(AgentStatusQuery.parse("What is session two waiting for?", names: [], namesKnown: false) == .waiting(.row(2, body: "")))
    }
}

struct AgentStatusAnswerTests {
    @Test(arguments: [
        (AgentLiveState.working, "Architect is working. No request for your input is currently reported."),
        (.idle, "Architect is ready for another message."),
        (.waitingApproval, "Architect is waiting for approval."),
        (.waitingQuestion, "Architect is waiting for an answer."),
        (.userDialog, "Architect has a dialog open."),
    ])
    func theStateAloneSaysOnlyWhatIsReported(state: AgentLiveState, line: String) {
        #expect(AgentStatusAnswer.waiting(handle: "Architect", state: state, connected: true, current: true, prompt: nil, description: nil) == line)
    }

    @Test(arguments: [
        (AgentLiveState.waitingApproval, "Architect was last seen waiting for approval. I couldn\u{2019}t check its current status."),
        (.working, "Architect was last seen working. I couldn\u{2019}t check its current status."),
        (.idle, "Architect was last seen ready. I couldn\u{2019}t check its current status."),
    ])
    func aStateCarriedFromAnEarlierCheckIsLastSeen(state: AgentLiveState, line: String) {
        let prompt = AgentPrompt(title: "Keep the schema?")
        #expect(AgentStatusAnswer.waiting(handle: "Architect", state: state, connected: true, current: false, prompt: prompt, description: "Asks.") == line)
        #expect(AgentStatusAnswer.hint(handle: "Architect", state: state, connected: true, current: false) == nil)
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
        #expect(AgentStatusAnswer.waiting(handle: "Architect", state: .userDialog, connected: true, current: true, prompt: prompt, description: "Asks something else.")
            == "Architect asks: Keep the existing schema or add a migration?")
    }

    @Test func aDescriptionIsUsedWhenThereIsNoUsableQuestion() {
        let prompt = AgentPrompt(kind: "confirm", tool: "bash", detail: "git push origin main")
        #expect(AgentStatusAnswer.question(in: prompt) == nil)
        #expect(AgentStatusAnswer.waiting(handle: "Architect", state: .userDialog, connected: true, current: true, prompt: prompt, description: "Asks whether to allow pushing to main.")
            == "Architect: Asks whether to allow pushing to main.")
    }

    @Test func aLongTitleIsNotReadAsTheQuestion() {
        let title = Array(repeating: "word", count: AgentStatusAnswer.questionWordLimit + 1).joined(separator: " ")
        #expect(AgentStatusAnswer.question(in: AgentPrompt(title: title)) == nil)
        #expect(AgentStatusAnswer.question(in: AgentPrompt(title: "   ")) == nil)
    }

    @Test func aConversationThatIsNotConnectedIsLastSeen() {
        #expect(AgentStatusAnswer.waiting(handle: "Architect", state: .waitingApproval, connected: false, current: true, prompt: nil, description: nil)
            == "Architect isn\u{2019}t connected. Last seen waiting for approval.")
        #expect(AgentStatusAnswer.waiting(handle: "Architect", state: .disconnected, connected: true, current: true, prompt: nil, description: nil)
            == "Architect isn\u{2019}t connected.")
        #expect(AgentStatusAnswer.waiting(handle: "Architect", state: .working, connected: false, current: true, prompt: nil, description: nil)
            == "Architect isn\u{2019}t connected. Last seen working.")
    }

    @Test(arguments: [
        ([String](), true, "No conversation needs you."),
        ([], false, "No confirmed requests for your input. I couldn\u{2019}t check every conversation."),
        (["Architect"], true, "One conversation needs you: Architect."),
        (["Architect", "Backend"], true, "Two conversations need you: Architect and Backend."),
        (["A", "B", "C"], true, "Three conversations need you: A, B and C."),
        (["Architect"], false, "One conversation needs you: Architect. I couldn\u{2019}t check every conversation."),
    ])
    func whoNeedsMeCountsThenNames(handles: [String], complete: Bool, line: String) {
        #expect(AgentStatusAnswer.whoNeedsMe(handles, complete: complete) == line)
    }
}
