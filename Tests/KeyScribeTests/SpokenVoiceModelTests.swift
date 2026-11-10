import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct SpokenVoiceModelTests {
    final class FakeInstaller: VoiceInstalling, @unchecked Sendable {
        private let lock = NSLock()
        private var _installed: Bool
        private var _intact: Bool
        private var _synthesisFails = false
        private var _removals = 0
        private var _downloads = 0
        private var held: CheckedContinuation<Void, Never>?
        var downloadFails = false
        var verifies = true
        var removeFails = false
        var holds = false

        init(installed: Bool = false, intact: Bool = true) {
            _installed = installed
            _intact = intact
        }

        var isInstalled: Bool { lock.withLock { _installed } }
        private var _intactChecks = 0
        var intactChecks: Int { lock.withLock { _intactChecks } }
        var isIntact: Bool {
            get { lock.withLock { _intactChecks += 1; return _intact } }
            set { lock.withLock { _intact = newValue } }
        }
        var synthesisBusy = false
        var synthesisFails: Bool {
            get { lock.withLock { _synthesisFails } }
            set { lock.withLock { _synthesisFails = newValue } }
        }
        var removals: Int { lock.withLock { _removals } }
        var downloads: Int { lock.withLock { _downloads } }

        func download(progress: @escaping @Sendable (ModelLoadProgress) -> Void) async throws {
            lock.withLock { _downloads += 1 }
            progress(ModelLoadProgress(phase: "Downloading voice\u{2026}", fraction: 0.4))
            if holds { await withCheckedContinuation { continuation in lock.withLock { held = continuation } } }
            if downloadFails { throw URLError(.notConnectedToInternet) }
        }

        func verify() async -> Bool { verifies }

        func setInstalled(_ installed: Bool) throws { lock.withLock { _installed = installed } }

        func remove() async throws {
            lock.withLock { _removals += 1 }
            if removeFails { throw CocoaError(.fileWriteNoPermission) }
            lock.withLock { _installed = false }
        }

        func synthesize(_ text: String, voice: String) async throws -> SpokenAudio {
            if synthesisBusy { throw WorkBusy() }
            if synthesisFails { throw CocoaError(.fileReadNoSuchFile) }
            return SpokenAudio(wav: Data(text.utf8))
        }

        func release() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                let pending = held
                held = nil
                return pending
            }
            continuation?.resume()
        }
    }

    private func settled() async {
        for _ in 0..<200 { await Task.yield() }
    }

    @Test func anInstalledVoiceStartsReadyAndAMissingOneOffersTheDownload() {
        #expect(SpokenVoiceModel(installer: FakeInstaller(installed: true)).status == .ready)
        #expect(SpokenVoiceModel(installer: FakeInstaller()).status == .notInstalled)
    }

    @Test func aVoiceThatWasNeverInstalledIsNotCheckedForFilesAtLaunch() {
        let installer = FakeInstaller()
        _ = SpokenVoiceModel(installer: installer)
        #expect(installer.intactChecks == 0)
    }

    @Test func anInstalledVoiceWithMissingFilesStartsNeedingAttention() {
        let model = SpokenVoiceModel(installer: FakeInstaller(installed: true, intact: false))
        #expect(model.status == .needsAttention)
        #expect(model.error == "Some of this voice\u{2019}s files are missing. Reinstall it.")
    }

    @Test func aFailedResultWhoseFilesAreGoneMovesTheVoiceToNeedsAttention() async {
        let installer = FakeInstaller(installed: true)
        let model = SpokenVoiceModel(installer: installer)
        let fallback = SpokenResultOutputTests.FakeSpeech()
        let speech = model.makeSpeech(player: NaturalSpeechTests.FakePlayer(), fallback: fallback)
        installer.synthesisFails = true
        installer.isIntact = false
        speech.speak("All done.", voice: nil)
        await settled()
        #expect(model.status == .needsAttention)
        #expect(model.error == "Some of this voice\u{2019}s files are missing. Reinstall it.")
    }

    @Test func aFailedResultWithItsFilesInPlaceLeavesTheVoiceReady() async {
        let installer = FakeInstaller(installed: true)
        let model = SpokenVoiceModel(installer: installer)
        let speech = model.makeSpeech(player: NaturalSpeechTests.FakePlayer(), fallback: SpokenResultOutputTests.FakeSpeech())
        installer.synthesisFails = true
        speech.speak("All done.", voice: nil)
        await settled()
        #expect(model.status == .ready)
    }

    @Test func aResultReadByTheMacOSVoiceInsteadIsShownUntilTheNaturalVoicePlaysAgain() async {
        let installer = FakeInstaller(installed: true)
        let model = SpokenVoiceModel(installer: installer)
        let speech = model.makeSpeech(player: NaturalSpeechTests.FakePlayer(), fallback: SpokenResultOutputTests.FakeSpeech())
        installer.synthesisFails = true
        speech.speak("All done.", voice: nil)
        await settled()
        #expect(model.status == .ready)
        #expect(model.fellBack)
        #expect(model.fallbackReason == "the natural voice failed")
        installer.synthesisFails = false
        speech.speak("All done.", voice: nil)
        await settled()
        #expect(!model.fellBack)
        #expect(model.fallbackReason == nil)
    }

    @Test func aDownloadReportsProgressThenTestsTheVoiceAndMarksItReady() async {
        let installer = FakeInstaller()
        installer.holds = true
        let model = SpokenVoiceModel(installer: installer)
        model.download()
        await settled()
        #expect(model.status == .downloading(phase: "Downloading voice\u{2026}", fraction: 0.4))
        installer.release()
        await settled()
        #expect(model.status == .ready)
        #expect(installer.isInstalled)
        #expect(model.error == nil)
    }

    @Test func aSecondDownloadWhileOneRunsIsIgnored() async {
        let installer = FakeInstaller()
        installer.holds = true
        let model = SpokenVoiceModel(installer: installer)
        model.download()
        await settled()
        model.download()
        await settled()
        installer.release()
        await settled()
        #expect(installer.downloads == 1)
    }

    @Test func aFailedDownloadRemovesItsPartialFilesAndShowsTheError() async {
        let installer = FakeInstaller()
        installer.downloadFails = true
        let model = SpokenVoiceModel(installer: installer)
        model.download()
        await settled()
        #expect(model.status == .notInstalled)
        #expect(installer.removals == 1)
        #expect(model.error != nil)
        #expect(!installer.isInstalled)
    }

    @Test func aVoiceThatProducesNoSoundNeedsAttentionAndIsNotMarkedInstalled() async {
        let installer = FakeInstaller()
        installer.verifies = false
        let model = SpokenVoiceModel(installer: installer)
        model.download()
        await settled()
        #expect(model.status == .needsAttention)
        #expect(!installer.isInstalled)
        #expect(model.error == "This voice didn\u{2019}t produce any sound. Reinstall it.")
    }

    @Test func reinstallRemovesTheBadFilesAndDownloadsAgain() async {
        let installer = FakeInstaller()
        installer.verifies = false
        let model = SpokenVoiceModel(installer: installer)
        model.download()
        await settled()
        installer.verifies = true
        model.reinstall()
        await settled()
        #expect(model.status == .ready)
        #expect(installer.downloads == 2)
        #expect(installer.removals == 1)
    }

    @Test func deletingAsksFirstThenRemovesTheVoice() async {
        let installer = FakeInstaller(installed: true)
        let model = SpokenVoiceModel(installer: installer)
        model.requestDelete()
        #expect(model.pendingDelete)
        #expect(installer.removals == 0)
        model.confirmDelete()
        await settled()
        #expect(!model.pendingDelete)
        #expect(model.status == .notInstalled)
        #expect(installer.removals == 1)
    }

    @Test func aCancelledDeleteKeepsTheVoice() {
        let installer = FakeInstaller(installed: true)
        let model = SpokenVoiceModel(installer: installer)
        model.requestDelete()
        model.cancelDelete()
        #expect(!model.pendingDelete)
        #expect(model.status == .ready)
        #expect(installer.removals == 0)
    }

    @Test func aDeleteThatFailsPartwayNeedsAttentionAndCanBeDeletedAgain() async {
        let installer = FakeInstaller(installed: true)
        installer.removeFails = true
        let model = SpokenVoiceModel(installer: installer)
        model.requestDelete()
        model.confirmDelete()
        await settled()
        #expect(model.status == .needsAttention)
        #expect(!installer.isInstalled)
        #expect(model.error == "Some of this voice\u{2019}s files couldn\u{2019}t be removed. Delete it again, or reinstall it.")
        installer.removeFails = false
        model.requestDelete()
        #expect(model.pendingDelete)
        model.confirmDelete()
        await settled()
        #expect(model.status == .notInstalled)
        #expect(model.error == nil)
    }

    @Test func deletingStopsEverySpeakerTheModelMade() async {
        let installer = FakeInstaller(installed: true)
        let model = SpokenVoiceModel(installer: installer)
        let player = NaturalSpeechTests.FakePlayer()
        let speech = model.makeSpeech(player: player, fallback: SpokenResultOutputTests.FakeSpeech())
        speech.speak("All done.", voice: nil)
        await settled()
        #expect(player.isPlaying)
        model.requestDelete()
        model.confirmDelete()
        #expect(!player.isPlaying)
        #expect(!speech.isSpeaking)
    }

    @Test func aVoiceBusyWithEarlierAudioIsNotCheckedForMissingFiles() async {
        let installer = FakeInstaller(installed: true)
        installer.synthesisBusy = true
        let model = SpokenVoiceModel(installer: installer)
        let before = installer.intactChecks
        let fallback = SpokenResultOutputTests.FakeSpeech()
        let speech = model.makeSpeech(player: NaturalSpeechTests.FakePlayer(), fallback: fallback)
        speech.speak("Done.", voice: nil)
        for _ in 0..<400 where fallback.spoken.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(fallback.spoken.map(\.text) == ["Done."])
        #expect(installer.intactChecks == before)
    }

    @Test func aPreviewThatFallsBackSaysSoOnItsOwnAndLeavesTheReplyAdvisoryAlone() async {
        let installer = FakeInstaller(installed: true)
        let model = SpokenVoiceModel(installer: installer)
        let preview = model.makeSpeech(player: NaturalSpeechTests.FakePlayer(), fallback: SpokenResultOutputTests.FakeSpeech(), preview: true)
        installer.synthesisFails = true
        preview.speak("Sample.", voice: nil)
        await settled()
        #expect(model.previewFallbackReason == "the natural voice failed")
        #expect(model.fallbackReason == nil)
        installer.synthesisFails = false
        preview.speak("Sample.", voice: nil)
        await settled()
        #expect(model.previewFallbackReason == nil)
    }

    @Test func theReplyAdvisoryLinksOnlyToTheEntryOfTheAttemptItDescribes() async {
        let installer = FakeInstaller(installed: true)
        let model = SpokenVoiceModel(installer: installer)
        let attempts = SpokenAttempts()
        let speech = model.makeSpeech(player: NaturalSpeechTests.FakePlayer(), fallback: SpokenResultOutputTests.FakeSpeech(), attempts: attempts)
        installer.synthesisFails = true
        speech.speak("docs: Done.", voice: nil)
        await settled()
        let failed = speech.attempt
        model.replySaved(attempt: "another attempt", entry: "unrelated")
        #expect(model.fallbackEntry == nil)
        model.replySaved(attempt: failed, entry: "e1")
        #expect(model.fallbackEntry == "e1")
        speech.speak("a notice", voice: nil)
        await settled()
        #expect(model.fallbackEntry == nil)
    }
}
