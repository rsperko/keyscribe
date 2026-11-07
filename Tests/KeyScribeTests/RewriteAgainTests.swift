import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct RewriteAgainTests {
    private final class FixedEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias = false
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "" }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        func start(sampleRate: Int) async throws -> URL { URL(fileURLWithPath: "/dev/null") }
        func stop() -> URL? { nil }
    }

    private actor UpperLLM: LLMClient {
        private(set) var users: [String] = []
        func complete(system: String, user: String, connection: Connection) async throws -> String {
            users.append(user)
            guard let start = user.range(of: "<content>\n"), let end = user.range(of: "\n</content>") else { return user }
            return String(user[start.upperBound..<end.lowerBound]).uppercased()
        }
    }

    @MainActor private final class Probes { var count = 0 }

    private let conn = Connection(id: "c1", name: "C1", provider: .gemini, model: "m", keyRef: "k")

    private func mode(liveEdits: Bool = false) -> Mode {
        var mode = Mode(id: "m", name: "Email")
        mode.aiRewrite = .init(connection: "c1", prompt: "Rewrite it.", context: .init(app: true, precedingText: true))
        mode.commands.liveEdits = liveEdits
        return mode
    }

    private func entry(
        heard: String, mode: String = "Email", redaction: Bool = false, routedPhrase: String? = nil
    ) -> HistoryEntry {
        HistoryEntry(
            id: "take", timestamp: Date(), modeName: mode, heard: heard, result: heard, outcome: .localFallback,
            cloudInvolved: true, redaction: redaction, contextCategories: [],
            modeChoice: routedPhrase == nil ? .triggerKey : .spokenPhrase, routedPhrase: routedPhrase)
    }

    private func makeController(mode: Mode, llm: any LLMClient, probed: @escaping @MainActor () -> Void) -> DictationController {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-rewrite-again-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        try? ModeStore.write(mode, to: modesDir)
        try? ConnectionStore.write(ConnectionSet(connections: [conn]), to: supportDir)
        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        let provider = try! SpeechEngineProvider(engines: [FixedEngine()], activeId: "fixed")
        return DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: nil, permits: { _ in true }, audio: FakeAudio(),
            insert: { _, _, _, _, _ in true }, submitKey: { _ in }, clipboard: { "CLIPBOARD" },
            snapshot: { TargetSnapshot(bundleId: "test.bundle", pid: 4242, focusedWindowId: "cg:99") },
            micStatus: { .granted }, accessibilityGranted: { true },
            precedingTextProbe: { _, _ in probed(); return "PRECEDINGCTX" },
            llmClient: llm)
    }

    @Test func itRewritesWhatWasHeardWithTheModeAsItIsNowAndSendsNoContext() async {
        let llm = UpperLLM()
        let probes = Probes()
        let controller = makeController(mode: mode(), llm: llm) { probes.count += 1 }
        guard case .rewritten(let text, let details) = await controller.rewriteAgain(entry(heard: "draft the memo"))
        else { Issue.record("expected a rewrite"); return }
        #expect(text.hasPrefix("DRAFT THE MEMO"))
        #expect(details.connection == "C1")
        #expect(details.contextCategories.isEmpty)
        #expect(probes.count == 0)
        let user = await llm.users.first ?? ""
        #expect(!user.contains("PRECEDINGCTX"))
        #expect(!user.contains("test.bundle"))
    }

    @Test func aModeThatNoLongerExistsIsNotRewritten() async {
        let llm = UpperLLM()
        let controller = makeController(mode: mode(), llm: llm) {}
        guard case .unavailable = await controller.rewriteAgain(entry(heard: "draft the memo", mode: "Gone")) else {
            Issue.record("expected unavailable"); return
        }
        #expect(await llm.users.isEmpty)
    }

    @Test func aDictationThatInsertedTheClipboardIsNotRewrittenWithTodaysClipboard() async {
        let llm = UpperLLM()
        let controller = makeController(mode: mode(liveEdits: true), llm: llm) {}
        guard case .unavailable = await controller.rewriteAgain(
            entry(heard: "see insert clipboard contents")) else {
            Issue.record("expected unavailable"); return
        }
        #expect(await llm.users.isEmpty)
    }

    @Test func aTakeThatWasRedactedIsRedactedAgainAfterTheModeTurnedRedactionOff() async {
        let llm = UpperLLM()
        let controller = makeController(mode: mode(), llm: llm) {}
        guard case .rewritten(let text, let details) = await controller.rewriteAgain(
            entry(heard: "email bob@example.com today", redaction: true)) else {
            Issue.record("expected a rewrite"); return
        }
        #expect(details.redaction)
        #expect(text.contains("bob@example.com"))
        let user = await llm.users.first ?? ""
        #expect(!user.contains("bob@example.com"))
    }

    @Test func theSpokenPhraseThatChoseTheModeIsNotSentAsContent() async {
        let llm = UpperLLM()
        let controller = makeController(mode: mode(), llm: llm) {}
        guard case .rewritten(let text, _) = await controller.rewriteAgain(
            entry(heard: "draft the memo as an email", routedPhrase: #"(?i)\bas an email$"#)) else {
            Issue.record("expected a rewrite"); return
        }
        #expect(!text.contains("AS AN EMAIL"))
        #expect(await llm.users.first?.contains("as an email") == false)
    }
}
