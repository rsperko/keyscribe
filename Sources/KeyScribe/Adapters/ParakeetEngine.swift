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

// One adapter, parameterized per Parakeet model. Each pairs a TDT transcription model with the
// same-tier CTC variant for bias (v3 0.6B ↔ ctc06b, TDT-CTC 110M ↔ ctc110m). Both download+compile
// together in `load`, so bias is ready on the first dictation, not stalling mid-dictation.
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

    // Recognition bias is FluidAudio's constrained-CTC vocabulary boosting: TDT transcribes, then a CTC
    // keyword spotter re-scores bias terms against the acoustic frames, swapping only when CTC evidence
    // and string similarity clear thresholds. Fails soft to plain TDT text.
    //
    // `spotterRescue` gates the spotter-anchored rescue pass (acoustic-only, no similarity gate): safe on
    // the accurate ctc06b/v3, off for the weaker ctc110m where it hallucinated swaps ("I'm"→"KeyScribe").
    // Set via `VocabularyRescorer.Config.spotterRescueEnabled` (upstreamed in #724).
    private var ctcSpotter: CtcKeywordSpotter?
    private var ctcTokenizer: CtcTokenizer?
    private var ctcDir: URL?
    private var ctcUnavailable = false

    // Vocab + rescorer cached keyed on the term set. Multi-slot LRU (not single-entry) so distinct modes
    // coexist — the global set stays resident while a mode with local dictionary words gets its own slot,
    // instead of evicting each other and re-reading the CTC tokenizer on every mode switch.
    private struct BiasArtifacts {
        let vocab: CustomVocabularyContext
        var rescorer: VocabularyRescorer?
    }
    private var biasCache: [[String]: BiasArtifacts] = [:]
    private var biasCacheLRU: [[String]] = []
    private let biasCacheLimit = 8

    init(profile: ParakeetModelProfile, modelsDir: URL) {
        self.id = profile.id
        self.displayName = profile.displayName
        self.version = profile.version
        self.ctcVariant = profile.ctcVariant
        self.tdtDownloadShare = profile.tdtDownloadShare
        self.spotterRescue = profile.spotterRescue
        self.modelsDir = modelsDir
    }

    // Runtime warm (warm-on-press / launch preload): load only the TDT model. The CTC bias model is NOT
    // loaded here — empty-dictionary users never pay its CoreML load; bias users get it lazily from disk
    // in transcribe() (the install path already downloaded it, so no network block).
    func loadIfNeeded() async throws {
        try await ensureManager(progress: nil)
    }

    // Install path (Settings download/verify): fetch + compile BOTH the TDT and paired CTC bias model, so
    // the first biased dictation neither downloads nor compiles it mid-dictation.
    func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws {
        try await ensureManager(progress: progress)
        // CtcModels exposes no progress callback, so these phases advance the bar by guesstimate.
        // Best-effort: bias is optional, transcription is not.
        let share = tdtDownloadShare
        progress?(.init(phase: "Downloading recognition-bias model…", fraction: share + (1 - share) * 0.5))
        await ensureCtc(allowDownload: true)
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

    nonisolated let supportsSampleInput = true

    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        try await loadIfNeeded()
        guard let manager else { throw EngineError.notInitialized }
        // Unbiased keeps FluidAudio's file entry point unchanged — it disk-backs clips over its streaming
        // threshold (~30 s), which the in-memory samples path does not. Biased already resampled to samples.
        guard !biasTerms.isEmpty else {
            var decoderState = try TdtDecoderState(decoderLayers: version.decoderLayers)
            return try await manager.transcribe(wavURL, decoderState: &decoderState).text
        }
        return try await biasedTranscribe(samples: try audioConverter.resampleAudioFile(wavURL), biasTerms: biasTerms, manager: manager)
    }

    // FluidAudio's sample APIs assume 16 kHz mono (the capture rate for Parakeet), so `sampleRate` is
    // informational here — the manager/spotter are fixed at 16 kHz.
    func transcribe(samples: [Float], sampleRate: Int, biasTerms: [String]) async throws -> String {
        try await loadIfNeeded()
        guard let manager else { throw EngineError.notInitialized }
        guard !biasTerms.isEmpty else {
            var decoderState = try TdtDecoderState(decoderLayers: version.decoderLayers)
            return try await manager.transcribe(samples, decoderState: &decoderState).text
        }
        return try await biasedTranscribe(samples: samples, biasTerms: biasTerms, manager: manager)
    }

    private func biasedTranscribe(samples: [Float], biasTerms: [String], manager: AsrManager) async throws -> String {
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
            let env = ProcessInfo.processInfo.environment
            let benchCbw = Float(env["KEYSCRIBE_BENCH_CBW"] ?? "") ?? vocabConfig.cbw
            let benchMinSim = Float(env["KEYSCRIBE_BENCH_MINSIM"] ?? "") ?? vocabConfig.minSimilarity
            let rescorer = try await rescorer(for: biasTerms, vocab: vocab, ctcDir: ctcDir, spotter: spotter)
            let rescored = rescorer.ctcTokenRescore(
                transcript: result.text,
                tokenTimings: timings,
                logProbs: spot.logProbs,
                frameDuration: spot.frameDuration,
                cbw: benchCbw,
                minSimilarity: benchMinSim)

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
        if let cached = biasCache[biasTerms] { touchBias(biasTerms); return cached.vocab }
        let vocab = makeVocabulary(biasTerms)
        storeBias(BiasArtifacts(vocab: vocab), for: biasTerms)
        return vocab
    }

    private func rescorer(
        for biasTerms: [String], vocab: CustomVocabularyContext, ctcDir: URL, spotter: CtcKeywordSpotter
    ) async throws -> VocabularyRescorer {
        if let cached = biasCache[biasTerms]?.rescorer { touchBias(biasTerms); return cached }
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: vocab,
            config: VocabularyRescorer.Config(spotterRescueEnabled: spotterRescue),
            ctcModelDirectory: ctcDir)
        if biasCache[biasTerms] != nil {
            biasCache[biasTerms]?.rescorer = rescorer
            touchBias(biasTerms)
        } else {
            storeBias(BiasArtifacts(vocab: vocab, rescorer: rescorer), for: biasTerms)
        }
        return rescorer
    }

    private func storeBias(_ artifacts: BiasArtifacts, for terms: [String]) {
        biasCache[terms] = artifacts
        touchBias(terms)
        while biasCacheLRU.count > biasCacheLimit {
            biasCache[biasCacheLRU.removeFirst()] = nil
        }
    }

    private func touchBias(_ terms: [String]) {
        if let idx = biasCacheLRU.firstIndex(of: terms) { biasCacheLRU.remove(at: idx) }
        biasCacheLRU.append(terms)
    }

    // Warm-time: build the CTC vocab + rescorer for each mode's bias set into its own cache slot, so the
    // first biased dictation hits the cache instead of paying VocabularyRescorer.create (a disk read)
    // mid-transcription. Capped to the cache size so warming can't self-evict what it just built.
    func prewarmBias(termSets: [[String]]) async {
        for terms in termSets.prefix(biasCacheLimit) where !terms.isEmpty {
            if biasCache[terms]?.rescorer != nil { touchBias(terms); continue }
            guard let spotter = await ensureCtc(), let ctcDir else { return }
            let vocab = vocabulary(for: terms)
            guard !vocab.terms.isEmpty else { continue }
            _ = try? await rescorer(for: terms, vocab: vocab, ctcDir: ctcDir, spotter: spotter)
        }
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

    // `allowDownload` is true only on the Settings install path (`load(progress:)`) — the one place a
    // network fetch of the CTC bias model is legitimate. Other paths pass false: firing
    // `CtcModels.downloadAndLoad` from the press-time warm path would violate the no-network-on-cold-load
    // contract (SpeechEngine.swift). When absent and download isn't allowed, bias latches off for the
    // residency; a later install re-arms it (allowDownload bypasses the latch).
    @discardableResult
    private func ensureCtc(allowDownload: Bool = false) async -> CtcKeywordSpotter? {
        if let ctcSpotter { return ctcSpotter }
        if ctcUnavailable, !allowDownload { return nil }
        let target = modelsDir.appendingPathComponent(
            CtcModels.defaultCacheDirectory(for: ctcVariant).lastPathComponent, isDirectory: true)
        guard allowDownload || CtcModels.modelsExist(at: target) else {
            ctcUnavailable = true
            return nil
        }
        do {
            let models = try await CtcModels.downloadAndLoad(to: target, variant: ctcVariant)
            self.ctcSpotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
            self.ctcTokenizer = try await CtcTokenizer.load(from: target)
            self.ctcDir = target
            self.ctcUnavailable = false
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
        biasCache.removeAll()
        biasCacheLRU.removeAll()
    }
}
