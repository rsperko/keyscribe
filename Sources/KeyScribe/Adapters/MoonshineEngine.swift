import Foundation
import MoonshineVoice
import KeyScribeKit

// Moonshine has no on-device hotword/context parameter, so supportsRecognitionBias=false and biasTerms
// are ignored.
//
// Not an actor: Transcriber is non-Sendable; access is serialized by the SerializedEngine decorator, whose
// evict() waits for the transcribe lock — so evict()'s transcriber.close() can never fire under a running
// transcribe (the ONNX use-after-close this engine is most exposed to).
final class MoonshineEngine: SpeechEngine, @unchecked Sendable {
    let id = "moonshine-base-en"
    let displayName = "Moonshine Base (English)"
    let supportsRecognitionBias = false
    var installDirNames: [String] { [Self.subdir] }

    private static let baseURL = "https://download.moonshine.ai/model/base-en/quantized/base-en"
    // Weights approximate each file's share of the download so the progress bar tracks reality.
    private static let files: [(name: String, weight: Double)] = [
        ("encoder_model.ort", 0.22), ("decoder_model_merged.ort", 0.77), ("tokenizer.bin", 0.01),
    ]
    private static let subdir = "moonshine-base-en"

    private let modelsDir: URL
    nonisolated(unsafe) private var transcriber: Transcriber?
    // ONNX inference is a synchronous whole-clip call; run it on a dedicated queue so it doesn't park a
    // cooperative concurrency-pool worker for the duration.
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
                // download(from:) doesn't throw on an HTTP error — a 404/5xx/auth body lands in `tmp`, and
                // promoting it would fail opaquely later and block retries (the bogus file now exists).
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
            // Load failure means a corrupt/partial artifact; remove it so the next attempt re-downloads
            // instead of failing forever.
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        progress?(.init(phase: "Ready", fraction: 1))
    }

    nonisolated var supportsSampleInput: Bool { true }
    // Streaming disabled: measured streamed WER ran +2.7% over batch with no latency win.
    nonisolated var supportsStreaming: Bool { false }

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
