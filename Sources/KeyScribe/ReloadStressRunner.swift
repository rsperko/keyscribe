import AVFoundation
import Foundation
import KeyScribeKit

// Dev tool: `KeyScribe --reload-stress <dir>`. Reproduces the intermittent "No speech detected" seen
// under Frugal memory (evict-after-each-dictation) — a freshly RELOADED model that occasionally returns
// an empty transcript on real speech. It mirrors the live Frugal path exactly: per iteration it
// evict()s, loadIfNeeded()s a COLD model, transcribes one known non-silent clip through the same
// in-memory `transcribe(samples:)` path the DictationController prefers, applies the same
// OutputCleanup collapse (so a `[BLANK_AUDIO]`/annotation that would surface as noSpeech counts), and
// records whether the result is empty. Intermittent by nature, so it LOOPS: any empty result across the
// run is a reproduction. Headless — reads a wav, never touches the mic. Exit non-zero if any iteration
// came back empty.
enum ReloadStressRunner {
    @discardableResult
    static func run(dir: URL, only: Set<String>? = nil, iterations: Int = 12, biasTerms: [String] = []) async -> Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            print("error: could not read \(dir.path)"); return false
        }
        guard let clipName = names.filter({ $0.hasSuffix(".wav") }).sorted().first else {
            print("error: no *.wav files in \(dir.path)"); return false
        }
        let clip = dir.appendingPathComponent(clipName)
        let engines = InstalledEngineFilter.filter(EngineRegistry.makeAll(modelsDir: KeyScribePaths.modelsDir))
            .filter { only == nil || only!.contains($0.id) }
        guard !engines.isEmpty else {
            print("no installed engines matched — install one, or check --engines."); return false
        }
        let biasNote = biasTerms.isEmpty ? "no bias" : "bias: \(biasTerms.joined(separator: ","))"
        print("Reload stress: \(iterations)× cold reload of \(clipName) × \(engines.count) engines (\(biasNote))\n")

        var ranAny = false
        var anyEmpty = false
        for engine in engines {
            let usesSamples = engine.supportsSampleInput
            var samples: [Float]? = nil
            if usesSamples { samples = try? AudioDecoder.pcmMono(clip, sampleRate: engine.captureSampleRate) }
            print("── \(engine.id) " + String(repeating: "─", count: max(0, 40 - engine.id.count))
                + (usesSamples ? " (samples path)" : " (wav path)"))

            var empties: [Int] = []
            var loadFailed = false
            for i in 1...iterations {
                await engine.evict()
                do { try await engine.loadIfNeeded() } catch {
                    print("  iter \(i): cold reload FAILED: \(error)"); loadFailed = true; break
                }
                let raw: String?
                if usesSamples, let s = samples {
                    raw = try? await engine.transcribe(samples: s, sampleRate: engine.captureSampleRate, biasTerms: biasTerms)
                } else {
                    raw = try? await engine.transcribe(wavURL: clip, biasTerms: biasTerms)
                }
                let cleaned = OutputCleanup.strippingBoundaryAnnotation(
                    OutputCleanup.blankingNonSpeechAnnotation(raw ?? ""))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.isEmpty {
                    empties.append(i)
                    print("  ✗ iter \(i): EMPTY (raw: \(oneLine(raw ?? "<transcribe error>")))")
                }
            }
            await engine.evict()
            if loadFailed { continue }
            ranAny = true
            if empties.isEmpty {
                print("  ✓ \(iterations)/\(iterations) non-empty — no reproduction\n")
            } else {
                anyEmpty = true
                print("  ✗ \(empties.count)/\(iterations) came back EMPTY (iters \(empties.map(String.init).joined(separator: ","))) — REPRODUCED\n")
            }
        }
        if !ranAny { print("no engine could run — models missing?"); return false }
        print(anyEmpty
            ? "✗ FAIL — a cold-reloaded model returned an empty transcript on real speech (the Frugal 'No speech detected' bug)."
            : "✓ PASS — every cold reload produced a non-empty transcript.")
        return !anyEmpty
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\t", with: "⇥")
    }
}
