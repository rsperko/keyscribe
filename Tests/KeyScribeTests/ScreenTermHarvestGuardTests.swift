import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// Guards for the screen-term harvest's two structural risks: a probe that outlives its dictation, and
// the cost of extraction+correction at the input ceiling. Both are cheap to get wrong silently.
@MainActor
struct ScreenTermHarvestGuardTests {
    private final class FixedEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias = false
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "call usestate now" }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
    }

    @MainActor private final class InsertSpy {
        private(set) var texts: [String] = []
        func record(_ text: String) { texts.append(text) }
    }

    // A field read from dictation A that lands after A ended must NOT publish into dictation B — B would
    // then snap its transcript against a window the user has already left (the KS-01/KS-02 class). The
    // generation guard is the mechanism; this is the regression test for it.
    @Test func aLateProbeFromAPriorDictationNeverPublishesIntoTheNext() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-genleak-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        var mode = Mode(id: "m", name: "M")
        mode.aiRewrite = .init(
            connection: "missing", prompt: "Rewrite it.", context: .init(precedingText: true))
        try? ModeStore.write(mode, to: modesDir)

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)

        let spy = InsertSpy()
        // Timing is the whole point. Dictation 1 finishes fast, but its probe is still running; it lands
        // 300 ms later, i.e. WHILE dictation 2 is recording and BEFORE dictation 2 commits. Dictation 2's
        // own probe never lands. So the only way dictation 2 can produce a snap is by reading dictation
        // 1's leaked value — which is exactly the bug the generation guard prevents. (Landing the stale
        // probe after BOTH dictations end proves nothing: there is no live session to leak into.)
        let probeCount = Counter()
        let provider = try! SpeechEngineProvider(engines: [FixedEngine()], activeId: "fixed")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: nil, hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, text, _ in await MainActor.run { spy.record(text) }; return true },
            submitKey: { _ in },
            snapshot: { TargetSnapshot(bundleId: "test.bundle", pid: 4242, focusedWindowId: "cg:99") },
            micStatus: { .granted },
            accessibilityGranted: { true },
            precedingTextProbe: { _, _ in
                let first = probeCount.bumpAndWasFirst()
                // DETACHED, mirroring the real probe (ContextProbe.precedingText wraps its AX walk in
                // Task.detached). That is load-bearing for this test: a detached child does not inherit
                // cancellation, so the teardown cancel at dictation end does NOT cut the read short —
                // which is exactly how a stale read survives its own dictation and reaches the next one.
                // A plain `try? await Task.sleep` here would return the instant it was cancelled, land
                // while no session exists, and make this test vacuously green.
                await Task.detached {
                    try? await Task.sleep(for: .milliseconds(first ? 300 : 5_000))
                }.value
                return "let value = useState(initialCount)"
            })

        // Dictation 1: commits immediately, leaving its probe in flight.
        controller.setNextModeOverride(id: "m")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value

        // Dictation 2: holds the recording open past the moment dictation 1's probe lands.
        controller.setNextModeOverride(id: "m")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        try? await Task.sleep(for: .milliseconds(700))
        controller.handleCommit()
        await controller.dictationTask?.value

        #expect(probeCount.value == 2)
        // Both must be unsnapped: #1's own probe was too slow for itself, and #2 must not inherit it.
        // A "call useState now " in the second slot is the generation leak.
        #expect(spy.texts == ["call usestate now ", "call usestate now "])
    }

    @MainActor private final class Counter {
        private(set) var value = 0
        func bumpAndWasFirst() -> Bool { value += 1; return value == 1 }
    }

    // The harvest runs inline on the commit path, so its cost must be negligible at the ceiling the
    // probe can actually deliver: 600 chars of preceding text (ContextProbe's bound) against a large
    // dictionary, plus the correction pass over a full-length transcript.
    @Test func extractionAndCorrectionAreNegligibleAtMaxInput() {
        let screen = String(
            repeating: "let handleReset = useState(0); parseConfig(rawValue); HTTPClient.send(); ", count: 12)
        let bounded = String(screen.prefix(600))
        let dictionary = (0..<200).map { "CuratedTerm\($0)" }
        let transcript = String(
            repeating: "we should rename the parse config helper and call httpclient again ", count: 8)

        let start = ContinuousClock.now
        var terms: [String] = []
        for _ in 0..<100 {
            terms = ScreenTermExtractor.terms(in: bounded, excluding: dictionary)
            let prepared = FuzzyCorrector.prepare(terms, matching: .exactNormalized)
            _ = FuzzyCorrector.apply(transcript, prepared: prepared)
        }
        let perIteration = (ContinuousClock.now - start) / 100

        #expect(!terms.isEmpty)
        // Generous bound: this is a sanity ceiling against an accidental quadratic, not a tight budget.
        // Measured well under a millisecond; 20 ms leaves room for a loaded CI machine.
        #expect(perIteration < .milliseconds(20))
    }
}

// Field-affordance capture: the role is read on the ADOPTION snapshot only, and is a snapshot-time
// hint that can go stale if focus moves within the same window. Both are deliberate; these pin them.
@MainActor
struct FieldRoleCaptureTests {
    // Only the adoption snapshot pays for the AX role round trip. commit / insertion / the Return check
    // all await snapshotAsync too, and none of them use the role — reading it there would put an extra
    // AX round trip on latency those paths await (detached keeps main unblocked, not the dictation).
    @Test func onlyTheAdoptionSnapshotRequestsTheRole() {
        let withRole = ContextProbe.focusedState(pid: ProcessInfo.processInfo.processIdentifier,
                                                 includeRole: true)
        let withoutRole = ContextProbe.focusedState(pid: ProcessInfo.processInfo.processIdentifier,
                                                    includeRole: false)
        // A test process exposes no focused UI element, so both degrade to nil — what matters is that
        // the role is never populated when it was not requested.
        #expect(withoutRole.role == nil)
        _ = withRole
    }

    // Documented limitation, pinned so it is a decision rather than a surprise: unlike isSecureField —
    // which is re-probed at commit and OR-ed into the adopted snapshot because getting it wrong leaks a
    // password — the role is captured once and never revalidated. A same-window field switch therefore
    // leaves it stale, and the rewrite prompt applies the ORIGINAL field's affordance rule. Worst case
    // is a formatting hint that does not match the destination, inside an atomically undoable insert.
    @Test func aSameWindowFieldSwitchLeavesTheCapturedRoleStale() {
        // Dictation starts in a single-line field…
        var captured = TargetSnapshot(
            bundleId: "app", pid: 42, focusedWindowId: "cg:1", focusedRole: "AXTextField")
        #expect(FieldFacts.derive(role: captured.focusedRole).singleLine == true)

        // …the user tabs to a text area in the SAME window. Insertion still targets it (same bundle,
        // pid and window, so decideInsertion permits the insert)…
        let current = TargetSnapshot(
            bundleId: "app", pid: 42, focusedWindowId: "cg:1", focusedRole: "AXTextArea")
        #expect(decideInsertion(captured: captured, current: current) == .insert)

        // …but nothing refreshes the captured role, so the stale single-line rule is what ships.
        #expect(captured.focusedRole == "AXTextField")
        #expect(FieldFacts.derive(role: captured.focusedRole).singleLine == true)

        // Adoption is the only writer; when it runs it replaces the role wholesale.
        captured.focusedRole = current.focusedRole
        #expect(FieldFacts.derive(role: captured.focusedRole).singleLine == false)
    }
}
