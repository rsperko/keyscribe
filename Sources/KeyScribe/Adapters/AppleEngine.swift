import AVFoundation
import Foundation
import Speech
import Synchronization
import KeyScribeKit

@available(macOS 26, *)
actor AppleEngine: SpeechEngine {
    nonisolated let id = "apple"
    nonisolated let displayName = "Apple Speech"
    nonisolated let supportsRecognitionBias = false

    nonisolated let benefitsFromWarmupClip = false

    private let locale: Locale
    private let forced: AppleSpeechModel?
    private var resolved: (model: AppleSpeechModel, locale: Locale)?
    private var choice: AppleSpeechModelChoice?
    private var dictationLocale: Locale?
    private var speechLocaleAwaitingRetry: Locale?
    private var speechRetry: Task<Void, Never>?
    private static let loadFallback = Mutex<AppleSpeechModelChoice?>(nil)
    private var assetsReady = false
    // One-shot: preheated at press, consumed by the next transcribe, else rebuilt.
    private var prepared: (analyzer: SpeechAnalyzer, transcriber: AppleTranscriber)?

    init(
        locale: Locale = Locale.current,
        forced: AppleSpeechModel? = AppleSpeechModel.override(in: ProcessInfo.processInfo.environment)
    ) {
        self.locale = locale
        self.forced = forced
    }

    static func resolve(locale: Locale, forced: AppleSpeechModel?) async
        -> (choice: AppleSpeechModelChoice, locale: Locale?, dictationLocale: Locale?) {
        let speechLocale = AppleSpeechModelChoice.coveredLocale(
            await SpeechTranscriber.supportedLocale(equivalentTo: locale),
            supported: await SpeechTranscriber.supportedLocales)
        let dictationLocale = AppleSpeechModelChoice.coveredLocale(
            await DictationTranscriber.supportedLocale(equivalentTo: locale),
            supported: await DictationTranscriber.supportedLocales)
        let choice = AppleSpeechModelChoice.resolve(
            speechAvailable: SpeechTranscriber.isAvailable,
            speechSupportsLocale: speechLocale != nil,
            dictationSupportsLocale: dictationLocale != nil,
            forced: forced)
        switch choice.model {
        case .speech: return (choice, speechLocale, dictationLocale)
        case .dictation: return (choice, dictationLocale, dictationLocale)
        case nil: return (choice, nil, dictationLocale)
        }
    }

    static func statusText(
        locale: Locale = Locale.current,
        forced: AppleSpeechModel? = AppleSpeechModel.override(in: ProcessInfo.processInfo.environment)
    ) async -> String {
        let fallback = loadFallback.withLock { $0 }
        let choice = if let fallback { fallback } else { await resolve(locale: locale, forced: forced).choice }
        return SpeechModelChoiceCopy.appleModelStatus(choice, languageName: languageName(locale))
    }

    private static func languageName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    func loadIfNeeded() async throws {
        guard !assetsReady else { return }
        let resolved = try await resolveOnce()
        do {
            try await Self.installAssets(resolved.model, locale: resolved.locale)
        } catch {
            guard let fallback = choice?.afterSpeechFailedToLoad(dictationSupportsLocale: dictationLocale != nil),
                  let dictationLocale else { throw error }
            Log.models.error(
                "apple speech install failed, using dictation: \(String(describing: error), privacy: .public)")
            try await Self.installAssets(.dictation, locale: dictationLocale)
            self.resolved = (.dictation, dictationLocale)
            choice = fallback
            speechLocaleAwaitingRetry = resolved.locale
            Self.loadFallback.withLock { $0 = fallback }
        }
        assetsReady = true
        retrySpeechIfWaiting()
    }

    private static func installAssets(_ model: AppleSpeechModel, locale: Locale) async throws {
        let module = AppleTranscriber(model, locale: locale).module
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    private func retrySpeechIfWaiting() {
        guard speechRetry == nil, let locale = speechLocaleAwaitingRetry else { return }
        speechRetry = Task {
            let installed = (try? await Self.installAssets(.speech, locale: locale)) != nil
            finishSpeechRetry(installed: installed, locale: locale)
        }
    }

    private func finishSpeechRetry(installed: Bool, locale: Locale) {
        speechRetry = nil
        guard installed else { return }
        Log.models.info("apple speech installed, switching from dictation")
        resolved = (.speech, locale)
        choice = AppleSpeechModelChoice(model: .speech, reason: .preferred)
        speechLocaleAwaitingRetry = nil
        Self.loadFallback.withLock { $0 = nil }
    }

    private func resolveOnce() async throws -> (model: AppleSpeechModel, locale: Locale) {
        if let resolved { return resolved }
        let fresh = await Self.resolve(locale: locale, forced: forced)
        Log.models.info("""
            apple model=\(fresh.choice.model?.rawValue ?? "none", privacy: .public) \
            reason=\(String(describing: fresh.choice.reason), privacy: .public) \
            locale=\(fresh.locale?.identifier ?? self.locale.identifier, privacy: .public)
            """)
        guard let model = fresh.choice.model, let modelLocale = fresh.locale else {
            throw AppleSpeechUnavailable(
                message: SpeechModelChoiceCopy.appleModelStatus(fresh.choice, languageName: Self.languageName(locale)))
        }
        resolved = (model, modelLocale)
        choice = fresh.choice
        dictationLocale = fresh.dictationLocale
        return (model, modelLocale)
    }

    // Analyzers are one-shot, so the next pair is prewarmed at press to overlap session setup with speech.
    // Best-effort: any failure leaves `prepared` nil and transcribe builds fresh.
    func prepareForDictation() async {
        retrySpeechIfWaiting()
        guard prepared == nil, (try? await loadIfNeeded()) != nil, let pair = try? makePair() else { return }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [pair.transcriber.module])
        try? await pair.analyzer.prepareToAnalyze(in: format)
        prepared = pair
    }

    private func makePair() throws -> (analyzer: SpeechAnalyzer, transcriber: AppleTranscriber) {
        guard let resolved else { throw EngineError.notInitialized }
        let transcriber = AppleTranscriber(resolved.model, locale: resolved.locale)
        return (SpeechAnalyzer(modules: [transcriber.module]), transcriber)
    }

    private func takePreparedOrBuild() throws -> (analyzer: SpeechAnalyzer, transcriber: AppleTranscriber) {
        if let prepared { self.prepared = nil; return prepared }
        return try makePair()
    }

    // biasTerms are ignored — Apple recognition bias (contextualStrings) was removed.
    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        try await loadIfNeeded()

        let (analyzer, transcriber) = try takePreparedOrBuild()
        let audioFile = try AVAudioFile(forReading: wavURL)

        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        return try await transcriber.transcript().value
    }

    func evict() async {}
}

@available(macOS 26, *)
enum AppleTranscriber {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    init(_ model: AppleSpeechModel, locale: Locale) {
        switch model {
        case .speech: self = .speech(SpeechTranscriber(locale: locale, preset: .transcription))
        case .dictation: self = .dictation(DictationTranscriber(locale: locale, preset: .longDictation))
        }
    }

    var module: any SpeechModule {
        switch self {
        case .speech(let transcriber): transcriber
        case .dictation(let transcriber): transcriber
        }
    }

    func transcript() -> Task<String, Error> {
        switch self {
        case .speech(let transcriber): Self.collect(transcriber.results) { $0.text }
        case .dictation(let transcriber): Self.collect(transcriber.results) { $0.text }
        }
    }

    private static func collect<Results: AsyncSequence & Sendable>(
        _ results: Results, text: @escaping @Sendable (Results.Element) -> AttributedString
    ) -> Task<String, Error> {
        Task {
            var transcript = AttributedString()
            for try await result in results { transcript += text(result) }
            return String(transcript.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
