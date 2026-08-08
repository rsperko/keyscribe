import Foundation
import KeyScribeKit

enum VadProbeRunner {
    static func run(dir: URL, chunks: Bool = false) async -> Bool {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        let manifest: BenchmarkManifest
        do {
            manifest = try BenchmarkManifest.load(from: manifestURL)
        } catch {
            print("error: could not read \(manifestURL.path): \(error)")
            return false
        }
        guard await VADModel.ensureDownloaded(in: KeyScribePaths.modelsDir) else {
            print("error: VAD model unavailable (download failed)")
            return false
        }
        let detector = SpeechPresenceDetector(modelsDir: KeyScribePaths.modelsDir)
        await detector.prewarm()

        print("VAD probe: \(manifest.entries.count) clips\n")
        var speechCount = 0
        var suppressed: [String] = []
        var minSpeechMaxProb = Float.greatestFiniteMagnitude
        var latencies: [Double] = []
        var clearingCounts: [Int] = []
        var failures: [String] = []
        let expectedCount = manifest.entries.count { $0.expectedPresence != nil }

        for entry in manifest.entries {
            let wav = dir.appendingPathComponent(entry.file)
            guard FileManager.default.fileExists(atPath: wav.path) else {
                if entry.expectedPresence != nil {
                    print("  \(entry.id)  MISSING \(wav.lastPathComponent) — cannot verify its expectation")
                    failures.append("\(entry.id) (wav missing: \(entry.file))")
                } else {
                    print("  missing \(wav.lastPathComponent), skipping")
                }
                continue
            }
            let samples = try? AudioDecoder.pcmMono(wav, sampleRate: 16000)
            let reading = await detector.read(samples: samples, url: wav, sampleRate: 16000)
            latencies.append(reading.latencyMs)
            let verdict = reading.presence.rawValue
            // speechStart doubles as the empty-transcript recovery's trim boundary: "-" means chunk zero
            // already had speech, so a silent-engine take on this clip would not be retried.
            let speechStart = reading.speechStart.map { String(format: "%.3fs", $0) } ?? "-"
            print(String(
                format: "  %-28@  %-8@  maxP=%.3f  speechStart=%-7@  %.1fms",
                entry.id as NSString, verdict as NSString, reading.maxProbability,
                speechStart as NSString, reading.latencyMs))
            if chunks {
                let clearing = SpeechPresenceGate.chunksClearingGate(reading.chunkProbabilities)
                let run = SpeechPresenceGate.longestRunClearingGate(reading.chunkProbabilities)
                clearingCounts.append(clearing)
                print(String(
                    format: "      chunks=%d  n>=%.2f=%d  run=%d",
                    reading.chunkProbabilities.count, SpeechPresenceGate.gateThreshold, clearing, run))
                print("      p=[\(reading.chunkProbabilities.map { String(format: "%.2f", $0) }.joined(separator: " "))]")
            }
            if let expected = entry.expectedPresence, reading.presence != expected {
                failures.append("\(entry.id) (wanted \(expected.rawValue), got \(verdict))")
                print("      FAIL — expected \(expected.rawValue)")
            }
            if reading.presence == .noSpeech {
                suppressed.append(entry.id)
            } else {
                speechCount += 1
                minSpeechMaxProb = min(minSpeechMaxProb, reading.maxProbability)
            }
        }

        let avgLatency = latencies.isEmpty ? 0 : latencies.reduce(0, +) / Double(latencies.count)
        print("\nspeech=\(speechCount) suppressed=\(suppressed.count) avgLatency=\(String(format: "%.1f", avgLatency))ms")
        if speechCount > 0 && minSpeechMaxProb < .greatestFiniteMagnitude {
            print(String(
                format: "min take-level max probability over speech clips = %.3f (margin above %.2f = %.3f)",
                minSpeechMaxProb, SpeechPresenceGate.gateThreshold,
                minSpeechMaxProb - SpeechPresenceGate.gateThreshold))
        }
        if chunks && !clearingCounts.isEmpty {
            let histogram = Dictionary(grouping: clearingCounts, by: { min($0, 5) })
                .sorted { $0.key < $1.key }
                .map { "\($0.key == 5 ? "5+" : String($0.key)):\($0.value.count)" }
                .joined(separator: " ")
            print("clips by chunks clearing the threshold — \(histogram)")
        }
        if !suppressed.isEmpty {
            print("suppressed: \(suppressed.joined(separator: ", "))")
        }
        guard expectedCount > 0 else { return true }
        // Every expected clip either reaches the comparison or appends a missing-wav failure, so an empty
        // failure list already means all of them were checked — the gate cannot pass vacuously.
        if failures.isEmpty {
            print("PASS — all \(expectedCount) clips with a stated expectation met it.")
            return true
        }
        print("FAIL — \(failures.count)/\(expectedCount) clips missed their expectation:")
        for f in failures { print("  \(f)") }
        return false
    }
}
