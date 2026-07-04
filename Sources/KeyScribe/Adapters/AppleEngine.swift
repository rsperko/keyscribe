import AVFoundation
import Foundation
import Speech
import KeyScribeKit

@available(macOS 26, *)
actor AppleEngine: SpeechEngine {
    nonisolated let id = "apple"
    nonisolated let displayName = "Apple Speech"
    nonisolated let supportsRecognitionBias = true

    nonisolated let benefitsFromWarmupClip = false

    private let locale: Locale
    private var assetsReady = false
    // A one-shot analyzer + transcriber preheated at press; consumed by the next transcribe, else rebuilt.
    private var prepared: (analyzer: SpeechAnalyzer, transcriber: DictationTranscriber)?

    init(locale: Locale = Locale.current) {
        self.locale = locale
    }

    func loadIfNeeded() async throws {
        guard !assetsReady else { return }
        try await ensureAssets()
        assetsReady = true
    }

    // Analyzers are one-shot, so build the next pair at press and prepareToAnalyze it, overlapping the
    // multi-hundred-ms session setup with speech. Best-effort: any failure leaves `prepared` nil and
    // transcribe builds fresh (today's behavior).
    func prepareForDictation() async {
        guard (try? await loadIfNeeded()) != nil else { return }
        let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try? await analyzer.prepareToAnalyze(in: format)
        prepared = (analyzer, transcriber)
    }

    private func takePreparedOrBuild() -> (analyzer: SpeechAnalyzer, transcriber: DictationTranscriber) {
        if let prepared { self.prepared = nil; return prepared }
        let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
        return (SpeechAnalyzer(modules: [transcriber]), transcriber)
    }

    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        try await loadIfNeeded()

        let (analyzer, transcriber) = takePreparedOrBuild()
        let audioFile = try AVAudioFile(forReading: wavURL)

        // Recognition bias (design.md §4.2): dictionary terms become contextual strings the analyzer
        // weights toward during recognition. Skipped when there are no terms. Must use
        // `DictationTranscriber` — `SpeechTranscriber` silently ignores `contextualStrings` (confirmed
        // by Apple dev forums), which is why bias appeared applied but had no effect.
        Log.bias.info("apple terms=\(biasTerms.joined(separator: "|"), privacy: .private) applied=\(!biasTerms.isEmpty, privacy: .public)")
        if !biasTerms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: biasTerms]
            try await analyzer.setContext(context)
        }

        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)

        var transcript = AttributedString()
        for try await result in transcriber.results {
            transcript += result.text
        }
        return String(transcript.characters)
    }

    func evict() async {}

    private func ensureAssets() async throws {
        let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }
}
