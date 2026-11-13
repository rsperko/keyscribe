import Foundation
import Testing
@testable import KeyScribeKit

struct SpokenReplyCheckTests {
    @Test func aRenderThatSaysItsTextMatches() throws {
        let result = try #require(SpokenReplyCheck.compare(text: "docs: Done, tests pass.", normalized: nil, heard: "Docs done tests pass"))
        #expect(result.errorRate == 0)
        #expect(result.matched)
        #expect(result.percentHeard == 100)
    }

    @Test func garbledSpeechDoesNotMatch() throws {
        let result = try #require(SpokenReplyCheck.compare(
            text: "The build finished and every test passed.", normalized: nil, heard: "the bill fish and of it"))
        #expect(!result.matched)
        #expect(result.percentHeard < 50)
    }

    @Test(arguments: [
        ("backend: Migrated the users table and backfilled three thousand rows.", "Backend migrated the user's table and backfilled 3,000 rows."),
        ("backend: Profiling shows most time spent serializing JSON.", "Back-end, profiling shows most time spent serializing JSON."),
        ("api: Query time dropped from eight hundred milliseconds to forty.", "API, query time dropped from 800 milliseconds to 40."),
        ("infra: Deployed version two point four to staging.", "Infra deployed version 2.4 to staging."),
    ])
    func howSpeechRecognitionWritesACleanRenderStillMatches(text: String, heard: String) {
        let result = SpokenReplyCheck.compare(text: text, normalized: nil, heard: heard)
        #expect((result?.errorRate ?? 1) < 0.05)
        #expect(result?.matched == true)
    }

    @Test func aReplyHeardOnlyHalfwayDoesNotMatch() {
        let text = "frontend: The dark mode colors are fixed in the settings sheet and the sidebar."
        #expect(SpokenReplyCheck.compare(text: text, normalized: nil, heard: "Frontend, the dark mode colors are")?.matched == false)
    }

    @Test func theNormalizedTextCountsWhenItMatchesBetter() {
        let heard = "docs and tests"
        #expect((SpokenReplyCheck.compare(text: "docs & tests", normalized: nil, heard: heard)?.errorRate ?? 0) > 0)
        #expect(SpokenReplyCheck.compare(text: "docs & tests", normalized: "docs and tests", heard: heard)?.errorRate == 0)
    }

    @Test func nothingHeardIsAMismatch() {
        let result = SpokenReplyCheck.compare(text: "All done.", normalized: nil, heard: "")
        #expect(result?.matched == false)
        #expect(result?.percentHeard == 0)
    }

    @Test func aWrongNumberIsAMismatchInTheNumber() {
        let result = SpokenReplyCheck.compare(text: "Deployed version two.", normalized: nil, heard: "Deployed version 9.")
        #expect((result?.errorRate ?? 0) > 0)
        #expect(SpokenReplyCheck.compare(text: "Deployed version 2.", normalized: nil, heard: "deployed version two")?.errorRate == 0)
    }

    @Test func aReplyOfOnlyNumbersIsStillChecked() {
        #expect(SpokenReplyCheck.compare(text: "42.", normalized: nil, heard: "")?.matched == false)
        #expect(SpokenReplyCheck.compare(text: "42.", normalized: nil, heard: "forty two")?.matched == true)
        #expect(SpokenReplyCheck.compare(text: "50%", normalized: nil, heard: "fifty percent")?.matched == true)
    }

    @Test func textWithNothingToSayIsNotChecked() {
        #expect(SpokenReplyCheck.compare(text: "\u{2026}", normalized: nil, heard: "") == nil)
    }

    @Test func theCheckerIsRecordedAndOnlyAMeasuredOneIsCalibrated() throws {
        let ultra = try #require(SpokenReplyCheck.compare(text: "Done.", normalized: nil, heard: "bill", checker: "parakeet-ultra"))
        #expect(ultra.checker == "parakeet-ultra")
        #expect(ultra.calibrated)
        #expect(SpokenReplyCheck.compare(text: "Done.", normalized: nil, heard: "bill", checker: "whisper-large")?.calibrated == false)
        #expect(SpokenReplyCheck.compare(text: "Done.", normalized: nil, heard: "bill")?.calibrated == false)
    }

    @Test func theResultRoundTripsThroughHistory() throws {
        var entry = HistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000), modeName: "Coding agent", heard: "", result: "", outcome: .inserted,
            cloudInvolved: false, redaction: false, contextCategories: [])
        entry.spokenReply = .init(at: Date(timeIntervalSince1970: 1_800_000_000), conversation: "docs", text: "Done.")
        entry.spokenReply?.check = .init(heard: "done", errorRate: 0, checker: "parakeet-ultra")
        entry.spokenReply?.kept = true
        entry.spokenReply?.rendering = .init(voice: "af_heart", sentences: ["Done."])
        let decoded = try HistoryEntry(jsonLine: entry.jsonLine())
        #expect(decoded.spokenReply?.check == entry.spokenReply?.check)
        #expect(decoded.spokenReply?.kept == true)
        #expect(decoded.spokenReply?.rendering == .init(voice: "af_heart", sentences: ["Done."]))
        #expect(try entry.jsonLine().contains("\"error_rate\""))
    }
}

struct SynthesisBaselineTests {
    private func stages(vocoder: Double, tail: Double = 10) -> [SpokenAttempt.Detail] {
        [.init(label: "vocoder", value: String(vocoder)), .init(label: "tail", value: String(tail))]
    }

    @Test func aRenderIsComparedOnlyOnceEnoughRendersAreKnown() {
        var baseline = SynthesisBaseline()
        for _ in 0..<(SynthesisBaseline.minimumRenders - 1) { baseline.record(stages(vocoder: 100), audioSeconds: 2) }
        #expect(baseline.compare(stages(vocoder: 300), audioSeconds: 2).allSatisfy { $0.usualMilliseconds == nil })
        baseline.record(stages(vocoder: 100), audioSeconds: 2)
        let vocoder = baseline.compare(stages(vocoder: 300), audioSeconds: 2).first { $0.stage == "vocoder" }
        #expect(vocoder?.usualMilliseconds == 100)
        #expect(vocoder?.ratio == 3)
    }

    @Test func usualTimingsScaleWithTheAudioLength() {
        var baseline = SynthesisBaseline()
        for _ in 0..<SynthesisBaseline.minimumRenders { baseline.record(stages(vocoder: 100), audioSeconds: 2) }
        let vocoder = baseline.compare(stages(vocoder: 200), audioSeconds: 4).first { $0.stage == "vocoder" }
        #expect(vocoder?.usualMilliseconds == 200)
        #expect(vocoder?.ratio == 1)
    }

    @Test func theUsualTimingIsTheMedianSoOneSlowRenderDoesNotMoveIt() {
        var baseline = SynthesisBaseline()
        for vocoder in [100.0, 100, 100, 100, 900] { baseline.record(stages(vocoder: vocoder), audioSeconds: 1) }
        #expect(baseline.compare(stages(vocoder: 100), audioSeconds: 1).first { $0.stage == "vocoder" }?.usualMilliseconds == 100)
    }

    @Test func onlyTheRecentRendersAreKept() {
        var baseline = SynthesisBaseline()
        for _ in 0..<SynthesisBaseline.window { baseline.record(stages(vocoder: 100), audioSeconds: 1) }
        for _ in 0..<SynthesisBaseline.window { baseline.record(stages(vocoder: 50), audioSeconds: 1) }
        #expect(baseline.compare(stages(vocoder: 50), audioSeconds: 1).first { $0.stage == "vocoder" }?.usualMilliseconds == 50)
    }

    @Test func veryShortAudioIsNotRecorded() {
        var baseline = SynthesisBaseline()
        for _ in 0..<SynthesisBaseline.minimumRenders { baseline.record(stages(vocoder: 100), audioSeconds: 0.2) }
        #expect(baseline.compare(stages(vocoder: 100), audioSeconds: 1).allSatisfy { $0.usualMilliseconds == nil })
    }
}

struct ActivityLogTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func reportsHowLongOtherWorkOverlappedAWindow() {
        var log = ActivityLog()
        let listen = log.begin(.transcription, at: start + 1)
        log.end(listen, at: start + 1.5)
        let recording = log.begin(.recording, at: start + 2)
        let overlaps = log.overlaps(from: start, to: start + 3, now: start + 3)
        #expect(overlaps[.transcription] == 0.5)
        #expect(overlaps[.recording] == 1)
        #expect(overlaps[.aiRequest] == nil)
        log.end(recording, at: start + 4)
    }

    @Test func workThatEndedBeforeTheWindowIsNotCounted() {
        var log = ActivityLog()
        let earlier = log.begin(.aiRequest, at: start)
        log.end(earlier, at: start + 1)
        #expect(log.overlaps(from: start + 2, to: start + 3, now: start + 3).isEmpty)
    }

    @Test func oldFinishedWorkIsForgotten() {
        var log = ActivityLog()
        let old = log.begin(.transcription, at: start)
        log.end(old, at: start + 1)
        _ = log.begin(.recording, at: start + ActivityLog.keptFor + 2)
        #expect(log.overlaps(from: start, to: start + 1, now: start + ActivityLog.keptFor + 2).isEmpty)
    }
}

struct RenderConditionsTests {
    private func conditions(during: [ActivityLog.Kind: TimeInterval] = [:]) -> RenderConditions {
        RenderConditions(
            appUptime: 2 * 3600 + 14 * 60, voiceUptime: 50 * 60, rendersSinceLoad: 37, during: during, thermal: "nominal",
            memoryPressure: "normal", appMemoryMB: 812, loadAverage: 3.25,
            stages: [
                .init(stage: "albert", milliseconds: 20, usualMilliseconds: 19),
                .init(stage: "vocoder", milliseconds: 500, usualMilliseconds: 200),
                .init(stage: "tail", milliseconds: 30, usualMilliseconds: nil),
            ])
    }

    @Test func detailsDescribeTheConditionsInWords() {
        let details = Dictionary(uniqueKeysWithValues: conditions(during: [.transcription: 0.42]).details.map { ($0.label, $0.value) })
        #expect(details["App running for"] == "2 h 14 min")
        #expect(details["Voice loaded for"] == "50 min, 37 renders")
        #expect(details["Also running during this render"] == "speech recognition for 0.4 s")
        #expect(details["Thermal state"] == "nominal")
        #expect(details["Memory"] == "pressure normal, app using 812 MB")
        #expect(details["Load average"] == "3.25")
        #expect(details["Stage timings vs this Mac's usual"] == "albert 20 ms (usual 19, 1.1×), vocoder 500 ms (usual 200, 2.5×), tail 30 ms (no usual yet)")
    }

    @Test func nothingElseRunningIsSaidPlainly() {
        let details = conditions().details
        #expect(details.first { $0.label == "Also running during this render" }?.value == "nothing else in this app")
    }

    @Test func theSlowestStageIsTheOneFurthestAboveUsual() {
        #expect(conditions().slowest?.stage == "vocoder")
    }
}

struct SynthesisBaselineStoreTests {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("baseline.json")
    }

    @Test func theBaselineSurvivesAReload() throws {
        let file = file()
        var baseline = SynthesisBaseline()
        for _ in 0..<SynthesisBaseline.minimumRenders { baseline.record([.init(label: "vocoder", value: "100")], audioSeconds: 1) }
        try SynthesisBaselineStore(file: file).save(baseline)
        #expect(SynthesisBaselineStore(file: file).load() == baseline)
    }

    @Test func aMissingFileIsAnEmptyBaseline() {
        #expect(SynthesisBaselineStore(file: file()).load() == SynthesisBaseline())
    }
}

struct SpokenReplyEvidenceTests {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    private func store() throws -> HistoryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return HistoryStore(supportDir: url)
    }

    @Test func keptFilesLiveInTheEntrysFolderAndRendersAreNumbered() throws {
        let evidence = try store().evidence
        try evidence.save(entry: "e1", at: at, files: [.init(name: "reply.wav", data: Data([1])), .init(name: "reply report.txt", data: Data([2]))])
        let second = try evidence.addRender(entry: "e1", at: at, wav: Data([3]), report: Data([4]))
        let third = try evidence.addRender(entry: "e1", at: at, wav: Data([5]), report: Data([6]))
        #expect(second == 2)
        #expect(third == 3)
        #expect(evidence.renders(entry: "e1", at: at).map(\.lastPathComponent) == ["render 2.wav", "render 3.wav"])
        #expect(evidence.original(entry: "e1", at: at)?.lastPathComponent == "reply.wav")
        #expect(evidence.isKept(entry: "e1", at: at))
    }

    @Test func deletingTheEntryDeletesItsEvidence() throws {
        let store = try store()
        var entry = HistoryEntry(
            id: "e1", timestamp: at, modeName: "Coding agent", heard: "", result: "", outcome: .inserted, cloudInvolved: false,
            redaction: false, contextCategories: [])
        entry.spokenReply = .init(at: at, conversation: "docs", text: "Done.")
        try store.append(entry, today: HistoryStore.todayString(date: at))
        try store.evidence.save(entry: "e1", at: at, files: [.init(name: "reply.wav", data: Data([1]))])
        #expect(store.delete(entry) == .deleted)
        #expect(!store.evidence.isKept(entry: "e1", at: at))
    }

    @Test func retentionDeletesTheEvidenceOfExpiredDays() throws {
        let store = try store()
        let old = HistoryStore.todayString(date: at)
        try FileManager.default.createDirectory(at: store.dir, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: store.dir.appendingPathComponent("\(old).jsonl"))
        try store.evidence.save(entry: "e1", at: at, files: [.init(name: "reply.wav", data: Data([1]))])
        let later = HistoryStore.todayString(date: at + 30 * 86_400)
        store.applyRetention(today: later, retentionDays: 7)
        #expect(!store.evidence.isKept(entry: "e1", at: at))
    }

    private func reply(in store: HistoryStore) throws -> HistoryEntry {
        var entry = HistoryEntry(
            id: "e1", timestamp: at, modeName: "Coding agent", heard: "", result: "", outcome: .inserted, cloudInvolved: false,
            redaction: false, contextCategories: [])
        entry.spokenReply = .init(at: at, conversation: "docs", text: "Done.")
        try store.append(entry, today: HistoryStore.todayString(date: at))
        return entry
    }

    @Test func keepingAReplySavesItsFilesAndMarksTheEntry() throws {
        let store = try store()
        _ = try reply(in: store)
        #expect(store.keepSpokenReply(id: "e1", near: at, files: [.init(name: "reply.wav", data: Data([1]))]) == .saved)
        #expect(store.evidence.isKept(entry: "e1", at: at))
        #expect(store.entries().first?.spokenReply?.kept == true)
        #expect(store.addSpokenRender(id: "e1", near: at, wav: Data([2]), report: Data([3])) == .saved(2))
    }

    @Test func nothingIsWrittenForAnEntryThatWasDeleted() throws {
        let store = try store()
        let entry = try reply(in: store)
        #expect(store.delete(entry) == .deleted)
        #expect(store.keepSpokenReply(id: "e1", near: at, files: [.init(name: "reply.wav", data: Data([1]))]) == .entryGone)
        #expect(store.addSpokenRender(id: "e1", near: at, wav: Data([2]), report: Data([3])) == .entryGone)
        #expect(!store.evidence.isKept(entry: "e1", at: at))
    }

    @Test func nothingIsWrittenForAnEntryRetentionRemoved() throws {
        let store = try store()
        _ = try reply(in: store)
        store.applyRetention(today: HistoryStore.todayString(date: at + 30 * 86_400), retentionDays: 7)
        #expect(store.addSpokenRender(id: "e1", near: at, wav: Data([2]), report: Data([3])) == .entryGone)
        #expect(!store.evidence.isKept(entry: "e1", at: at))
    }

    @Test func retentionKeepsADayWhoseKeptAudioCannotBeRemovedSoItIsTriedAgain() throws {
        let store = try store()
        _ = try reply(in: store)
        #expect(store.keepSpokenReply(id: "e1", near: at, files: [.init(name: "reply.wav", data: Data([1]))]) == .saved)
        let later = HistoryStore.todayString(date: at + 30 * 86_400)
        let folder = store.evidence.folder(entry: "e1", at: at)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        #expect(store.applyRetention(today: later, retentionDays: 7).isEmpty)
        #expect(store.entries().map(\.id) == ["e1"])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("reply.wav").path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        #expect(store.applyRetention(today: later, retentionDays: 7) == ["\(HistoryStore.todayString(date: at)).jsonl"])
        #expect(store.entries().isEmpty)
        #expect(!store.evidence.isKept(entry: "e1", at: at))
    }

    @Test func anEntryWhoseKeptAudioCannotBeRemovedStaysSoTheDeleteCanBeRetried() throws {
        let store = try store()
        let entry = try reply(in: store)
        #expect(store.keepSpokenReply(id: "e1", near: at, files: [.init(name: "reply.wav", data: Data([1]))]) == .saved)
        let folder = store.evidence.folder(entry: "e1", at: at)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        #expect(store.delete(entry) == .writeFailed)
        #expect(store.entries().map(\.id) == ["e1"])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("reply.wav").path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        #expect(store.delete(entry) == .deleted)
        #expect(!store.evidence.isKept(entry: "e1", at: at))
    }

    @Test func historyIgnoresTheEvidenceFolder() throws {
        let store = try store()
        try store.evidence.save(entry: "e1", at: at, files: [.init(name: "reply.wav", data: Data([1]))])
        #expect(store.dayFiles().isEmpty)
    }
}

struct SpokenAttemptReportTests {
    @Test func theReportCarriesEverySentenceTheCheckAndTheConditions() {
        var attempt = SpokenAttempt(id: "a", at: Date(timeIntervalSince1970: 1_800_000_000), text: "One. Two.", voice: "af_heart")
        let measured = SpokenAudioCheck.Measurements(seconds: 1, peak: 0.5, rms: 0.1, clippedSamples: 0)
        let conditions = RenderConditions(
            appUptime: 60, voiceUptime: 30, rendersSinceLoad: 2, during: [:], thermal: "serious", memoryPressure: "warning",
            appMemoryMB: nil, loadAverage: nil, stages: [])
        attempt.segments = [
            .init(text: "One.", synthesis: .init(
                normalizedText: "one", phonemes: "wˈʌn", predictedDurations: [1], stageMilliseconds: [], sampleRate: 24_000,
                measurements: measured, conditions: conditions)),
            .init(text: "Two.", synthesis: .init(
                normalizedText: "two", phonemes: "tˈu", predictedDurations: [2], stageMilliseconds: [], sampleRate: 24_000,
                measurements: measured)),
        ]
        attempt.check = .init(heard: "one blah", errorRate: 0.5, checker: "parakeet-ultra")
        let report = attempt.report(appName: "KeyScribe")
        #expect(report.contains("Sentence 1 of 2: One."))
        #expect(report.contains("Sentence 2 of 2: Two."))
        #expect(report.contains("Phonemes: tˈu"))
        #expect(report.contains("Thermal state: serious"))
        #expect(report.contains(
            "Check of the generated audio by speech recognition (Parakeet Ultra): did not match its text (50% heard), error rate 0.50 · heard: one blah"))
        #expect(report.contains(SpokenAttempt.determinismNote))
        #expect(attempt.synthesis?.phonemes == "wˈʌn")
    }

    @Test func aLaterCheckReplacesTheCheckLineInASavedReport() {
        let first = SpokenReplyCheck.Result(heard: "one blah", errorRate: 0.5, checker: "parakeet-ultra")
        let second = SpokenReplyCheck.Result(heard: "one two", errorRate: 0, checker: "parakeet-ultra")
        var attempt = SpokenAttempt(at: Date(timeIntervalSince1970: 1_800_000_000), text: "One. Two.", voice: "af_heart")
        attempt.check = first
        let saved = attempt.report(appName: "KeyScribe")
        let updated = SpokenAttempt.report(saved, checked: second)
        #expect(!updated.contains("heard: one blah"))
        #expect(updated.contains("Check of the generated audio by speech recognition (Parakeet Ultra): matched its text (100% heard)"))
        #expect(updated.components(separatedBy: "Check of the generated audio").count == 2)
    }

    @Test func aCheckIsAddedToASavedReportThatHadNone() {
        let attempt = SpokenAttempt(at: Date(timeIntervalSince1970: 1_800_000_000), text: "Done.", voice: "af_heart")
        let check = SpokenReplyCheck.Result(heard: "done", errorRate: 0, checker: "parakeet-ultra")
        let updated = SpokenAttempt.report(attempt.report(appName: "KeyScribe"), checked: check)
        #expect(updated.hasPrefix(attempt.report(appName: "KeyScribe").trimmingCharacters(in: .newlines)))
        #expect(updated.hasSuffix("heard: done\n"))
    }
}
