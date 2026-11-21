import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct ScriptedTakeTests {
    final class Microphone: AudioCapturing, @unchecked Sendable {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ks-mic-\(UUID().uuidString).wav")
        private(set) var starts = 0
        private(set) var drains = 0
        func start(sampleRate: Int) async throws -> URL {
            starts += 1
            return file
        }
        func stop() -> URL? { file }
        func finishDraining() async -> URL? {
            drains += 1
            return file
        }
        func takeDrainedSamples() -> [Float]? { [0.5] }
    }

    struct Engine: SpeechEngine {
        var id = "fake"
        var displayName = "Fake"
        var supportsRecognitionBias = false
        var captureSampleRate = 24000
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "heard by the engine" }
        var supportsSampleInput: Bool { true }
        func transcribe(samples: [Float], sampleRate: Int, biasTerms: [String]) async throws -> String { "heard from samples" }
        func evict() async {}
    }

    private func wav(_ text: String = "RIFF") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ks-clip-\(UUID().uuidString).wav")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func speechTool(hangsFirst: Bool, always: Bool = false) throws -> (tool: URL, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ks-say-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let marker = folder.appendingPathComponent("hung").path
        let tool = folder.appendingPathComponent("say")
        let body = always ? "exec sleep 30" : """
            if [ -e "\(marker)" ] || [ \(hangsFirst ? 0 : 1) = 1 ]; then printf clip > "$2"; exit 0; fi
            touch "\(marker)"
            exec sleep 30
            """
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return (tool, folder)
    }

    @Test func aSpeechToolThatStallsOnceIsStoppedAndTheClipIsSpokenAgain() throws {
        let (tool, folder) = try speechTool(hangsFirst: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = folder.appendingPathComponent("take.wav")
        let started = ContinuousClock.now
        #expect(ScriptedTakeCLI.speak("hi", into: clip, using: tool, within: 0.5))
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(FileManager.default.contents(atPath: clip.path) == Data("clip".utf8))
    }

    @Test func aSpeechToolThatKeepsStallingFailsWithinItsBound() throws {
        let (tool, folder) = try speechTool(hangsFirst: true, always: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let started = ContinuousClock.now
        #expect(!ScriptedTakeCLI.speak("hi", into: folder.appendingPathComponent("take.wav"), using: tool, within: 0.5))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func anArmedCaptureServesACopyOfItsClipForOneTakeAndThenTheMicrophoneAgain() async throws {
        let microphone = Microphone()
        let capture = ScriptedCapture(microphone)
        let clip = try wav("clip bytes")
        capture.arm(clip)
        let recorded = try await capture.start(sampleRate: 16000, wantsSamples: true)
        #expect(recorded != clip)
        #expect(try String(contentsOf: recorded, encoding: .utf8) == "clip bytes")
        #expect(await capture.finishDraining() == recorded)
        #expect(capture.takeDrainedSamples() == nil)
        #expect(microphone.starts == 0)
        #expect(FileManager.default.fileExists(atPath: clip.path))
        #expect(try await capture.start(sampleRate: 16000, wantsSamples: true) == microphone.file)
        #expect(await capture.finishDraining() == microphone.file)
        #expect(capture.takeDrainedSamples() == [0.5])
        #expect(microphone.starts == 1)
    }

    @Test func aCancelledScriptedTakeLeavesTheNextTakeOnTheMicrophone() async throws {
        let microphone = Microphone()
        let capture = ScriptedCapture(microphone)
        capture.arm(try wav())
        _ = try await capture.start(sampleRate: 16000, wantsSamples: false)
        _ = capture.stop()
        #expect(try await capture.start(sampleRate: 16000, wantsSamples: false) == microphone.file)
    }

    @Test func anArmedEngineSaysTheTextForOneTakeAndOtherwiseIsTheEngine() async throws {
        let engines = ScriptedEngines()
        let base = Engine()
        engines.arm("tell docs run the tests")
        let scripted = engines.engine(for: base)
        #expect(scripted.id == base.id)
        #expect(scripted.captureSampleRate == base.captureSampleRate)
        #expect(!scripted.supportsSampleInput)
        #expect(try await scripted.transcribe(wavURL: URL(fileURLWithPath: "/x.wav"), biasTerms: []) == "tell docs run the tests")
        let next = engines.engine(for: base)
        #expect(try await next.transcribe(samples: [], sampleRate: 24000, biasTerms: []) == "heard from samples")
    }

    @MainActor class Target: ScriptedTakeTarget {
        var steps: [String] = []
        var recording = false
        var idle = true
        var published = 0
        var outcome: DictationRecord.Outcome? = .inserted
        var receipts = 0
        var receipt: AgentReceipt? = .sent("docs")
        var recipient: ScriptedTakeRecipient? = ScriptedTakeRecipient(conversation: "claude:abc-123", agent: "claude", request: "req-1")
        var hudSays: String? = "Sent to docs"
        var modes = ["agent-mode": ScriptedTakeMode(id: "agent-mode", sendsToAgents: true), "": ScriptedTakeMode(id: "agent-mode", sendsToAgents: true)]
        func scriptedTakeMode(_ named: String?) -> ScriptedTakeMode? { modes[named ?? ""] }
        func setNextModeOverride(id: String?) { steps.append("mode \(id ?? "-")") }
        func pressForScriptedTake() {
            steps.append("press")
            idle = false
            recording = true
        }
        func releaseForScriptedTake() {
            steps.append("release")
            recording = false
        }
        var isRecordingForScriptedTake: Bool { recording }
        var isIdleForScriptedTake: Bool { idle }
        func finishScriptedTake() async {
            steps.append("finish")
            idle = true
            published += 1
            receipts += receipt == nil ? 0 : 1
        }
        var scriptedTakeMarks: ScriptedTakeMarks {
            var record = DictationRecord(modeName: "Agent")
            record.outcome = outcome
            return ScriptedTakeMarks(records: published, record: record, receipts: receipts, receipt: receipt, recipient: recipient, hud: hudSays)
        }
    }

    @Test func aDeliveredTakeReportsTheConversationAndAgentItReachedAndTheKindOfReceipt() async throws {
        let target = Target()
        let runner = ScriptedTakeRunner(target: target, capture: ScriptedCapture(Microphone()), engines: ScriptedEngines(), pause: .milliseconds(1))
        let result = try await take(runner, ScriptedTakeRequest(id: "d1", wav: try wav().path, transcript: "tell docs hi", mode: nil, caller: getpid(), issued: Date()))
        #expect(result.conversation == "claude:abc-123")
        #expect(result.agent == "claude")
        #expect(result.receiptKind == "sent")
    }

    @Test func aRefusedTakeStillNamesTheConversationItWasMeantFor() async throws {
        let target = Target()
        target.receipt = .notSent("docs", reason: .disconnected)
        target.outcome = .failed
        let runner = ScriptedTakeRunner(target: target, capture: ScriptedCapture(Microphone()), engines: ScriptedEngines(), pause: .milliseconds(1))
        let result = try await take(runner, ScriptedTakeRequest(id: "d2", wav: try wav().path, transcript: "tell docs hi", mode: nil, caller: getpid(), issued: Date()))
        #expect(result.receiptKind == "notSent")
        #expect(result.conversation == "claude:abc-123")
    }

    @Test func aTakeWithNoNewReceiptReportsNoConversationFromAnEarlierTake() async throws {
        let target = Target()
        target.receipt = nil
        let runner = ScriptedTakeRunner(target: target, capture: ScriptedCapture(Microphone()), engines: ScriptedEngines(), pause: .milliseconds(1))
        let result = try await take(runner, ScriptedTakeRequest(id: "d3", wav: try wav().path, transcript: "x", mode: nil, caller: getpid(), issued: Date()))
        #expect(result.conversation == nil)
        #expect(result.agent == nil)
        #expect(result.receiptKind == nil)
    }

    @Test func anAgentCommandSucceedsWithoutAMessageReceipt() async throws {
        let target = Target()
        target.receipt = nil
        target.outcome = .command
        let runner = ScriptedTakeRunner(target: target, capture: ScriptedCapture(Microphone()), engines: ScriptedEngines(), pause: .milliseconds(1))
        let result = try await take(runner, ScriptedTakeRequest(id: "command", wav: try wav().path, transcript: "check on docs", mode: nil, caller: getpid(), issued: Date()))
        #expect(result.ok)
        #expect(result.problem == nil)
        #expect(result.conversation == nil)
        #expect(result.receipt == nil)
    }

    @Test func everyReceiptHasAStableKindName() {
        let kinds: [(AgentReceipt, String)] = [
            (.sent("a"), "sent"), (.sentWithDraft("a"), "sentWithDraft"), (.queued("a"), "queued"),
            (.kept("a", reason: .composing), "kept"), (.notSent(nil, reason: .stopped), "notSent"), (.uncertain("a"), "uncertain"),
        ]
        for (receipt, kind) in kinds { #expect(ScriptedTakeRunner.kind(of: receipt) == kind) }
    }

    @Test func aDeliveredTakeReportsTheRequestItWasSentAs() async throws {
        let target = Target()
        let runner = ScriptedTakeRunner(target: target, capture: ScriptedCapture(Microphone()), engines: ScriptedEngines(), pause: .milliseconds(1))
        let result = try await take(runner, ScriptedTakeRequest(id: "w0", wav: try wav().path, transcript: "x", mode: nil, caller: getpid(), issued: Date()))
        #expect(result.request == "req-1")
        #expect(result.reply == nil)
    }

    @Test func aTakeThatWaitsForItsReplyReportsTheReplyToItsOwnRequestOnly() async throws {
        final class Replying: Target {
            var replies: ScriptedReplies?
            override func finishScriptedTake() async {
                await super.finishScriptedTake()
                replies?.noteAnswer(origin: "someone-else", answer: "not this one")
                replies?.noteAnswer(origin: "req-1", answer: "All four tests pass.")
            }
        }
        let target = Replying()
        let replies = ScriptedReplies()
        target.replies = replies
        let runner = ScriptedTakeRunner(
            target: target, capture: ScriptedCapture(Microphone()), engines: ScriptedEngines(), pause: .milliseconds(1), replies: replies)
        var request = ScriptedTakeRequest(id: "w1", wav: try wav().path, transcript: "x", mode: nil, caller: getpid(), issued: Date())
        request.waitReply = 5
        let result = try await take(runner, request)
        let reply = try #require(result.reply)
        #expect(reply.kind == "answer")
        #expect(reply.length == "All four tests pass.".count)
        #expect(reply.sha256 == ScriptedReplies.digest("All four tests pass."))
        #expect(result.ok)
    }

    @Test func aReplyThatNeverComesIsReportedAsMissingWithoutFailingTheDelivery() async throws {
        let target = Target()
        let runner = ScriptedTakeRunner(
            target: target, capture: ScriptedCapture(Microphone()), engines: ScriptedEngines(), pause: .milliseconds(1), replies: ScriptedReplies())
        var request = ScriptedTakeRequest(id: "w2", wav: try wav().path, transcript: "x", mode: nil, caller: getpid(), issued: Date())
        request.waitReply = 0.1
        let result = try await take(runner, request)
        #expect(result.ok)
        #expect(result.reply == nil)
        #expect(result.replyProblem == "No reply within 0.1 s.")
    }

    @Test func aTakeThatWasNotDeliveredDoesNotWaitForAReply() async throws {
        let target = Target()
        target.receipt = .notSent("docs", reason: .disconnected)
        target.outcome = .failed
        let runner = ScriptedTakeRunner(
            target: target, capture: ScriptedCapture(Microphone()), engines: ScriptedEngines(), pause: .milliseconds(1), replies: ScriptedReplies())
        var request = ScriptedTakeRequest(id: "w3", wav: try wav().path, transcript: "x", mode: nil, caller: getpid(), issued: Date())
        request.waitReply = 30
        let started = ContinuousClock.now
        let result = try await take(runner, request)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(result.reply == nil)
    }

    @Test func anEndingIsReportedByItsFixedWordingAndAnAnswerOnlyByDigest() {
        let replies = ScriptedReplies()
        replies.noteEnded(origin: "a", body: "Stopped.")
        replies.noteAnswer(origin: "b", answer: "secret reply text")
        #expect(replies.reply(for: "a") == ScriptedReply(kind: "ended", length: 8, sha256: ScriptedReplies.digest("Stopped."), ending: "Stopped."))
        #expect(replies.reply(for: "b")?.ending == nil)
        #expect(ScriptedReplies.digest("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func repliesAreKeptOnlyForTheMostRecentRequests() {
        let replies = ScriptedReplies(limit: 2)
        replies.noteAnswer(origin: "1", answer: "a")
        replies.noteAnswer(origin: "2", answer: "b")
        replies.noteAnswer(origin: "3", answer: "c")
        #expect(replies.reply(for: "1") == nil)
        #expect(replies.reply(for: "3") != nil)
    }

    @Test func theJSONLineIsTheWholeResultAndTheTextLineIsUnchanged() throws {
        let result = ScriptedTakeResult(
            id: "j1", ok: true, outcome: "inserted", receipt: "sent(\"docs\")", receiptKind: "sent", conversation: "claude:abc-123", agent: "claude",
            request: "req-1", reply: ScriptedReply(kind: "answer", length: 3, sha256: "x", ending: nil), hud: "Sent to docs", problem: nil)
        let json = ScriptedTakeCLI.line(for: result, json: true)
        #expect(try JSONDecoder().decode(ScriptedTakeResult.self, from: Data(json.utf8)) == result)
        #expect(!json.contains("\n"))
        #expect(ScriptedTakeCLI.line(for: result, json: false) == "agent-take: inserted \u{2014} sent(\"docs\") \u{2014} Sent to docs")
    }

    @Test func aScriptedTakePressesInTheChosenModeRecordsThenReleasesAndReportsWhatTheHudSaid() async throws {
        let target = Target()
        let capture = ScriptedCapture(Microphone())
        let engines = ScriptedEngines()
        let runner = ScriptedTakeRunner(target: target, capture: capture, engines: engines, pause: .milliseconds(1))
        let result = try await take(runner, ScriptedTakeRequest(id: "r1", wav: try wav().path, transcript: "tell docs hi", mode: "agent-mode", caller: getpid(), issued: Date()))
        #expect(target.steps == ["mode agent-mode", "press", "release", "finish"])
        #expect(result.ok)
        #expect(result.hud == "Sent to docs")
        #expect(result.outcome == "inserted")
        #expect(result.receipt == "sent(\"docs\")")
    }

    @Test func aScriptedTakeIsRefusedWhileADictationRuns() async throws {
        let target = Target()
        target.idle = false
        let runner = ScriptedTakeRunner(target: target, capture: ScriptedCapture(Microphone()), engines: ScriptedEngines(), pause: .milliseconds(1))
        let result = try await take(runner, ScriptedTakeRequest(id: "r2", wav: try wav().path, transcript: nil, mode: nil, caller: getpid(), issued: Date()))
        #expect(!result.ok)
        #expect(result.problem == "A dictation is already running.")
        #expect(target.steps.isEmpty)
    }

    @Test func aMissingClipIsRefusedBeforePressing() async throws {
        let target = Target()
        let runner = ScriptedTakeRunner(target: target, capture: ScriptedCapture(Microphone()), engines: ScriptedEngines(), pause: .milliseconds(1))
        let result = try await take(runner, ScriptedTakeRequest(id: "r3", wav: "/no/such/clip.wav", transcript: nil, mode: nil, caller: getpid(), issued: Date()))
        #expect(!result.ok)
        #expect(target.steps.isEmpty)
    }

    @Test func aTakeThatNeverStartsRecordingIsReleasedAndReported() async throws {
        final class Stuck: Target {
            override func pressForScriptedTake() { steps.append("press") }
        }
        let stuck = Stuck()
        let runner = ScriptedTakeRunner(
            target: stuck, capture: ScriptedCapture(Microphone()), engines: ScriptedEngines(), pause: .milliseconds(1), recordingWithin: .milliseconds(30))
        let result = try await take(runner, ScriptedTakeRequest(id: "r4", wav: try wav().path, transcript: nil, mode: nil, caller: getpid(), issued: Date()))
        #expect(!result.ok)
        #expect(result.problem == "The take never started recording.")
        #expect(stuck.steps == ["mode agent-mode", "press", "release"])
    }

    @Test func aTakeWhoseAgentDidNotGetItIsNotOk() async throws {
        let target = Target()
        target.receipt = .notSent("docs", reason: .disconnected)
        target.outcome = .failed
        let runner = ScriptedTakeRunner(target: target, capture: ScriptedCapture(Microphone()), engines: ScriptedEngines(), pause: .milliseconds(1))
        let result = try await take(runner, ScriptedTakeRequest(id: "n1", wav: try wav().path, transcript: "tell docs hi", mode: nil, caller: getpid(), issued: Date()))
        #expect(!result.ok)
        #expect(result.problem == "The take did not deliver.")
    }

    @Test func anAgentTakeThatEndedWithoutAReceiptIsNotOkButAPlainTakeIs() async throws {
        let target = Target()
        target.receipt = nil
        let runner = ScriptedTakeRunner(target: target, capture: ScriptedCapture(Microphone()), engines: ScriptedEngines(), agentModesOnly: false, pause: .milliseconds(1))
        #expect(!(try await take(runner, ScriptedTakeRequest(id: "q1", wav: try wav().path, transcript: "x", mode: nil, caller: getpid(), issued: Date()))).ok)
        target.modes["plain"] = ScriptedTakeMode(id: "plain", sendsToAgents: false)
        #expect(try await take(runner, ScriptedTakeRequest(id: "q2", wav: try wav().path, transcript: "x", mode: "plain", caller: getpid(), issued: Date())).ok)
    }

    @Test func aBuildLimitedToAgentModesRefusesAPlainModeBeforePressingAndStillTakesAnAgentMode() async throws {
        let target = Target()
        target.modes["plain"] = ScriptedTakeMode(id: "plain", sendsToAgents: false)
        let runner = ScriptedTakeRunner(
            target: target, capture: ScriptedCapture(Microphone()), engines: ScriptedEngines(), agentModesOnly: true, pause: .milliseconds(1))
        let plain = try await take(runner, ScriptedTakeRequest(id: "q1", wav: try wav().path, transcript: "x", mode: "plain", caller: getpid(), issued: Date()))
        #expect(!plain.ok)
        #expect(plain.problem == "This build makes scripted takes only in a mode that sends to agents, and \u{201C}plain\u{201D} doesn\u{2019}t.")
        #expect(target.steps.isEmpty)
        #expect(try await take(runner, ScriptedTakeRequest(id: "q2", wav: try wav().path, transcript: "x", mode: "agent-mode", caller: getpid(), issued: Date())).ok)
    }

    @Test func aRequestWhoseCommandHasExitedIsNeitherTakenNorAnswered() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ks-inbox-\(UUID().uuidString)", isDirectory: true)
        let target = Target()
        let inbox = ScriptedTakeInbox(
            folder: folder, runner: ScriptedTakeRunner(target: target, capture: ScriptedCapture(Microphone()), engines: ScriptedEngines(), pause: .milliseconds(1)))
        inbox.start()
        defer {
            inbox.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try ended.run()
        ended.waitUntilExit()
        let gone = ScriptedTakeRequest(id: "gone", wav: try wav().path, transcript: "x", mode: nil, caller: ended.processIdentifier, issued: Date())
        try JSONEncoder().encode(gone).write(to: folder.appendingPathComponent("gone.request.json"))
        for _ in 0..<200 where FileManager.default.fileExists(atPath: folder.appendingPathComponent("gone.request.json").path) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(target.steps.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func aRequestWhoseCommandStoppedWaitingIsNotTaken() async throws {
        let target = Target()
        let runner = ScriptedTakeRunner(
            target: target, capture: ScriptedCapture(Microphone()), engines: ScriptedEngines(), pause: .milliseconds(1), callerWaits: { _, _ in false })
        #expect(await runner.run(ScriptedTakeRequest(id: "c1", wav: try wav().path, transcript: "x", mode: nil, caller: 42, issued: Date())) == nil)
        #expect(target.steps.isEmpty)
    }

    @Test func aCallerWaitsOnlyWhileItsOwnProcessRuns() throws {
        #expect(ScriptedTakeRunner.callerWaits(getpid(), issued: Date()))
        #expect(!ScriptedTakeRunner.callerWaits(getpid(), issued: Date(timeIntervalSince1970: 0)))
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try ended.run()
        ended.waitUntilExit()
        #expect(!ScriptedTakeRunner.callerWaits(ended.processIdentifier, issued: Date()))
    }

    @Test func aTakeHeldForTheAgentIsNotYetDelivered() async throws {
        let target = Target()
        target.receipt = .queued("docs", waitingOn: .working)
        let runner = ScriptedTakeRunner(target: target, capture: ScriptedCapture(Microphone()), engines: ScriptedEngines(), pause: .milliseconds(1))
        #expect(!(try await take(runner, ScriptedTakeRequest(id: "n2", wav: try wav().path, transcript: "x", mode: nil, caller: getpid(), issued: Date()))).ok)
    }

    @Test func aTakeThatPublishedNoRecordIsNotOkAndAnOlderRecordIsNotReported() async throws {
        final class Silent: Target {
            override func finishScriptedTake() async {
                steps.append("finish")
                idle = true
            }
        }
        let target = Silent()
        target.published = 3
        let runner = ScriptedTakeRunner(target: target, capture: ScriptedCapture(Microphone()), engines: ScriptedEngines(), pause: .milliseconds(1))
        let result = try await take(runner, ScriptedTakeRequest(id: "n3", wav: try wav().path, transcript: "x", mode: nil, caller: getpid(), issued: Date()))
        #expect(!result.ok)
        #expect(result.outcome == nil)
        #expect(result.problem == "The take finished without a result.")
    }

    @Test func aPressThatFailsEarlyStopsWaitingAtOnceAndLeavesNothingArmed() async throws {
        final class Refusing: Target {
            override func pressForScriptedTake() {
                steps.append("press")
                published += 1
            }
        }
        let target = Refusing()
        target.outcome = .failed
        let engines = ScriptedEngines()
        let capture = ScriptedCapture(Microphone())
        let runner = ScriptedTakeRunner(target: target, capture: capture, engines: engines, pause: .milliseconds(1), recordingWithin: .seconds(30))
        let started = ContinuousClock.now
        let result = try await take(runner, ScriptedTakeRequest(id: "n4", wav: try wav().path, transcript: "armed text", mode: nil, caller: getpid(), issued: Date()))
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(!result.ok)
        #expect(result.outcome == "failed")
        #expect(try await engines.engine(for: Engine()).transcribe(wavURL: URL(fileURLWithPath: "/x.wav"), biasTerms: []) == "heard by the engine")
        #expect(try await capture.start(sampleRate: 16000, wantsSamples: false).lastPathComponent.hasPrefix("ks-mic-"))
    }

    @Test func requestsLeftFromAnEarlierRunAreDroppedAtLaunchNotTaken() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ks-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stale = ScriptedTakeRequest(id: "old", wav: try wav().path, transcript: "tell docs rm everything", mode: nil, caller: getpid(), issued: Date())
        try JSONEncoder().encode(stale).write(to: folder.appendingPathComponent("old.request.json"))
        try Data().write(to: folder.appendingPathComponent("old.pending"))
        try Data().write(to: folder.appendingPathComponent("older.result.json"))
        let target = Target()
        let inbox = ScriptedTakeInbox(
            folder: folder, runner: ScriptedTakeRunner(target: target, capture: ScriptedCapture(Microphone()), engines: ScriptedEngines(), pause: .milliseconds(1)))
        inbox.start()
        defer { inbox.stop() }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(target.steps.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func aBuildWithoutTheDevelopmentToolsSendsNoScriptedTake() {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("ks-support-\(UUID().uuidString)", isDirectory: true)
        #expect(ScriptedTakeCLI.run(text: "hi", wav: nil, mode: nil, timeout: 1, supportDir: support, allowed: false) == 2)
        #expect(!FileManager.default.fileExists(atPath: support.path))
    }

    @Test func aModeThatDoesNotExistIsRefusedBeforePressing() async throws {
        let target = Target()
        let runner = ScriptedTakeRunner(target: target, capture: ScriptedCapture(Microphone()), engines: ScriptedEngines(), pause: .milliseconds(1))
        let result = try await take(runner, ScriptedTakeRequest(id: "r6", wav: try wav().path, transcript: nil, mode: "Nope", caller: getpid(), issued: Date()))
        #expect(result.problem == "No enabled mode is named \u{201C}Nope\u{201D}.")
        #expect(target.steps.isEmpty)
    }

    private func take(_ runner: ScriptedTakeRunner, _ request: ScriptedTakeRequest) async throws -> ScriptedTakeResult {
        try #require(await runner.run(request))
    }

    @Test func requestsAndResultsRoundTripAsJSON() throws {
        let request = ScriptedTakeRequest(id: "r5", wav: "/a.wav", transcript: "hi", mode: "Agent", caller: getpid(), issued: Date())
        #expect(try JSONDecoder().decode(ScriptedTakeRequest.self, from: JSONEncoder().encode(request)) == request)
        let result = ScriptedTakeResult(id: "r5", ok: true, outcome: "sent", hud: "Sent to docs", problem: nil)
        #expect(try JSONDecoder().decode(ScriptedTakeResult.self, from: JSONEncoder().encode(result)) == result)
    }
}
