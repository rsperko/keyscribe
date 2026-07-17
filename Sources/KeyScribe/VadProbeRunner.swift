import Foundation
import KeyScribeKit

enum VadProbeRunner {
    static func run(dir: URL) async {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let manifest = try? BenchmarkManifest.load(from: manifestURL) else {
            print("error: could not read \(manifestURL.path)")
            return
        }
        guard await VADModel.ensureDownloaded(in: KeyScribePaths.modelsDir) else {
            print("error: VAD model unavailable (download failed)")
            return
        }
        let detector = SpeechPresenceDetector(modelsDir: KeyScribePaths.modelsDir)
        await detector.prewarm()

        print("VAD probe: \(manifest.entries.count) clips\n")
        var speechCount = 0
        var suppressed: [String] = []
        var minSpeechMaxProb = Float.greatestFiniteMagnitude
        var latencies: [Double] = []

        for entry in manifest.entries {
            let wav = dir.appendingPathComponent(entry.file)
            guard FileManager.default.fileExists(atPath: wav.path) else {
                print("  missing \(wav.lastPathComponent), skipping")
                continue
            }
            let samples = try? AudioDecoder.pcmMono(wav, sampleRate: 16000)
            let reading = await detector.read(samples: samples, url: wav, sampleRate: 16000)
            latencies.append(reading.latencyMs)
            let verdict = reading.presence == .noSpeech ? "noSpeech" : "speech"
            // speechStart doubles as the empty-transcript recovery's trim boundary: "-" means chunk zero
            // already had speech, so a silent-engine take on this clip would not be retried.
            let speechStart = reading.speechStart.map { String(format: "%.3fs", $0) } ?? "-"
            print(String(
                format: "  %-28@  %-8@  maxP=%.3f  speechStart=%-7@  %.1fms",
                entry.id as NSString, verdict as NSString, reading.maxProbability,
                speechStart as NSString, reading.latencyMs))
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
        if !suppressed.isEmpty {
            print("suppressed: \(suppressed.joined(separator: ", "))")
        }
    }
}
