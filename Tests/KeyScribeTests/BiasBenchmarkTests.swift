import AVFoundation
import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

private func pad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
}
private func padL(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
}

// Opt-in performance benchmark (loads real ~632MB/Parakeet models + runs live transcription), so it
// is gated out of the normal suite. Run with:
//   RUN_BIAS_BENCH=1 swift test --filter biasBenchmark
// Compares per-dictation latency with vs without recognition bias across all four models on a
// non-trivial (~36s) real-speech passage, to feel the cost of each engine's bias mechanism —
// especially Parakeet's second (CTC) acoustic pass vs Whisper/Apple's single pass.
struct BiasBenchmarkTests {
    // ~12 terms: some spoken in the passage, some distractors that never appear (a realistic
    // dictionary), >10 so Parakeet hits its "large vocab" rescorer path.
    static let bias = [
        "KeyScribe", "FluidBloo", "Parakeet", "WhisperKit", "SpeechAnalyzer", "eigenvector",
        "Bayesian", "transducer", "Kubernetes", "PostgreSQL", "Levenshtein", "Cupertino",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_BIAS_BENCH"] != nil))
    func biasBenchmark() async throws {
        let wav = try Self.audioURL()
        let audioSec = try Self.duration(of: wav)
        let dir = KeyScribePaths.modelsDir
        let warmups = 1
        let iterations = 5

        print("\n=== Bias benchmark — \(String(format: "%.1f", audioSec))s passage, \(iterations) warm runs ===")
        print(pad("engine", 16) + padL("load(cold)", 11) + padL("bias med", 12) + padL("bias min", 11)
            + padL("plain med", 12) + padL("RTF(bias)", 11))

        let engines: [(String, @Sendable () -> any SpeechEngine)] = [
            ("Parakeet v3", { ParakeetEngine(profile: .tdtV3, modelsDir: dir) }),
            ("Parakeet 110M", { ParakeetEngine(profile: .tdtCtc110m, modelsDir: dir) }),
            ("Whisper", { WhisperEngine(modelsDir: dir) }),
            ("Apple", { AppleEngine() }),
        ]

        for (name, make) in engines {
            let engine = make()
            let loadMs = await time { try? await engine.loadIfNeeded() }

            let biasMs = await measure(engine, wav, Self.bias, warmups: warmups, iterations: iterations)
            let plainMs = await measure(engine, wav, [], warmups: warmups, iterations: iterations)
            let sample = (try? await engine.transcribe(wavURL: wav, biasTerms: Self.bias)) ?? "<error>"
            await engine.evict()

            let biasMed = median(biasMs), biasMin = biasMs.min() ?? 0, plainMed = median(plainMs)
            func ms(_ x: Double) -> String { String(format: "%.0f", x) + "ms" }
            print(pad(name, 16) + padL(ms(loadMs), 11) + padL(ms(biasMed), 12) + padL(ms(biasMin), 11)
                + padL(ms(plainMed), 12) + padL(String(format: "%.3f", (biasMed / 1000) / audioSec), 11))
            print("   bias overhead: \(ms(biasMed - plainMed))   text: \(sample.prefix(90))…")
        }
        print("=== end ===\n")
    }

    private func measure(
        _ engine: any SpeechEngine, _ wav: URL, _ terms: [String], warmups: Int, iterations: Int
    ) async -> [Double] {
        for _ in 0..<warmups { _ = try? await engine.transcribe(wavURL: wav, biasTerms: terms) }
        var times: [Double] = []
        for _ in 0..<iterations {
            times.append(await time { _ = try? await engine.transcribe(wavURL: wav, biasTerms: terms) })
        }
        return times
    }

    private func time(_ body: () async -> Void) async -> Double {
        let t0 = Date()
        await body()
        return Date().timeIntervalSince(t0) * 1000
    }

    private func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[s.count / 2]
    }

    // MARK: - Audio fixture (real speech via `say`, generated once)

    static func audioURL() throws -> URL {
        let wav = URL(fileURLWithPath: "/tmp/keyscribe-bench.wav")
        if FileManager.default.fileExists(atPath: wav.path) { return wav }
        let aiff = "/tmp/keyscribe-bench.aiff"
        let passage = """
            I am building a dictation app called KeyScribe on top of FluidBloo. The speech recognition \
            runs entirely on device using Parakeet and WhisperKit. KeyScribe tokenizes sensitive spans \
            before any optional rewrite, so nothing leaks to the cloud. The FluidBloo engine pairs a \
            transducer model with a constrained CTC keyword spotter for recognition bias. We tested \
            KeyScribe against Whisper and Apple SpeechAnalyzer, measuring latency and accuracy on long \
            passages. FluidBloo and KeyScribe both handle technical vocabulary like eigenvector \
            decomposition and Bayesian inference without trouble.
            """
        try shell("/usr/bin/say", ["-o", aiff, passage])
        try shell("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav.path])
        return wav
    }

    static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    static func shell(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
    }
}
