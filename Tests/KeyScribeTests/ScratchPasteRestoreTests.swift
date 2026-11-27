import AppKit
import os
import KeyScribeKit
import Foundation
import Testing
@testable import KeyScribeApp

// A paste that detaches its clipboard-restore (awaitSettle: false, the fast dictation path) must not let
// the next paste snapshot its still-present scratch text as the user's clipboard — otherwise that scratch
// text (which can hold a just-restored redacted span) gets restored back and persists. Runs against a
// PRIVATE pasteboard (no real clipboard, no synthesized ⌘V). Serialized because the coordinator keeps
// process-wide pending-restore state the dictation state machine only ever touches one at a time.
final class LateReads: @unchecked Sendable {
    private let lock = NSLock()
    private var read: [String] = []
    var texts: [String] { lock.withLock { read } }

    func read(_ name: String, after delay: Duration) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            let text = NSPasteboard(name: NSPasteboard.Name(name)).string(forType: .string) ?? ""
            self.lock.withLock { self.read.append(text) }
        }
    }

    func settled(count: Int) async {
        for _ in 0..<500 where texts.count < count { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

@MainActor
@Suite(.serialized)
struct ScratchPasteRestoreTests {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("keyscribe-test-\(UUID().uuidString)"))
    }

    @Test func detachedRestoreIsDrainedBeforeTheNextPasteSnapshots() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let first = await TextInserter.beginScratchPaste("dictationA", on: pb)
        #expect(first != nil)
        #expect(pb.string(forType: .string) == "dictationA")
        await TextInserter.settleScratch(first!, awaitSettle: false)

        let second = await TextInserter.beginScratchPaste("dictationB", on: pb)
        #expect(second != nil)
        await TextInserter.settleScratch(second!, awaitSettle: true)
        await TextInserter.drainPendingRestore()

        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    @Test func aSubmitSettleRestoresTheUserClipboardInTheBackground() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb)
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: true)
        await TextInserter.drainPendingRestore()

        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    @Test func aCopyLandingDuringCaptureIsPreservedNotClobbered() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        var fired = false
        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb, afterCapture: {
            if !fired { fired = true; pb.clearContents(); pb.setString("USER_COPIED_LATE", forType: .string) }
        })
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: true)
        await TextInserter.drainPendingRestore()

        #expect(pb.string(forType: .string) == "USER_COPIED_LATE")
    }

    @Test func repeatedCopiesDuringCaptureStabilizeToTheLatest() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("ORIGINAL", forType: .string)

        let values = ["COPY_1", "COPY_2"]
        var i = 0
        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb, afterCapture: {
            if i < values.count { pb.clearContents(); pb.setString(values[i], forType: .string); i += 1 }
        })
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: true)
        await TextInserter.drainPendingRestore()

        #expect(pb.string(forType: .string) == "COPY_2")
    }

    @Test func theBackstopRestoresAtTheConfiguredDelay() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb)
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: false)
        #expect(pb.string(forType: .string) == "dictation")

        #expect(await restores(pb, to: "USER_ORIGINAL", withinMs: 900))
    }

    @Test func aLongerConfiguredDelayHoldsTheScratchLonger() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb)
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: false, restoreMs: 3000)

        try? await Task.sleep(for: .milliseconds(700))
        #expect(pb.string(forType: .string) == "dictation")
        await TextInserter.drainPendingRestore()
        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    @Test func readingTheClipboardDrainsAPendingRestore() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb)
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: false)

        #expect(TextInserter.currentClipboardText(on: pb) == "USER_ORIGINAL")
    }

    private func restores(_ pb: NSPasteboard, to expected: String, withinMs: Int) async -> Bool {
        var waited = 0
        while waited < withinMs {
            if pb.string(forType: .string) == expected { return true }
            try? await Task.sleep(for: .milliseconds(20))
            waited += 20
        }
        return pb.string(forType: .string) == expected
    }

    // The scratch is published as a LAZY `.string` flavor, so the target reading it is observable and the
    // clipboard can come back as soon as the paste has actually been served, instead of after a fixed
    // guess. The read through this pasteboard handle stands in for the target app's read. These live in
    // this suite rather than their own because the pending-restore state is process-wide and suites run
    // in parallel.

    @Test func aReadServesTheDictationAndRestoresWellBeforeTheBackstop() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb, lazy: true)
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: false, restoreMs: 5000)

        #expect(pb.string(forType: .string) == "dictation")     // the target's paste is served the dictation
        #expect(await restores(pb, to: "USER_ORIGINAL", withinMs: 1000))
    }

    @Test func aSecondReadInsideTheGraceStillGetsTheDictation() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb, lazy: true)
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: false, restoreMs: 5000)

        #expect(pb.string(forType: .string) == "dictation")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(pb.string(forType: .string) == "dictation")
    }

    @Test func aReadBeforeThePasteDoesNotShortenTheHold() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb, lazy: true)
        #expect(scratch != nil)
        #expect(pb.string(forType: .string) == "dictation")     // the pre-⌘V inspection

        await TextInserter.settleScratch(
            scratch!, awaitSettle: false, restoreMs: 5000,
            pastedAt: ContinuousClock.now.advanced(by: .milliseconds(400)))

        try? await Task.sleep(for: .milliseconds(300))
        #expect(pb.string(forType: .string) == "dictation")
        await TextInserter.drainPendingRestore()
        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    @Test func noReadFallsBackToTheConfiguredBackstop() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb, lazy: true)
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: false, restoreMs: 250)

        try? await Task.sleep(for: .milliseconds(600))
        #expect(scratch!.provider?.firstReadAt == nil)
        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    @Test func aCopyBeforeTheRestoreIsPreserved() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb, lazy: true)
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: false, restoreMs: 5000)

        pb.clearContents()
        pb.setString("USER_COPIED", forType: .string)
        await TextInserter.drainPendingRestore()

        #expect(pb.string(forType: .string) == "USER_COPIED")
    }

    @Test func withoutTheFlagTheScratchIsEagerAndTimerDriven() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb)
        #expect(scratch != nil)
        await TextInserter.settleScratch(scratch!, awaitSettle: false, restoreMs: 3000)

        #expect(pb.string(forType: .string) == "dictation")
        try? await Task.sleep(for: .milliseconds(400))
        #expect(pb.string(forType: .string) == "dictation")     // a read did not shorten it
        await TextInserter.drainPendingRestore()
        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    @Test func aPersistentlyUnstableClipboardFailsClosedWithoutClobbering() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("CHURN_0", forType: .string)

        var n = 0
        let scratch = await TextInserter.beginScratchPaste("dictation", on: pb, afterCapture: {
            n += 1; pb.clearContents(); pb.setString("CHURN_\(n)", forType: .string)
        })
        #expect(scratch == nil)
        #expect(pb.string(forType: .string)?.hasPrefix("CHURN_") == true)
    }


    private func unpostable() throws -> ClipboardPaste {
        ClipboardPaste(keystroke: try ClipboardKeystroke(parsing: "control+☃"))
    }

    @Test func aPasteChordThatCannotBePostedReportsFailure() async throws {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        let landed = await TextInserter.insertViaPaste("dictated", paste: try unpostable(), on: pb)
        #expect(!landed)
    }

    @Test func aFailedPasteRestoresTheUserClipboard() async throws {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        _ = await TextInserter.insertViaPaste("dictated", paste: try unpostable(), on: pb)
        await TextInserter.drainPendingRestore()
        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    private func pasteCountingCaptures(_ text: String, on pb: NSPasteboard) async -> (TextInserter.ScratchPaste?, Int) {
        var captures = 0
        let scratch = await TextInserter.beginScratchPaste(text, on: pb, afterCapture: { captures += 1 })
        return (scratch, captures)
    }

    @Test func aClipboardSnapshotTakenDuringTranscriptionIsUsedForThePaste() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        await TextInserter.prefetchSnapshot(on: pb).value
        let (scratch, captures) = await pasteCountingCaptures("dictation", on: pb)
        #expect(captures == 0)
        await TextInserter.settleScratch(scratch!, awaitSettle: true)
        await TextInserter.drainPendingRestore()
        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    @Test func aCopyAfterTheEarlySnapshotForcesAFreshOne() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        await TextInserter.prefetchSnapshot(on: pb).value
        pb.clearContents()
        pb.setString("USER_COPIED_LATER", forType: .string)
        let (scratch, captures) = await pasteCountingCaptures("dictation", on: pb)
        #expect(captures == 1)
        await TextInserter.settleScratch(scratch!, awaitSettle: true)
        await TextInserter.drainPendingRestore()
        #expect(pb.string(forType: .string) == "USER_COPIED_LATER")
    }

    @Test func theEarlySnapshotDrainsTheLastPastesPendingRestoreFirst() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)
        let first = await TextInserter.beginScratchPaste("dictationA", on: pb)
        await TextInserter.settleScratch(first!, awaitSettle: false)

        await TextInserter.prefetchSnapshot(on: pb).value
        let (second, _) = await pasteCountingCaptures("dictationB", on: pb)
        await TextInserter.settleScratch(second!, awaitSettle: true)
        await TextInserter.drainPendingRestore()
        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    @Test func anEarlySnapshotServesOnePasteOnly() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        await TextInserter.prefetchSnapshot(on: pb).value
        let (first, _) = await pasteCountingCaptures("dictationA", on: pb)
        await TextInserter.settleScratch(first!, awaitSettle: true)
        await TextInserter.drainPendingRestore()
        let (second, captures) = await pasteCountingCaptures("dictationB", on: pb)
        #expect(captures == 1)
        await TextInserter.settleScratch(second!, awaitSettle: true)
        await TextInserter.drainPendingRestore()
    }

    @Test func anEarlySnapshotOfAnotherPasteboardIsNotUsed() async {
        let other = makePasteboard()
        other.clearContents()
        other.setString("OTHER", forType: .string)
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        await TextInserter.prefetchSnapshot(on: other).value
        let (scratch, captures) = await pasteCountingCaptures("dictation", on: pb)
        #expect(captures == 1)
        await TextInserter.settleScratch(scratch!, awaitSettle: true)
        await TextInserter.drainPendingRestore()
        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
        TextInserter.discardPrefetchedSnapshot()
    }

    @Test func aDiscardedEarlySnapshotIsNotUsed() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        await TextInserter.prefetchSnapshot(on: pb).value
        TextInserter.discardPrefetchedSnapshot()
        let (scratch, captures) = await pasteCountingCaptures("dictation", on: pb)
        #expect(captures == 1)
        await TextInserter.settleScratch(scratch!, awaitSettle: true)
        await TextInserter.drainPendingRestore()
    }

    private final class OneLineEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias = false
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
            try await Task.sleep(for: .milliseconds(50))
            return "hello there"
        }
        func evict() async {}
    }

    private final class SilentAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
    }

    @Test func aTakesEarlySnapshotReachesItsPasteThroughTheController() async throws {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-prefetch-take-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("modes", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
        var captures = 0
        var pasted: String?
        let controller = DictationController(
            settings: settings, provider: try SpeechEngineProvider(engines: [OneLineEngine()], activeId: "fixed"),
            config: ConfigCache(supportDir: dir), history: HistoryStore(supportDir: dir), hud: nil,
            permits: { _ in true }, audio: SilentAudio(url: dir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, text, _ in
                guard let scratch = await TextInserter.beginScratchPaste(text, on: pb, afterCapture: { captures += 1 })
                else { return false }
                pasted = pb.string(forType: .string)
                await TextInserter.settleScratch(scratch, awaitSettle: true)
                return true
            },
            snapshot: { TargetSnapshot(bundleId: "test.bundle", pid: 100) },
            micStatus: { .granted },
            accessibilityGranted: { true },
            prefetchClipboard: { TextInserter.prefetchSnapshot(on: pb) },
            discardPrefetchedClipboard: { TextInserter.discardPrefetchedSnapshot() })

        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value
        await TextInserter.drainPendingRestore()
        #expect(pasted?.trimmingCharacters(in: .whitespaces) == "hello there")
        #expect(captures == 0)
        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    @Test func aPrefetchDiscardedWhileItReadsLeavesNothingForThePaste() async throws {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        let source = try await SlowPasteboardSource(on: pb, delay: 0.5)
        defer { source.stop() }
        let prefetch = TextInserter.PasteboardSnapshot.$readBudgetSeconds.withValue(30) {
            TextInserter.prefetchSnapshot(on: pb, helper: PasteboardReaderTests.helper)
        }
        try await source.until("rendering")
        TextInserter.discardPrefetchedSnapshot()

        let (scratch, captures) = await pasteCountingCaptures("dictation", on: pb)
        if let scratch { await TextInserter.settleScratch(scratch, awaitSettle: false) }
        await TextInserter.drainPendingRestore()
        _ = await prefetch.value

        #expect(captures == 1)
    }

    @Test func aSecondPasteDuringTheFirstsClipboardReadWaitsAndRestoresTheUsersClipboard() async throws {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        let source = try await SlowPasteboardSource(on: pb, delay: 0.6)
        defer { source.stop() }
        let helper = PasteboardReaderTests.helper
        let keys = OSAllocatedUnfairLock(initialState: 0)

        await TextInserter.PasteboardSnapshot.$readBudgetSeconds.withValue(30) {
            await TextInserter.$frontmostApp.withValue({ 1 }) {
                await TextInserter.$keystrokeSink.withValue({ _ in keys.withLock { $0 += 1 } }) {
                    let first = Task { await TextInserter.insertViaPaste("dictationA", awaitSettle: false, on: pb, helper: helper) }
                    try? await source.until("rendering")
                    let second = Task { await TextInserter.insertViaPaste("dictationB", awaitSettle: false, on: pb, helper: helper) }
                    #expect(await first.value)
                    #expect(await second.value)
                }
            }
        }
        await TextInserter.drainPendingRestore()

        #expect(keys.withLock { $0 } == 2)
        #expect(pb.string(forType: .string) == "plain fallback")
        #expect(pb.data(forType: SlowPasteboardSource.slowType) == Data("slow bytes".utf8))
    }

    @Test func aTargetThatReadsThePasteLateStillGetsThatPastesText() async {
        let name = "keyscribe-test-\(UUID().uuidString)"
        let pb = NSPasteboard(name: NSPasteboard.Name(name))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)
        let late = LateReads()

        await TextInserter.PasteboardSnapshot.$readBudgetSeconds.withValue(30) {
            await TextInserter.$frontmostApp.withValue({ 1 }) {
                await TextInserter.$keystrokeSink.withValue({ _ in late.read(name, after: .milliseconds(100)) }) {
                    let first = Task {
                        await TextInserter.insertViaPaste("dictationA", awaitSettle: false, on: pb, helper: PasteboardReaderTests.helper)
                    }
                    let second = Task {
                        await TextInserter.insertViaPaste("dictationB", awaitSettle: false, on: pb, helper: PasteboardReaderTests.helper)
                    }
                    #expect(await first.value)
                    #expect(await second.value)
                }
            }
        }
        await late.settled(count: 2)
        await TextInserter.drainPendingRestore()

        #expect(late.texts == ["dictationA", "dictationB"])
        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    @Test func anotherAppInFrontAfterTheReadSkipsThePaste() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)
        let asked = OSAllocatedUnfairLock(initialState: Int32(0))
        let keys = OSAllocatedUnfairLock(initialState: 0)

        let pasted = await TextInserter.$frontmostApp.withValue({ asked.withLock { $0 += 1; return $0 } }) {
            await TextInserter.$keystrokeSink.withValue({ _ in keys.withLock { $0 += 1 } }) {
                await TextInserter.insertViaPaste("dictation", awaitSettle: false, on: pb, helper: PasteboardReaderTests.helper)
            }
        }

        #expect(!pasted)
        #expect(keys.withLock { $0 } == 0)
        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    private func pasteAfterPrefetch(
        on pb: NSPasteboard, settledFirst: Bool, check: @escaping @MainActor @Sendable () async -> Bool
    ) async -> (pasted: Bool, keys: Int) {
        let keys = OSAllocatedUnfairLock(initialState: 0)
        let pasted = await TextInserter.PasteboardSnapshot.$readBudgetSeconds.withValue(30) {
            await TextInserter.$frontmostApp.withValue({ 1 }) {
                await TextInserter.$targetStillFocused.withValue(check) {
                    await TextInserter.$keystrokeSink.withValue({ _ in keys.withLock { $0 += 1 } }) {
                        let read = TextInserter.prefetchSnapshot(on: pb, helper: PasteboardReaderTests.helper)
                        if settledFirst { _ = await read.value }
                        let paste = await TextInserter.insertViaPaste("dictation", awaitSettle: false, on: pb, helper: nil)
                        _ = await read.value
                        return paste
                    }
                }
            }
        }
        await TextInserter.drainPendingRestore()
        return (pasted, keys.withLock { $0 })
    }

    @Test(arguments: [true, false])
    func aPasteThatWaitedOnTheClipboardChecksItsTargetAgainBeforeTheKeystroke(stillThere: Bool) async throws {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        let source = try await SlowPasteboardSource(on: pb, delay: 0.3)
        defer { source.stop() }
        let checks = OSAllocatedUnfairLock(initialState: 0)

        let (pasted, keys) = await pasteAfterPrefetch(on: pb, settledFirst: false) {
            checks.withLock { $0 += 1 }
            return stillThere
        }

        #expect(pasted == stillThere)
        #expect(checks.withLock { $0 } == 1)
        #expect(keys == (stillThere ? 1 : 0))
        #expect(pb.string(forType: .string) == "plain fallback")
    }

    @Test func aPasteWhoseClipboardWasReadyDoesNotCheckItsTargetAgain() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)
        let checks = OSAllocatedUnfairLock(initialState: 0)

        let (pasted, keys) = await pasteAfterPrefetch(on: pb, settledFirst: true) {
            checks.withLock { $0 += 1 }
            return false
        }

        #expect(pasted)
        #expect(checks.withLock { $0 } == 0)
        #expect(keys == 1)
    }

    @Test func aCopyLandingWhileTheTargetIsCheckedAgainIsNeitherPastedNorOverwritten() async throws {
        let name = "keyscribe-test-\(UUID().uuidString)"
        let pb = NSPasteboard(name: NSPasteboard.Name(name))
        defer { pb.releaseGlobally() }
        let source = try await SlowPasteboardSource(on: pb, delay: 0.3)
        defer { source.stop() }

        let (pasted, keys) = await pasteAfterPrefetch(on: pb, settledFirst: false) {
            try? await Task.sleep(for: .milliseconds(20))
            let copied = NSPasteboard(name: NSPasteboard.Name(name))
            copied.clearContents()
            copied.setString("COPIED_DURING_CHECK", forType: .string)
            return true
        }

        #expect(!pasted)
        #expect(keys == 0)
        #expect(pb.string(forType: .string) == "COPIED_DURING_CHECK")
    }

    @Test func anAbortedPasteRestoresTheClipboardImmediately() async {
        let pb = NSPasteboard(name: NSPasteboard.Name("keyscribe-abort-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        var acted = true
        await TextInserter.$shouldAbortInsertion.withValue({ true }) {
            acted = await TextInserter.insertViaPaste("truncated dictation", awaitSettle: false, on: pb)
        }

        #expect(acted == false)
        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }
}
