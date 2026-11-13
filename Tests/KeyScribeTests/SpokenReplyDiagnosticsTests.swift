import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct SpokenReplyDiagnosticsTests {
    final class Calls: @unchecked Sendable {
        var renders: [String] = []
        var files: [URL] = []
        var voices: [String] = []
    }

    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    nonisolated static func audio(_ text: String, conditions: RenderConditions? = nil) -> SpokenAudio {
        let samples = [Float](repeating: 0.2, count: max(1, text.count) * 100)
        return SpokenAudio(
            wav: SpokenAudio.wav([samples], sampleRate: 24_000) ?? Data(),
            synthesis: .init(
                normalizedText: text.lowercased(), phonemes: "/\(text)/", predictedDurations: [1], stageMilliseconds: [], sampleRate: 24_000,
                measurements: SpokenAudioCheck.measure(samples, sampleRate: 24_000), conditions: conditions),
            samples: samples, sampleRate: 24_000)
    }

    private func store() throws -> HistoryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return HistoryStore(supportDir: url)
    }

    private func entry(in store: HistoryStore, id: String = "e1", text: String = "Build passed. Ship it.") throws -> HistoryEntry {
        var entry = HistoryEntry(
            id: id, timestamp: at, modeName: "Coding agent", heard: "", result: "", outcome: .inserted, cloudInvolved: false,
            redaction: false, contextCategories: [])
        entry.spokenReply = .init(at: at, conversation: "docs", text: text, voice: "natural")
        try store.append(entry, today: HistoryStore.todayString(date: at))
        return entry
    }

    private func spoken(_ attempts: SpokenAttempts, entry: String, sentences: [String]) -> String? {
        let id = attempts.begin(text: sentences.joined(separator: " "), voice: "af_heart")
        attempts.awaitLink(id)
        for sentence in sentences { attempts.addSegment(id, text: sentence, audio: Self.audio(sentence)) }
        attempts.update(id) {
            $0.reader = .natural
            $0.playback = .finished
        }
        attempts.link(id, to: entry)
        attempts.ended(id)
        return id
    }

    private func make(
        _ store: HistoryStore, attempts: SpokenAttempts, heard: [EngineKeeper.Listening], calls: Calls = Calls()
    ) -> SpokenReplyDiagnostics {
        let diagnostics = SpokenReplyDiagnostics(attempts: attempts, history: { store }, wait: { _ in })
        var answers = heard
        diagnostics.listen = { wav in
            calls.files.append(wav)
            return answers.isEmpty ? .unavailable : answers.removeFirst()
        }
        return diagnostics
    }

    private func stored(_ store: HistoryStore, _ id: String = "e1") -> HistoryEntry? {
        store.entries().first { $0.id == id }
    }

    private func report(_ store: HistoryStore, _ name: String) throws -> String {
        try String(contentsOf: store.evidence.folder(entry: "e1", at: at).appendingPathComponent(name), encoding: .utf8)
    }

    @Test func aReplyThatEndsIsNotCheckedAndItsHistoryEntryIsLeftAlone() throws {
        let store = try store()
        _ = try entry(in: store)
        let attempts = SpokenAttempts()
        let calls = Calls()
        _ = make(store, attempts: attempts, heard: [.heard("build passed ship it", checker: "parakeet-ultra")], calls: calls)
        let id = try #require(spoken(attempts, entry: "e1", sentences: ["Build passed.", "Ship it."]))
        #expect(calls.files.isEmpty)
        #expect(stored(store)?.spokenReply?.check == nil)
        #expect(stored(store)?.spokenReply?.rendering == nil)
        #expect(try #require(attempts.attempt(id)?.audio).count > Self.audio("Build passed.").wav.count)
    }

    @Test func keepingAReplyRecordsHowItWasRead() throws {
        let store = try store()
        let entry = try entry(in: store)
        let attempts = SpokenAttempts()
        _ = spoken(attempts, entry: "e1", sentences: ["Build passed.", "Ship it."])
        #expect(make(store, attempts: attempts, heard: []).keep(entry) == .kept("docs"))
        #expect(stored(store)?.spokenReply?.rendering == .init(voice: "af_heart", sentences: ["Build passed.", "Ship it."]))
    }

    @Test func checkingAHeldReplyListensToItsAudioAndRecordsTheResult() async throws {
        let store = try store()
        let entry = try entry(in: store)
        let attempts = SpokenAttempts()
        let calls = Calls()
        let diagnostics = make(store, attempts: attempts, heard: [.heard("build passed ship it", checker: "parakeet-ultra")], calls: calls)
        let id = try #require(spoken(attempts, entry: "e1", sentences: ["Build passed.", "Ship it."]))
        guard case .checked(let check) = await diagnostics.check(entry) else { Issue.record("not checked"); return }
        #expect(check.matched)
        #expect(calls.files.count == 1)
        #expect(stored(store)?.spokenReply?.check == check)
        #expect(attempts.attempt(id)?.check == check)
        #expect(stored(store)?.spokenReply?.kept == nil)
    }

    @Test func aMismatchIsRecordedButNothingIsKept() async throws {
        let store = try store()
        let entry = try entry(in: store)
        let attempts = SpokenAttempts()
        let diagnostics = make(store, attempts: attempts, heard: [.heard("bill fish", checker: "parakeet-ultra")])
        _ = spoken(attempts, entry: "e1", sentences: ["Build passed.", "Ship it."])
        guard case .checked(let check) = await diagnostics.check(entry) else { Issue.record("not checked"); return }
        #expect(!check.matched)
        #expect(stored(store)?.spokenReply?.check?.matched == false)
        #expect(!store.evidence.isKept(entry: "e1", at: at))
    }

    @Test func checkingAKeptReplyListensToItsSavedAudioAndUpdatesItsReport() async throws {
        let store = try store()
        let entry = try entry(in: store)
        let attempts = SpokenAttempts()
        _ = spoken(attempts, entry: "e1", sentences: ["Build passed.", "Ship it."])
        #expect(make(store, attempts: attempts, heard: []).keep(entry) == .kept("docs"))
        let calls = Calls()
        let diagnostics = make(store, attempts: SpokenAttempts(), heard: [.heard("bill fish", checker: "parakeet-ultra")], calls: calls)
        guard case .checked(let check) = await diagnostics.check(entry) else { Issue.record("not checked"); return }
        #expect(!check.matched)
        #expect(calls.files == [try #require(store.evidence.original(entry: "e1", at: at))])
        #expect(try report(store, "reply report.txt").contains("heard: bill fish"))
    }

    @Test func checkingASavedRenderUpdatesThatRendersReportAndLeavesTheEntrysCheck() async throws {
        let store = try store()
        let entry = try entry(in: store)
        let render = make(store, attempts: SpokenAttempts(), heard: [])
        render.render = { text, _ in Self.audio(text) }
        guard case .rendered(let number, _, _) = await render.renderAgain(entry) else { Issue.record("not rendered"); return }
        let url = try #require(store.evidence.renders(entry: "e1", at: at).first)
        let diagnostics = make(store, attempts: SpokenAttempts(), heard: [.heard("build passed ship it", checker: "parakeet-ultra")])
        guard case .checked(let check) = await diagnostics.check(entry, render: url) else { Issue.record("not checked"); return }
        #expect(check.matched)
        #expect(try report(store, "render \(number) report.txt").contains("heard: build passed ship it"))
        #expect(stored(store)?.spokenReply?.check == nil)
    }

    @Test func aBusyModelIsReportedOnceAndNothingIsRecorded() async throws {
        let store = try store()
        let entry = try entry(in: store)
        let attempts = SpokenAttempts()
        let calls = Calls()
        let diagnostics = make(store, attempts: attempts, heard: [.busy, .heard("build passed ship it", checker: "parakeet-ultra")], calls: calls)
        _ = spoken(attempts, entry: "e1", sentences: ["Build passed."])
        #expect(await diagnostics.check(entry) == .busy)
        #expect(calls.files.count == 1)
        #expect(stored(store)?.spokenReply?.check == nil)
    }

    @Test func aCancelledCheckRecordsNothing() async throws {
        let store = try store()
        let entry = try entry(in: store)
        let attempts = SpokenAttempts()
        let diagnostics = make(store, attempts: attempts, heard: [.cancelled])
        _ = spoken(attempts, entry: "e1", sentences: ["Build passed."])
        #expect(await diagnostics.check(entry) == .cancelled)
        #expect(stored(store)?.spokenReply?.check == nil)
    }

    @Test func aReplyWithNoAudioLeftIsNotListenedTo() async throws {
        let store = try store()
        let entry = try entry(in: store)
        let calls = Calls()
        let diagnostics = make(store, attempts: SpokenAttempts(), heard: [.heard("x", checker: "parakeet-ultra")], calls: calls)
        #expect(await diagnostics.check(entry) == .noAudio)
        #expect(calls.files.isEmpty)
    }

    @Test func theHeldAudioIsWrittenOnlyForTheCheck() async throws {
        let store = try store()
        let entry = try entry(in: store)
        let attempts = SpokenAttempts()
        var listened: Data?
        let diagnostics = make(store, attempts: attempts, heard: [])
        diagnostics.listen = { wav in
            listened = try? Data(contentsOf: wav)
            defer { _ = wav }
            return .heard("build passed", checker: "parakeet-ultra")
        }
        let id = try #require(spoken(attempts, entry: "e1", sentences: ["Build passed."]))
        var file: URL?
        diagnostics.listen = { wav in
            file = wav
            listened = try? Data(contentsOf: wav)
            return .heard("build passed", checker: "parakeet-ultra")
        }
        _ = await diagnostics.check(entry)
        #expect(listened == attempts.attempt(id)?.audio)
        #expect(!FileManager.default.fileExists(atPath: try #require(file).path))
    }

    @Test func keepingAReplyWhoseAudioIsGoneKeepsItsTextReport() throws {
        let store = try store()
        let entry = try entry(in: store)
        let diagnostics = make(store, attempts: SpokenAttempts(), heard: [])
        #expect(diagnostics.keep(entry) == .reportOnly("docs"))
        let folder = store.evidence.folder(entry: "e1", at: at)
        let report = try String(contentsOf: folder.appendingPathComponent("reply report.txt"), encoding: .utf8)
        #expect(report.contains("Text read: Build passed. Ship it."))
        #expect(report.contains("no longer held"))
        #expect(store.evidence.renders(entry: "e1", at: at).isEmpty)
        #expect(stored(store)?.spokenReply?.kept == true)
    }

    @Test func renderingAgainKeepsTheReplyAndSavesTheNewRenderBesideTheOriginal() async throws {
        let store = try store()
        let entry = try entry(in: store)
        let attempts = SpokenAttempts()
        let calls = Calls()
        let diagnostics = make(store, attempts: attempts, heard: [], calls: calls)
        diagnostics.render = { text, _ in
            calls.renders.append(text)
            return Self.audio(text)
        }
        _ = spoken(attempts, entry: "e1", sentences: ["Build passed.", "Ship it."])
        let outcome = await diagnostics.renderAgain(entry)
        guard case .rendered(let number, _, let note) = outcome else { Issue.record("not rendered: \(outcome)"); return }
        #expect(number == 2)
        #expect(calls.files.isEmpty)
        #expect(note == nil)
        #expect(calls.renders == ["Build passed.", "Ship it."])
        #expect(store.evidence.renders(entry: "e1", at: at).map(\.lastPathComponent) == ["render 2.wav"])
        #expect(store.evidence.original(entry: "e1", at: at) != nil)
        let report = try String(
            contentsOf: store.evidence.folder(entry: "e1", at: at).appendingPathComponent("render 2 report.txt"), encoding: .utf8)
        #expect(report.contains("Rendered again from History"))
        #expect(report.contains("Phonemes: /Ship it./"))
    }

    @Test func aSilentRenderIsStillKeptAsEvidence() async throws {
        let store = try store()
        let entry = try entry(in: store, text: "Done.")
        let diagnostics = make(store, attempts: SpokenAttempts(), heard: [])
        diagnostics.render = { text, _ in throw SpokenAudio.Unusable(problem: .silent, audio: Self.audio(text)) }
        let outcome = await diagnostics.renderAgain(entry)
        guard case .rendered(let number, _, _) = outcome else { Issue.record("not rendered: \(outcome)"); return }
        #expect(number == 2)
        let report = try String(
            contentsOf: store.evidence.folder(entry: "e1", at: at).appendingPathComponent("render 2 report.txt"), encoding: .utf8)
        #expect(report.contains("made silent audio"))
    }

    @Test func renderingAgainAfterTheAudioIsGoneUsesTheRecordedVoiceAndSentences() async throws {
        let store = try store()
        var entry = try entry(in: store)
        entry.spokenReply?.rendering = .init(voice: "bf_emma", sentences: ["Build passed.", "Ship it."])
        _ = store.update(id: "e1", near: at) { _ in entry }
        let calls = Calls()
        let diagnostics = make(store, attempts: SpokenAttempts(), heard: [], calls: calls)
        diagnostics.render = { text, voice in
            calls.renders.append(text)
            calls.voices.append(voice)
            return Self.audio(text)
        }
        diagnostics.currentVoice = { "af_heart" }
        let outcome = await diagnostics.renderAgain(entry)
        guard case .rendered(_, _, let note) = outcome else { Issue.record("not rendered: \(outcome)"); return }
        #expect(note == nil)
        #expect(calls.renders == ["Build passed.", "Ship it."])
        #expect(calls.voices == ["bf_emma", "bf_emma"])
    }

    @Test func renderingAgainWithoutARecordSaysTheInputsChanged() async throws {
        let store = try store()
        let entry = try entry(in: store)
        let diagnostics = make(store, attempts: SpokenAttempts(), heard: [])
        diagnostics.render = { text, _ in Self.audio(text) }
        diagnostics.currentVoice = { "af_heart" }
        let outcome = await diagnostics.renderAgain(entry)
        guard case .rendered(_, _, let note) = outcome else { Issue.record("not rendered: \(outcome)"); return }
        #expect(note != nil)
        let report = try String(
            contentsOf: store.evidence.folder(entry: "e1", at: at).appendingPathComponent("render 2 report.txt"), encoding: .utf8)
        #expect(report.contains("weren\u{2019}t recorded"))
    }

    @Test func aRenderThatFinishesAfterItsEntryWasDeletedSavesNothing() async throws {
        let store = try store()
        let entry = try entry(in: store)
        let diagnostics = make(store, attempts: SpokenAttempts(), heard: [])
        diagnostics.render = { text, _ in
            _ = store.delete(entry)
            return Self.audio(text)
        }
        #expect(await diagnostics.renderAgain(entry) == .failed("This entry was deleted, so the new render wasn\u{2019}t saved."))
        #expect(!store.evidence.isKept(entry: "e1", at: at))
    }

    @Test func aStalledRenderGivesUpAtItsDeadline() async throws {
        let store = try store()
        let entry = try entry(in: store)
        let diagnostics = make(store, attempts: SpokenAttempts(), heard: [])
        diagnostics.renderLimit = { _ in .milliseconds(50) }
        diagnostics.render = { _, _ in
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }
        #expect(await diagnostics.renderAgain(entry) == .failed("The natural voice took too long to render this reply."))
        #expect(!store.evidence.isKept(entry: "e1", at: at))
    }

    @Test func aKeptReplyCanStillBePlayedFromItsSavedAudio() throws {
        let store = try store()
        let entry = try entry(in: store)
        let attempts = SpokenAttempts()
        _ = spoken(attempts, entry: "e1", sentences: ["Build passed."])
        let diagnostics = make(store, attempts: attempts, heard: [])
        #expect(diagnostics.keep(entry) == .kept("docs"))
        let unheld = make(store, attempts: SpokenAttempts(), heard: [])
        #expect(unheld.keptOriginal(entry)?.lastPathComponent == "reply.wav")
    }
}
