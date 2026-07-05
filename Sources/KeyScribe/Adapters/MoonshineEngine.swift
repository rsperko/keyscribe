import Foundation
import MoonshineVoice
import KeyScribeKit

// Moonshine (Useful Sensors) — ONNX Runtime backend shipped as a prebuilt xcframework. Ultra-low
// latency English ASR. The .ort model files download directly from download.moonshine.ai into
// modelsDir/<subdir>; Transcriber loads that directory.
//
// Recognition bias: NOT supported on-device. Moonshine's on-device path has no hotword/context
// parameter (customization is a commercial retraining service), so this engine reports
// supportsRecognitionBias=false and ignores biasTerms. DictationController skips assembling terms
// for it, and the Settings models list badges it as no-local-bias.
//
// Not an actor: MoonshineVoice.Transcriber is a non-Sendable class; access to the `transcriber` handle
// is serialized by the SerializedEngine actor decorator wrapping this engine at EngineRegistry.makeAll,
// whose evict() waits for the transcribe lock — so evict()'s transcriber.close() can never fire under a
// running transcribe (the ONNX use-after-close this engine is most exposed to). Like WhisperEngine/Qwen.
final class MoonshineEngine: SpeechEngine, @unchecked Sendable {
    let id = "moonshine-base-en"
    let displayName = "Moonshine Base (English)"
    let supportsRecognitionBias = false
    var installDirNames: [String] { [Self.subdir] }

    private static let baseURL = "https://download.moonshine.ai/model/base-en/quantized/base-en"
    // Approx download weights (decoder dominates) so the progress bar tracks reality across files.
    private static let files: [(name: String, weight: Double)] = [
        ("encoder_model.ort", 0.22), ("decoder_model_merged.ort", 0.77), ("tokenizer.bin", 0.01),
    ]
    private static let subdir = "moonshine-base-en"

    private let modelsDir: URL
    nonisolated(unsafe) private var transcriber: Transcriber?
    // ONNX inference is a synchronous, whole-clip call; running it on a Swift-concurrency pool thread
    // parks a cooperative worker (width = core count) for the duration. Hop it to a dedicated queue so
    // the pool stays free. SerializedEngine still guarantees one transcribe at a time on this instance.
    private let inferenceQueue = DispatchQueue(label: "com.keyscribe.audio.moonshine-inference", qos: .userInitiated)

    init(modelsDir: URL) {
        self.modelsDir = modelsDir
    }

    private var modelDir: URL { modelsDir.appendingPathComponent(Self.subdir, isDirectory: true) }

    private func modelFilesPresent(at folder: URL) -> Bool {
        let fm = FileManager.default
        return Self.files.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0.name).path) }
    }

    func verifyInstalled(in modelsDir: URL) -> Bool? {
        modelFilesPresent(at: modelsDir.appendingPathComponent(Self.subdir, isDirectory: true))
    }

    func loadIfNeeded() async throws {
        try await load(progress: nil)
    }

    func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws {
        guard transcriber == nil else { return }
        let dir = modelDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var cumulative = 0.0
        for file in Self.files {
            let dest = dir.appendingPathComponent(file.name)
            if !FileManager.default.fileExists(atPath: dest.path) {
                progress?(.init(phase: "Downloading speech model…", fraction: cumulative))
                guard let url = URL(string: "\(Self.baseURL)/\(file.name)") else {
                    throw EngineError.badModelURL(file.name)
                }
                let (tmp, response) = try await URLSession.shared.download(from: url)
                // download(from:) does not throw on an HTTP error — a 404/5xx/auth body lands in `tmp`.
                // Promoting that as a .ort/tokenizer file fails opaquely later in Transcriber and, since
                // the bogus file now exists, blocks any retry. Require a 2xx + non-empty payload first.
                let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? Int
                guard ok, (size ?? 0) > 0 else {
                    try? FileManager.default.removeItem(at: tmp)
                    throw EngineError.downloadFailed(file.name)
                }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
            }
            cumulative += file.weight
            progress?(.init(phase: "Downloading speech model…", fraction: cumulative))
        }
        progress?(.init(phase: "Loading speech model…", fraction: 0.97))
        do {
            transcriber = try Transcriber(modelPath: dir.path, modelArch: .base)
        } catch {
            // Loading failed against what's on disk (a corrupt/partial artifact from an earlier run).
            // Remove the model dir so the next attempt re-downloads instead of failing on it forever.
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        progress?(.init(phase: "Ready", fraction: 1))
    }

    nonisolated var supportsSampleInput: Bool { true }
    // Streaming is DISABLED for Moonshine: it proved the streaming interface (P3-1) but its streamed WER ran
    // +2.7% over batch with no latency win, so it fails the rollout contract. makeStreamingSession and
    // MoonshineStreamingSession are kept as harness fixtures; this flag being false means the controller
    // never opens a session for it. Apple is the shipping streaming engine.
    nonisolated var supportsStreaming: Bool { false }

    // A fresh per-dictation stream off the transcriber handle. loadIfNeeded ran under the SerializedEngine
    // lock (ensureRuntimeLocked) before this, so the transcriber is resident; the lock is held for the
    // session's whole lifetime, so evict()'s transcriber.close() can never fire under a live stream.
    func makeStreamingSession(sampleRate: Int, biasTerms: [String]) async throws -> any StreamingSpeechSession {
        try await loadIfNeeded()
        Log.bias.info("moonshine streaming: bias unsupported — \(biasTerms.count, privacy: .public) term(s) ignored")
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<any StreamingSpeechSession, Error>) in
            inferenceQueue.async { [self] in
                guard let transcriber else { cont.resume(throwing: EngineError.notInitialized); return }
                do {
                    let stream = try transcriber.createStream()
                    try stream.start()
                    cont.resume(returning: MoonshineStreamingSession(stream: stream, sampleRate: sampleRate, queue: inferenceQueue))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        try await transcribe(samples: try AudioDecoder.pcmMono(wavURL, sampleRate: 16000), sampleRate: 16000, biasTerms: biasTerms)
    }

    func transcribe(samples: [Float], sampleRate: Int, biasTerms: [String]) async throws -> String {
        try await loadIfNeeded()
        Log.bias.info("moonshine bias unsupported — \(biasTerms.count, privacy: .public) term(s) ignored")
        let text = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            inferenceQueue.async { [self] in
                guard let transcriber else { cont.resume(throwing: EngineError.notInitialized); return }
                do {
                    let transcript = try transcriber.transcribeWithoutStreaming(audioData: samples, sampleRate: Int32(sampleRate))
                    cont.resume(returning: transcript.lines.map(\.text).joined(separator: " "))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func evict() async {
        transcriber?.close()
        transcriber = nil
    }
}

// One dictation's Moonshine stream. Every SDK call (addAudio/stop/updateTranscription/close) touches the
// non-Sendable Stream handle, so all run on the same inferenceQueue the batch path uses — serialized both
// against each other (the driver calls them sequentially anyway) and off the cooperative pool. The
// SerializedEngine lock (held for this session's lifetime) keeps evict from closing the transcriber under it.
final class MoonshineStreamingSession: StreamingSpeechSession, @unchecked Sendable {
    private let stream: MoonshineVoice.Stream
    private let sampleRate: Int
    private let queue: DispatchQueue

    init(stream: MoonshineVoice.Stream, sampleRate: Int, queue: DispatchQueue) {
        self.stream = stream
        self.sampleRate = sampleRate
        self.queue = queue
    }

    // A mid-stream addAudio failure throws so the driver cancels this session and the dictation degrades to
    // a batch transcribe of the intact audio — the chunk is never silently dropped.
    func append(samples: [Float]) async throws {
        try await onQueueThrowing {
            try self.stream.addAudio(samples, sampleRate: Int32(self.sampleRate))
        }
    }

    func finalizeTranscript() async throws -> String {
        try await onQueueThrowing {
            defer { self.stream.close() }
            try self.stream.stop()
            let transcript = try self.stream.updateTranscription()
            return transcript.lines.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func cancel() async {
        await onQueue { self.stream.close() }
    }

    private func onQueue(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { body(); cont.resume() }
        }
    }

    private func onQueueThrowing<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async { do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) } }
        }
    }
}
