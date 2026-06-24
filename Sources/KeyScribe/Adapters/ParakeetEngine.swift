import Foundation
import FluidAudio
import KeyScribeKit

// Per-model identity + bias tuning, bundled so adding a Parakeet model is adding a profile constant,
// not editing the engine. Each TDT model pairs with the same-tier CTC model; `spotterRescue` gates
// FluidAudio's acoustic-only rescue pass (safe on the accurate ctc06b, off for the weaker ctc110m
// where it hallucinated swaps — see the bias note below).
struct ParakeetModelProfile {
    let id: String
    let displayName: String
    let version: AsrModelVersion
    let ctcVariant: CtcModelVariant
    let tdtDownloadShare: Double
    let spotterRescue: Bool

    static let tdtV3 = ParakeetModelProfile(
        id: "parakeet", displayName: "Parakeet TDT v3", version: .v3,
        ctcVariant: .ctc06b, tdtDownloadShare: 0.67, spotterRescue: true)
    static let tdtCtc110m = ParakeetModelProfile(
        id: "parakeet-tdt-ctc-110m", displayName: "Parakeet TDT-CTC 110M", version: .tdtCtc110m,
        ctcVariant: .ctc110m, tdtDownloadShare: 0.5, spotterRescue: false)
}

// One adapter, parameterized per Parakeet model. Each engine pairs a TDT transcription model with
// the CTC variant of the same size tier for recognition bias, so every Parakeet model biases
// consistently: v3 0.6B ↔ ctc06b, TDT-CTC 110M ↔ ctc110m. Both the TDT models and the paired CTC
// bias model download (and compile/prewarm into CoreML) together in `load`, so bias is ready on the
// first dictation rather than stalling mid-dictation on a first-use download.
actor ParakeetEngine: SpeechEngine {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let supportsRecognitionBias = true

    // Both dir names come from FluidAudio (TDT bundle + paired CTC bias model), never hardcoded.
    nonisolated var installDirNames: [String] {
        [AsrModels.defaultCacheDirectory(for: version).lastPathComponent,
         CtcModels.defaultCacheDirectory(for: ctcVariant).lastPathComponent]
    }

    // Parakeet can verify its TDT bundle on disk (the CTC bias model is optional, never gates
    // "installed"). The other engines have no SDK integrity check and use the default `nil`.
    nonisolated func verifyInstalled(in modelsDir: URL) -> Bool? {
        let tdt = modelsDir.appendingPathComponent(
            AsrModels.defaultCacheDirectory(for: version).lastPathComponent, isDirectory: true)
        return AsrModels.modelsExist(at: tdt, version: version)
    }

    private let modelsDir: URL
    private let version: AsrModelVersion
    private let ctcVariant: CtcModelVariant
    private let tdtDownloadShare: Double
    private let spotterRescue: Bool

    private var manager: AsrManager?
    private let audioConverter = AudioConverter()

    // Recognition bias for Parakeet is FluidAudio's constrained-CTC vocabulary boosting (NeMo
    // CTC-WS): TDT transcribes, then a CTC keyword spotter re-scores bias terms against the
    // acoustic frames, swapping a TDT word for a dictionary term only when the CTC evidence and
    // string similarity clear confidence thresholds. This is decode-adjacent, not the old blind
    // post-STT span substitution. Fails soft to plain TDT text — bias terms still reach the
    // post-STT LLM "valid term" hint.
    //
    // `spotterRescue` gates FluidAudio's spotter-anchored rescue pass (acoustic-only replacement,
    // no similarity gate). It's safe only with an accurate CTC model: on by default (ctc06b/v3),
    // off for the weaker ctc110m where it hallucinated swaps (e.g. "I'm"→"KeyScribe"). Requires our
    // FluidAudio fork's `enableSpotterRescue` param (see Package.swift).
    private var ctcSpotter: CtcKeywordSpotter?
    private var ctcTokenizer: CtcTokenizer?
    private var ctcDir: URL?
    private var ctcUnavailable = false

    // Bias terms rarely change between consecutive dictations, so the tokenized vocabulary and the
    // rescorer it feeds are cached keyed on the term set. Both are rebuilt only when the terms change
    // (the rescorer reads from the CTC model dir, so recreating it per dictation was needless I/O).
    private var cachedBiasTerms: [String]?
    private var cachedVocab: CustomVocabularyContext?
    private var cachedRescorer: VocabularyRescorer?

    init(profile: ParakeetModelProfile, modelsDir: URL) {
        self.id = profile.id
        self.displayName = profile.displayName
        self.version = profile.version
        self.ctcVariant = profile.ctcVariant
        self.tdtDownloadShare = profile.tdtDownloadShare
        self.spotterRescue = profile.spotterRescue
        self.modelsDir = modelsDir
    }

    // Runtime warm (warm-on-press / launch preload): load only the TDT transcription model. The CTC
    // bias model is NOT loaded here — users with an empty dictionary never pay its CoreML load, and
    // bias users get it lazily from disk inside transcribe() the first time they actually bias (the
    // install path below already downloaded it, so that lazy load never blocks on the network).
    func loadIfNeeded() async throws {
        try await ensureManager(progress: nil)
    }

    // Install path (Settings download/verify): fetch + compile BOTH the TDT model and the paired CTC
    // bias model, so the first biased dictation neither downloads nor compiles the bias model
    // mid-dictation. Runtime warming uses loadIfNeeded() above and skips the eager CTC load.
    func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws {
        try await ensureManager(progress: progress)
        // The CTC bias model ships with the engine. CtcModels exposes no progress callback, so these
        // phases advance the bar by guesstimate. Best-effort: bias is optional, transcription is not.
        let share = tdtDownloadShare
        progress?(.init(phase: "Downloading recognition-bias model…", fraction: share + (1 - share) * 0.5))
        await ensureCtc()
        progress?(.init(phase: "Compiling recognition-bias model…", fraction: share + (1 - share) * 0.9))
        progress?(.init(phase: "Ready", fraction: 1))
    }

    private func ensureManager(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws {
        guard manager == nil else { return }
        let share = tdtDownloadShare
        var handler: DownloadUtils.ProgressHandler?
        if let progress {
            handler = { snapshot in
                progress(.init(phase: "Downloading speech model…", fraction: snapshot.fractionCompleted * share))
            }
        }
        // FluidAudio's `to:` is the full model-bundle path (it downloads into the parent), so
        // target the bundle *inside* models/. The dir name comes from FluidAudio (not hardcoded).
        let target = modelsDir.appendingPathComponent(
            AsrModels.defaultCacheDirectory(for: version).lastPathComponent, isDirectory: true)
        let models = try await AsrModels.downloadAndLoad(
            to: target, version: version, progressHandler: handler)
        progress?(.init(phase: "Compiling speech model…", fraction: share))
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        try await loadIfNeeded()
        guard let manager else { throw EngineError.notInitialized }

        guard !biasTerms.isEmpty else {
            var decoderState = try TdtDecoderState(decoderLayers: version.decoderLayers)
            return try await manager.transcribe(wavURL, decoderState: &decoderState).text
        }

        let samples = try audioConverter.resampleAudioFile(wavURL)
        var decoderState = try TdtDecoderState(decoderLayers: version.decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)

        guard let spotter = await ensureCtc(), let ctcDir,
            let timings = result.tokenTimings, !timings.isEmpty
        else {
            Log.bias.info("\(self.id, privacy: .public) terms=\(biasTerms.joined(separator: "|"), privacy: .private) applied=false")
            return result.text
        }

        let vocab = vocabulary(for: biasTerms)
        guard !vocab.terms.isEmpty else {
            Log.bias.info("\(self.id, privacy: .public) terms=\(biasTerms.joined(separator: "|"), privacy: .private) applied=false")
            return result.text
        }

        do {
            let spot = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: vocab)
            guard !spot.logProbs.isEmpty else {
                Log.bias.info("\(self.id, privacy: .public) terms=\(biasTerms.joined(separator: "|"), privacy: .private) applied=false")
                return result.text
            }

            let vocabConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: vocab.terms.count)
            let rescorer = try await rescorer(vocab: vocab, ctcDir: ctcDir, spotter: spotter)
            let rescored = rescorer.ctcTokenRescore(
                transcript: result.text,
                tokenTimings: timings,
                logProbs: spot.logProbs,
                frameDuration: spot.frameDuration,
                cbw: vocabConfig.cbw,
                minSimilarity: vocabConfig.minSimilarity,
                enableSpotterRescue: spotterRescue)

            Log.bias.info(
                "\(self.id, privacy: .public) terms=\(biasTerms.joined(separator: "|"), privacy: .private) applied=\(rescored.wasModified, privacy: .public) replacements=\(rescored.replacements.count, privacy: .public)"
            )
            for r in rescored.replacements {
                Log.bias.debug(
                    "\(self.id, privacy: .public) repl '\(r.originalWord, privacy: .private)'(\(r.originalScore, privacy: .public)) -> '\(r.replacementWord ?? "", privacy: .private)'(\(r.replacementScore ?? 0, privacy: .public)) reason=\(r.reason, privacy: .private)"
                )
            }
            return rescored.text
        } catch {
            Log.bias.error("\(self.id, privacy: .public) bias rescoring failed: \(error, privacy: .public)")
            return result.text
        }
    }

    private func vocabulary(for biasTerms: [String]) -> CustomVocabularyContext {
        if cachedBiasTerms == biasTerms, let cachedVocab { return cachedVocab }
        let vocab = makeVocabulary(biasTerms)
        cachedBiasTerms = biasTerms
        cachedVocab = vocab
        cachedRescorer = nil
        return vocab
    }

    private func rescorer(
        vocab: CustomVocabularyContext, ctcDir: URL, spotter: CtcKeywordSpotter
    ) async throws -> VocabularyRescorer {
        if let cachedRescorer { return cachedRescorer }
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: vocab, config: .default, ctcModelDirectory: ctcDir)
        cachedRescorer = rescorer
        return rescorer
    }

    private func makeVocabulary(_ biasTerms: [String]) -> CustomVocabularyContext {
        guard let tokenizer = ctcTokenizer else { return CustomVocabularyContext(terms: []) }
        let terms = biasTerms.compactMap { text -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(text)
            guard !ids.isEmpty else { return nil }
            return CustomVocabularyTerm(text: text, ctcTokenIds: ids)
        }
        return CustomVocabularyContext(terms: terms)
    }

    @discardableResult
    private func ensureCtc() async -> CtcKeywordSpotter? {
        if let ctcSpotter { return ctcSpotter }
        if ctcUnavailable { return nil }
        do {
            let target = modelsDir.appendingPathComponent(
                CtcModels.defaultCacheDirectory(for: ctcVariant).lastPathComponent, isDirectory: true)
            let models = try await CtcModels.downloadAndLoad(to: target, variant: ctcVariant)
            self.ctcSpotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
            self.ctcTokenizer = try await CtcTokenizer.load(from: target)
            self.ctcDir = target
            return ctcSpotter
        } catch {
            ctcUnavailable = true
            Log.bias.error("\(self.id, privacy: .public) CTC bias unavailable: \(error, privacy: .public)")
            return nil
        }
    }

    func evict() async {
        await manager?.cleanup()
        manager = nil
        ctcSpotter = nil
        ctcTokenizer = nil
        ctcDir = nil
        ctcUnavailable = false
        cachedBiasTerms = nil
        cachedVocab = nil
        cachedRescorer = nil
    }
}
