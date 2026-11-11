@testable import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct CodingAgentPhrasesTests {
    private func unquoted(_ phrase: String) -> String {
        String(phrase.dropFirst().dropLast()).trimmingCharacters(in: .punctuationCharacters)
    }

    private func phrases(name: String, readsReplies: Bool) -> [String] {
        CodingAgentPhrasesSection.examples(name: name, readsReplies: readsReplies).map { unquoted($0.phrase) }
    }

    @Test func tellingANameSendsTheInstructionThere() {
        let said = phrases(name: "backend", readsReplies: false)[0]
        #expect(VoiceCommandGrammar.parse(said) == nil)
        #expect(AgentRename.request(in: said) == nil)
        #expect(AgentStatusQuery.parse(said, names: ["backend"]) == nil)
        #expect(AgentAddress.parse(said, names: ["backend"]) == .name("backend", body: "run the unit tests"))
    }

    @Test func selectingANameChoosesItWithoutAMessage() {
        let said = phrases(name: "backend", readsReplies: false)[1]
        #expect(AgentStatusQuery.parse(said, names: ["backend"]) == nil)
        #expect(AgentAddress.parse(said, names: ["backend"]) == .select(.name("backend", body: "")))
    }

    @Test func openingANameShowsItWithoutAMessage() {
        let said = phrases(name: "backend", readsReplies: false)[2]
        #expect(AgentStatusQuery.parse(said, names: ["backend"]) == nil)
        #expect(AgentAddress.parse(said, names: ["backend"]) == .open(.name("backend", body: "")))
    }

    @Test func theQuestionsAreAnsweredWithoutSendingAnything() {
        let said = phrases(name: "backend", readsReplies: false)
        #expect(AgentStatusQuery.parse(said[3], names: ["backend"]) == .waiting(.name("backend", body: "")))
        #expect(AgentStatusQuery.parse(said[4], names: ["backend"]) == .whoNeedsMe)
    }

    @Test func goBackCancelAndRepeatAreTheBuiltInCommands() {
        let said = phrases(name: "backend", readsReplies: false)
        #expect(VoiceCommandGrammar.parse(said[5]) == .goBack)
        #expect(VoiceCommandGrammar.parse(said[6]) == .cancel)
        #expect(said.count == 7)
        let reading = phrases(name: "backend", readsReplies: true)
        #expect(reading.count == 8)
        #expect(VoiceCommandGrammar.parse(reading[7]) == .repeatSummary)
    }

    @Test func withoutNamesTheExamplesUseTheConversationNumber() {
        let said = phrases(name: "conversation two", readsReplies: false)
        #expect(AgentAddress.parse(said[0], names: [], namesKnown: false) == .row(2, body: "run the unit tests"))
        #expect(AgentAddress.parse(said[1], names: [], namesKnown: false) == .select(.row(2, body: "")))
        #expect(AgentAddress.parse(said[2], names: [], namesKnown: false) == .open(.row(2, body: "")))
        #expect(AgentStatusQuery.parse(said[3], names: [], namesKnown: false) == .waiting(.row(2, body: "")))
    }

    @Test func renamingNamesTheConversationInstructionsGoTo() {
        #expect(AgentRename.parse(unquoted(CodingAgentPhrasesSection.renameExample)) == .rename("API"))
    }
}
