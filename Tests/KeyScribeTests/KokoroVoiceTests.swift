import FluidAudio
import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct KokoroVoiceTests {
    @Test func aVoiceThatIsNotInstalledRefusesToSynthesizeInsteadOfReloading() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ks-kokoro-\(UUID().uuidString)")
        let voice = KokoroVoice(directory: directory, pronunciationDirectory: { directory })
        await #expect(throws: KokoroVoice.NotInstalled.self) {
            _ = try await voice.synthesize("All done.", voice: "af_heart")
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    private func scratch() throws -> (KokoroVoice, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ks-kokoro-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("voice")
        let pronunciation = root.appendingPathComponent("pronunciation")
        let voice = KokoroVoice(directory: directory, pronunciationDirectory: { pronunciation })
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try voice.setInstalled(true)
        return (voice, directory, pronunciation)
    }

    private func place(_ names: [String], in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names { try Data().write(to: folder.appendingPathComponent(name)) }
    }

    @Test func aVoiceIsIntactOnlyWhenTheModelEverySpeakerAndThePronunciationFilesArePresent() throws {
        let (voice, directory, pronunciation) = try scratch()
        let repository = directory.appendingPathComponent(Repo.kokoroAne.folderName)
        try place(Array(ModelNames.KokoroAne.requiredModels), in: repository)
        try place(SpokenVoices.all.map { "\($0.id).bin" }, in: repository)
        try place(Array(ModelNames.G2P.requiredModels) + ["us_lexicon_cache.json"], in: pronunciation)
        #expect(voice.isIntact)

        try FileManager.default.removeItem(at: pronunciation.appendingPathComponent("us_lexicon_cache.json"))
        #expect(!voice.isIntact)
    }

    @Test func anInstalledVoiceWithMissingFilesRefusesToSynthesizeSoNothingIsFetched() async throws {
        let (voice, _, _) = try scratch()
        #expect(voice.isInstalled)
        #expect(!voice.isIntact)
        await #expect(throws: KokoroVoice.NotInstalled.self) {
            _ = try await voice.synthesize("All done.", voice: "af_heart")
        }
    }

    @Test func theSharedCacheFolderIsNotResolvedUntilTheVoiceIsChecked() {
        let resolved = Counter()
        let voice = KokoroVoice(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ks-kokoro-\(UUID().uuidString)")) {
            resolved.bump()
            return nil
        }
        #expect(!voice.isInstalled)
        #expect(resolved.value == 0)
        #expect(!voice.isIntact)
        #expect(resolved.value == 1)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        var value: Int { lock.withLock { _value } }
        func bump() { lock.withLock { _value += 1 } }
    }

    @Test func dependencyLogsBelowErrorReachNeitherTheConsoleNorTheSystemLog() {
        DependencyLogging.configure()
        #expect(!AppLogger.mirrorsToConsole)
        #expect(AppLogger.minimumLevel == .error)
    }

    private func result(_ samples: [Float]) -> KokoroAneSynthesisResult {
        var timings = KokoroAneStageTimings()
        timings.tail = 12.5
        return KokoroAneSynthesisResult(
            samples: samples, sampleRate: 24000, encoderTokens: 4, acousticFrames: 7, timings: timings,
            predictedDurations: [1, 4, 2], normalizedText: "docs done", phonemes: "dˈɑks dˈʌn")
    }

    @Test func aGoodResultBecomesTheWAVThatPlaysAndTheDetailsBehindIt() throws {
        let samples = (0..<24000).map { 0.3 * sin(Float($0) * 0.05) }
        let audio = try SpokenAudio.made(from: result(samples))
        #expect(audio.wav.prefix(4) == Data("RIFF".utf8))
        #expect(audio.wav.count == 44 + samples.count * 2)
        let synthesis = try #require(audio.synthesis)
        #expect(synthesis.normalizedText == "docs done")
        #expect(synthesis.phonemes == "dˈɑks dˈʌn")
        #expect(synthesis.predictedDurations == [1, 4, 2])
        #expect(synthesis.stageMilliseconds.contains(.init(label: "tail", value: "12.5")))
        #expect(abs(synthesis.measurements.seconds - 1) < 0.001)
    }

    @Test func invalidOrSilentAudioIsRejectedBeforeItPlaysAndSilentAudioIsKeptAsEvidence() throws {
        var invalid = (0..<24000).map { 0.3 * sin(Float($0) * 0.05) }
        invalid[10] = .nan
        do {
            _ = try SpokenAudio.made(from: result(invalid))
            Issue.record("invalid samples were accepted")
        } catch let rejected as SpokenAudio.Unusable {
            #expect(rejected.problem == .invalidSamples)
            #expect(rejected.audio == nil)
        }
        do {
            _ = try SpokenAudio.made(from: result([Float](repeating: 0, count: 24000)))
            Issue.record("silent audio was accepted")
        } catch let rejected as SpokenAudio.Unusable {
            #expect(rejected.problem == .silent)
            #expect(rejected.audio?.wav.prefix(4) == Data("RIFF".utf8))
        }
    }

    @Test func theRouteIsReadFromWhereEachStageRunsNotFromAPresetsName() {
        #expect(KokoroVoice.route(.aneTailGpu) == "vocoder on CPU and Neural Engine, noise on CPU and GPU, tail on CPU and GPU")
        #expect(KokoroVoice.route(.aneTailCpu) == "vocoder on CPU and Neural Engine, noise on CPU, tail on CPU")
        var mixed = KokoroAneComputeUnits.aneTailGpu
        mixed.tail = .cpuOnly
        #expect(KokoroVoice.route(mixed).hasSuffix("noise on CPU and GPU, tail on CPU"))
    }
}
