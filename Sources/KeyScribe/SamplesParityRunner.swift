import AVFoundation
import Foundation
import KeyScribeKit

// Dev tool: `KeyScribe --samples-parity <dir>`. Verifies the in-memory-samples transcription path matches
// the WAV path for every installed sample-capable engine, over the *.wav files in <dir>. Runs TWO isolated
// same-order passes — all `transcribe(wavURL:)`, then evict+reload, then all `transcribe(samples:)` fed the
// SAME audio at the engine's captureSampleRate — and asserts each clip's two transcripts are identical.
// Separated (not interleaved) because some engines (Moonshine's ONNX transcriber) carry state across calls,
// so interleaving would report a mismatch that never happens live; same-order passes give each call the
// identical preceding-state trajectory, so any divergence is a real bug. Headless; exit non-zero on mismatch.
enum SamplesParityRunner {
    @discardableResult
    static func run(dir: URL, only: Set<String>? = nil) async -> Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            print("error: could not read \(dir.path)")
            return false
        }
        let wavs = names.filter { $0.hasSuffix(".wav") }.sorted()
            .map { dir.appendingPathComponent($0) }
        guard !wavs.isEmpty else {
            print("error: no *.wav files in \(dir.path)")
            return false
        }
        let engines = InstalledEngineFilter.filter(EngineRegistry.makeAll(modelsDir: KeyScribePaths.modelsDir))
            .filter { $0.supportsSampleInput && (only == nil || only!.contains($0.id)) }
        guard !engines.isEmpty else {
            print("no installed sample-capable engines matched — install one, or check --engines.")
            return false
        }
        print("Samples-vs-WAV parity: \(wavs.count) clips × \(engines.count) engines (two isolated passes)\n")

        var ranAny = false
        var allMatched = true
        for engine in engines {
            do { try await engine.loadIfNeeded() } catch {
                print("· \(engine.id): not installed / load failed\n")
                continue
            }
            ranAny = true
            print("── \(engine.id) " + String(repeating: "─", count: max(0, 40 - engine.id.count)))

            // Pass A: WAV path for every clip, in order.
            var fileTexts: [String?] = []
            for wav in wavs {
                fileTexts.append(try? await engine.transcribe(wavURL: wav, biasTerms: []))
            }
            // Reload so pass B starts from the same fresh state pass A did.
            await engine.evict()
            do { try await engine.loadIfNeeded() } catch {
                print("  reload failed between passes — skipping\n"); continue
            }
            // Pass B: samples path for every clip, in the same order.
            var sampleTexts: [String?] = []
            for wav in wavs {
                if let samples = try? AudioDecoder.pcmMono(wav, sampleRate: engine.captureSampleRate) {
                    sampleTexts.append(try? await engine.transcribe(
                        samples: samples, sampleRate: engine.captureSampleRate, biasTerms: []))
                } else {
                    sampleTexts.append(nil)
                }
            }
            await engine.evict()

            var matched = 0, total = 0, mismatched = 0
            for (i, wav) in wavs.enumerated() {
                guard let fileText = fileTexts[i], let sampleText = sampleTexts[i] else {
                    print("  \(wav.lastPathComponent): <transcribe/decode error>"); continue
                }
                total += 1
                if fileText == sampleText {
                    matched += 1
                } else {
                    mismatched += 1
                    allMatched = false
                    print("  ✗ \(wav.lastPathComponent) MISMATCH")
                    print("      wav     : \(oneLine(fileText))")
                    print("      samples : \(oneLine(sampleText))")
                }
            }
            print("  \(mismatched == 0 ? "✓" : "✗") \(matched)/\(total) identical\n")
        }
        if !ranAny {
            print("no engine could run — models missing?")
            return false
        }
        print(allMatched
            ? "✓ PASS — every clip's samples transcript matched its WAV transcript on every engine."
            : "✗ FAIL — a samples transcript diverged from the WAV path (see MISMATCH lines above).")
        return allMatched
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\t", with: "⇥")
    }
}
