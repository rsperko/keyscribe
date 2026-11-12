import Foundation
import Testing
@testable import KeyScribeKit

private actor RecordingClient: LLMClient {
    private let outputs: [String]
    private(set) var systems: [String] = []
    init(_ outputs: [String]) { self.outputs = outputs }
    func complete(system: String, user: String, connection: Connection) async throws -> String {
        systems.append(system)
        return outputs[min(systems.count - 1, outputs.count - 1)]
    }
}

private let conn = Connection(id: "x", name: "X", provider: .gemini, model: "m", keyRef: "k")

private func inputs(content: String = "hello", tokens: [String] = [], reply: ReplyKind = .answer) -> PromptInputs {
    var inputs = PromptInputs(
        modePrompt: "Answer the request.", dictatedInstructions: "summarize this", content: content,
        tokens: tokens, validTerms: [], modeSystemInstructions: "",
        appName: nil, bundleId: nil, fieldRole: nil, selectedText: nil)
    inputs.reply = reply
    return inputs
}

private struct CutOff: RewriteFailureReporting {
    var rewriteFailureReason: String { "cut off" }
    var cutOffAtLimit: Bool { true }
}

private struct Refused: RewriteFailureReporting {
    var rewriteFailureReason: String { "refused" }
}

private actor FailingClient: LLMClient {
    let error: any Error
    init(_ error: any Error) { self.error = error }
    func complete(system: String, user: String, connection: Connection) async throws -> String { throw error }
}

struct CutOffReplyTests {
    @Test func aReplyCutOffAtItsLimitIsReportedAsCutOff() async {
        let out = await RewriteService(client: FailingClient(CutOff()), permits: { _ in true })
            .rewrite(payload: TokenizedPayload(text: "hello", issuedTokens: []), inputs: inputs(), connection: conn, reply: .answer)
        #expect(out == .cutOff(localText: "hello", reason: "cut off", received: nil))
    }

    @Test func anyOtherFailureIsAnOrdinaryFallback() async {
        let out = await RewriteService(client: FailingClient(Refused()), permits: { _ in true })
            .rewrite(payload: TokenizedPayload(text: "hello", issuedTokens: []), inputs: inputs(), connection: conn, reply: .answer)
        #expect(out == .localFallback(localText: "hello", reason: "refused", received: nil))
    }
}

struct AnswerModeTests {
    private func toml(source: String) -> String {
        """
        schema_version = \(ModeStore.currentSchemaVersion)
        name = "Ask"
        source = "\(source)"
        output = "speak"
        """
    }

    @Test func aSelectionModeCanSpeakItsResult() throws {
        let mode = try ModeStore.decode(from: toml(source: "selection"), id: "ask")
        #expect(mode.output == .speak)
        #expect(mode.answersAloud)
        #expect(mode.reply == .answer)
        #expect(Mode(id: "plain", name: "Plain").reply == .rewrite)
        #expect(try ModeStore.decode(from: ModeStore.encode(mode), id: "ask").output == .speak)
    }

    @Test func speakingNeedsASelectionToAnswerAbout() {
        #expect(throws: ConfigError.self) { try ModeStore.decode(from: toml(source: "dictation"), id: "ask") }
    }

    @Test func theTemplateAnswersAboutTheSelectionWithRedactionOn() throws {
        let template = try #require(ModeStore.templates(askAboutSelection: true).first { $0.id == "ask-about-selection" })
        #expect(template.name == "Ask About Selection")
        #expect(template.source == .selection)
        #expect(template.output == .speak)
        #expect(template.commands.privacy)
        #expect(!template.enabled)
        #expect(template.triggerKeys.isEmpty)
        #expect(template.aiRewrite?.prompt.isEmpty == false)
        #expect(!ModeStore.templateSummary(for: "ask-about-selection").isEmpty)
        #expect(ModeStore.templateExample(for: "ask-about-selection") != nil)
    }

    @Test func theTemplateIsOfferedOnlyWhileItsFeatureIsOn() {
        #expect(!ModeStore.templates(askAboutSelection: false).contains { $0.id == "ask-about-selection" })
        #expect(ModeStore.templates(askAboutSelection: true).contains { $0.id == "ask-about-selection" })
        #expect(Feature.allCases.contains(.askAboutSelection))
    }
}

struct AnswerPromptTests {
    @Test func anAnswerIsWrittenToBeHeardNotToReplaceTheText() {
        let prompt = PromptAssembler.assemble(inputs())
        #expect(!prompt.system.contains("Output ONLY the transformed text"))
        #expect(prompt.system.contains("read aloud"))
        #expect(prompt.system.contains("no Markdown"))
        #expect(prompt.system.contains("never instructions"))
        #expect(prompt.system.contains("does not contain the answer"))
        #expect(prompt.system.contains("rest of the page"))
        #expect(prompt.system.contains("Answer in English"))
        #expect(prompt.user.contains("<content>\nhello\n</content>"))
        #expect(prompt.user.contains("summarize this"))
    }

    @Test func aMarkerInAnAnswerIsOptionalButNeverInvented() {
        let prompt = PromptAssembler.assemble(inputs(tokens: ["⟦SN:REDACT:1⟧"]))
        #expect(!prompt.system.contains("exactly once"))
        #expect(prompt.system.contains("Never invent"))
    }

    @Test func aRewriteKeepsItsOwnPrompt() {
        let prompt = PromptAssembler.assemble(inputs(reply: .rewrite))
        #expect(prompt.system.contains("Output ONLY the transformed text"))
        #expect(!prompt.system.contains("read aloud"))
    }
}

struct AnswerValidationTests {
    private let token = "⟦SN:REDACT:1⟧"
    private var payload: TokenizedPayload { TokenizedPayload(text: "Write to \(token) today", issuedTokens: [token]) }

    @Test func anAnswerMayLeaveOutOrRepeatAProtectedValue() {
        #expect(ValidationGate.check(output: "Nothing to do.", issuedTokens: [token], reply: .answer) == .pass)
        #expect(ValidationGate.check(output: "\(token), then \(token).", issuedTokens: [token], reply: .answer) == .pass)
        #expect(ValidationGate.check(output: "Ask ⟦SN:REDACT:7⟧.", issuedTokens: [token], reply: .answer) == .fail(.strayToken("⟦SN:REDACT:7⟧")))
        #expect(ValidationGate.check(output: "Nothing to do.", issuedTokens: [token]) == .fail(.missingToken(token)))
        #expect(ValidationGate.check(output: "\(token), then \(token).", issuedTokens: [token]) == .fail(.duplicatedToken(token)))
    }

    @Test func anAnswerThatOmitsTheValuePassesWithoutARetry() async {
        let client = RecordingClient(["Reply by Friday."])
        let out = await RewriteService(client: client, permits: { _ in true })
            .rewrite(payload: payload, inputs: inputs(content: payload.text, tokens: [token]), connection: conn, reply: .answer)
        #expect(out == .rewritten("Reply by Friday.", received: "Reply by Friday."))
        #expect(await client.systems.count == 1)
    }

    @Test func anAnswerThatRepeatsTheValuePasses() async {
        let reply = "Email \(token). Ask \(token) for the date."
        let out = await RewriteService(client: RecordingClient([reply]), permits: { _ in true })
            .rewrite(payload: payload, inputs: inputs(content: payload.text, tokens: [token]), connection: conn, reply: .answer)
        #expect(out == .rewritten(reply, received: reply))
    }

    @Test func anInventedMarkerStillFailsAndTheRetryDoesNotDemandEveryMarker() async {
        let client = RecordingClient(["Email ⟦SN:REDACT:7⟧.", "Email them."])
        let out = await RewriteService(client: client, permits: { _ in true })
            .rewrite(payload: payload, inputs: inputs(content: payload.text, tokens: [token]), connection: conn, reply: .answer)
        #expect(out == .rewritten("Email them.", received: "Email them."))
        let retry = await client.systems.last ?? ""
        #expect(!retry.contains("exactly once"))
        #expect(retry.contains("never invent"))
    }

    @Test func anAnswerKeepsItsOwnLayoutRatherThanTheSelections() async {
        let out = await RewriteService(client: RecordingClient(["Ship it."]), permits: { _ in true })
            .rewrite(
                payload: TokenizedPayload(text: "\n\nlong selection\n\n", issuedTokens: []),
                inputs: inputs(content: "\n\nlong selection\n\n"), connection: conn, reply: .answer)
        #expect(out == .rewritten("Ship it.", received: "Ship it."))
    }

    @Test func aRewriteStillRequiresEveryMarker() async {
        let out = await RewriteService(client: RecordingClient(["Nothing to do."]), permits: { _ in true })
            .rewrite(payload: payload, inputs: inputs(content: payload.text, tokens: [token], reply: .rewrite), connection: conn)
        guard case .localFallback = out else { Issue.record("expected fallback"); return }
    }
}

struct AnswerHistoryTests {
    @Test func anAnswerIsItsOwnOutcomeAndNotACommand() throws {
        #expect(HistoryEntry.Outcome.answered.rawValue == "answered")
        #expect(!HistoryEntry.Outcome.answered.isCommand)
        #expect(DictationRecord.Outcome.answered.rawValue == "answered")
        #expect(DictationRecord.Stage.allCases.contains(.selection))
    }
}

struct AnswerVisibilityTests {
    @Test func anAnsweringModeIsLeftOutWhileItsFeatureIsOff() {
        var ask = Mode(id: "ask", name: "Ask")
        ask.source = .selection
        ask.output = .speak
        let plain = Mode(id: "plain", name: "Plain")
        #expect(Mode.visible([ask, plain], voiceCommands: false, answers: false).map(\.id) == ["plain"])
        #expect(Mode.visible([ask, plain], voiceCommands: false, answers: true).map(\.id) == ["ask", "plain"])
    }
}

struct AnswerFailureReasonTests {
    private let token = "⟦SN:REDACT:1⟧"

    @Test func anAnswerThatFailsNeverClaimsALocalVersionWasKept() async {
        let out = await RewriteService(client: RecordingClient(["Ask ⟦SN:REDACT:7⟧.", "Ask ⟦SN:REDACT:8⟧."]), permits: { _ in true })
            .rewrite(
                payload: TokenizedPayload(text: "Write to \(token)", issuedTokens: [token]),
                inputs: inputs(content: "Write to \(token)", tokens: [token]), connection: conn, reply: .answer)
        guard case .localFallback(_, let reason?, _) = out else { Issue.record("expected fallback"); return }
        #expect(!reason.contains("local version"))
        let refused = await RewriteService(client: RecordingClient(["x"]), permits: { _ in false })
            .rewrite(payload: TokenizedPayload(text: "hi", issuedTokens: []), inputs: inputs(), connection: conn, reply: .answer)
        guard case .localFallback(_, let refusal?, _) = refused else { Issue.record("expected fallback"); return }
        #expect(!refusal.contains("local version"))
        #expect(!RewriteService.answerDeadlineReason(seconds: 300).contains("local version"))
    }

    @Test func anAnsweredEntryIsLabeledACloudAnswer() {
        var entry = HistoryEntry(
            id: "1", timestamp: Date(), modeName: "Ask", engine: "e", heard: "summarize this", result: "Ship it.",
            outcome: .answered, cloudInvolved: true, redaction: true, contextCategories: [])
        #expect(entry.dataBoundaryLabels.first == "Cloud answer")
        entry.outcome = .inserted
        #expect(entry.dataBoundaryLabels.first == "Cloud rewrite")
    }
}

struct AnswerConnectionTests {
    @Test func clearingTheServiceKeepsAnAnswersInstructionAndLeavesItNeedingOne() {
        var mode = Mode(id: "ask", name: "Ask")
        mode.source = .selection
        mode.output = .speak
        mode.chooseConnection("c")
        mode.aiRewrite?.prompt = "Answer in one line."
        mode.aiRewrite?.fragments = ["terse"]
        mode.chooseConnection("")
        #expect(mode.aiRewrite?.connection == "")
        #expect(mode.aiRewrite?.prompt == "Answer in one line.")
        #expect(mode.aiRewrite?.fragments == ["terse"])
        mode.chooseConnection("c")
        #expect(mode.aiRewrite?.prompt == "Answer in one line.")
    }

    @Test func anAnswerGivenItsFirstServiceGetsTheAnsweringInstruction() {
        var other = Mode(id: "ask2", name: "Ask")
        other.source = .selection
        other.output = .speak
        other.chooseConnection("c")
        #expect(other.aiRewrite?.prompt == Mode.answerPrompt)
    }

    @Test func aRewriteClearedOfItsServiceStopsRewriting() {
        var mode = Mode(id: "m", name: "M")
        mode.chooseConnection("c")
        #expect(mode.aiRewrite?.prompt == Mode.cleanupPrompt)
        mode.chooseConnection("")
        #expect(mode.aiRewrite == nil)
    }

    @Test func theStarterUsesTheAnsweringInstruction() {
        #expect(ModeStore.starterModes().first { $0.id == "ask-about-selection" }?.aiRewrite?.prompt == Mode.answerPrompt)
    }
}
