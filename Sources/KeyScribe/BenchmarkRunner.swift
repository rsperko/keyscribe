import AVFoundation
import Foundation
import KeyScribeKit

// Dev tool: `KeyScribe --benchmark <dir>`. Drives every shipping SpeechEngine adapter over recorded
// clips and reports WER (biased vs unbiased), bias term recall, and RTF per engine — so accuracy and
// speed are measured on the exact code paths that ship (incl. Parakeet CTC-WS and Qwen3 context bias),
// not a re-implementation. Headless: reads wavs, never touches mic/insertion/TCC. Engines whose
// models aren't installed are skipped, so you control cost by installing only what you want to compare.
enum BenchmarkRunner {
    struct EngineResult {
        var status = "ok"
        var clips = 0
        var werUnbiased = 0.0
        var werBiased = 0.0
        var rtfSum = 0.0
        var termClips = 0
        var recallUnbiased = 0.0
        var recallBiased = 0.0
    }

    static func run(dir: URL, only: Set<String>? = nil, raw: Bool = false, fuzzy: Bool = false) async {
        let verbose = ProcessInfo.processInfo.environment["KEYSCRIBE_BENCH_VERBOSE"] != nil
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let manifest = try? BenchmarkManifest.load(from: manifestURL) else {
            print("error: could not read \(manifestURL.path)")
            return
        }
        let engines = makeEngines().filter { only == nil || only!.contains($0.id) }
        if raw {
            await runRaw(dir: dir, manifest: manifest, engines: engines)
            return
        }
        print("Benchmark: \(manifest.entries.count) clips × \(engines.count) engines\n")

        var results: [String: EngineResult] = [:]
        for engine in engines {
            var r = EngineResult()
            do {
                try await engine.loadIfNeeded()
            } catch {
                r.status = "not installed / load failed"
                results[engine.id] = r
                print("· \(engine.id): \(r.status)")
                continue
            }
            // Warm up so RTF excludes one-time JIT/compile cost.
            if let first = manifest.entries.first {
                _ = try? await engine.transcribe(
                    wavURL: dir.appendingPathComponent("\(first.id).wav"), biasTerms: [])
            }
            for entry in manifest.entries {
                let wav = dir.appendingPathComponent("\(entry.id).wav")
                guard FileManager.default.fileExists(atPath: wav.path) else {
                    print("  missing \(wav.lastPathComponent), skipping")
                    continue
                }
                let dur = audioDuration(wav)
                let start = Date()
                guard let biased = try? await engine.transcribe(wavURL: wav, biasTerms: entry.biasTerms)
                else { continue }
                let elapsed = Date().timeIntervalSince(start)
                let unbiasedRaw = (try? await engine.transcribe(wavURL: wav, biasTerms: [])) ?? biased

                // Optionally apply the real post-STT fuzzy stage (dictionary = this clip's bias terms)
                // so we can measure how much it recovers on top of the engine — the lever for bias-less
                // engines. Timed RTF stays engine-only (fuzzy runs after `elapsed`).
                var biasedH = biased
                var unbiasedH = unbiasedRaw
                if fuzzy, !entry.biasTerms.isEmpty {
                    let prepared = FuzzyCorrector.prepare(entry.biasTerms)
                    biasedH = FuzzyCorrector.apply(biased, prepared: prepared)
                    unbiasedH = FuzzyCorrector.apply(unbiasedRaw, prepared: prepared)
                }

                r.clips += 1
                r.werBiased += BenchmarkScoring.wer(reference: entry.text, hypothesis: biasedH)
                r.werUnbiased += BenchmarkScoring.wer(reference: entry.text, hypothesis: unbiasedH)
                if dur > 0 { r.rtfSum += elapsed / dur }
                if !entry.biasTerms.isEmpty {
                    r.termClips += 1
                    let recB = BenchmarkScoring.termRecall(terms: entry.biasTerms, in: biasedH)
                    r.recallBiased += recB
                    r.recallUnbiased += BenchmarkScoring.termRecall(terms: entry.biasTerms, in: unbiasedH)
                    if verbose, recB < 1 {
                        let missed = entry.biasTerms.filter { biasedH.range(of: $0, options: .caseInsensitive) == nil }
                        print("  [\(engine.id) \(entry.id)] MISS \(missed)")
                        print("    want : \(entry.text)")
                        print("    bias : \(biasedH)")
                        print("    plain: \(unbiasedH)")
                    }
                }
            }
            await engine.evict()
            results[engine.id] = r
        }
        printTable(results, engineOrder: engines.map(\.id))
        writeJSON(results, to: dir.appendingPathComponent("results.json"))
    }

    private static func runRaw(dir: URL, manifest: BenchmarkManifest, engines: [any SpeechEngine]) async {
        FileHandle.standardError.write("raw dump: \(manifest.entries.count) clips × \(engines.count) engines\n".data(using: .utf8)!)
        for engine in engines {
            do {
                try await engine.loadIfNeeded()
            } catch {
                FileHandle.standardError.write("· \(engine.id): not installed / load failed\n".data(using: .utf8)!)
                continue
            }
            for entry in manifest.entries {
                let wav = dir.appendingPathComponent("\(entry.id).wav")
                guard FileManager.default.fileExists(atPath: wav.path) else { continue }
                let hyp = (try? await engine.transcribe(wavURL: wav, biasTerms: [])) ?? "<error>"
                let line = hyp.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
                print("RAW\t\(engine.id)\t\(entry.id)\t\(line)")
            }
            await engine.evict()
            FileHandle.standardError.write("· \(engine.id): done\n".data(using: .utf8)!)
        }
    }

    private static func makeEngines() -> [any SpeechEngine] {
        EngineRegistry.makeAll(modelsDir: KeyScribePaths.modelsDir)
    }

    private static func audioDuration(_ url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        let sr = f.fileFormat.sampleRate
        return sr > 0 ? Double(f.length) / sr : 0
    }

    private static func printTable(_ results: [String: EngineResult], engineOrder: [String]) {
        func pct(_ v: Double) -> String { String(format: "%5.1f%%", v * 100) }
        print("\nengine                  clips  WER(unbias)  WER(bias)  recall(unbias)  recall(bias)   RTF")
        print(String(repeating: "─", count: 92))
        for id in engineOrder {
            guard let r = results[id] else { continue }
            guard r.status == "ok", r.clips > 0 else {
                print("\(id.padding(toLength: 22, withPad: " ", startingAt: 0))  \(r.status)")
                continue
            }
            let n = Double(r.clips)
            let tn = max(Double(r.termClips), 1)
            let recallU = r.termClips > 0 ? pct(r.recallUnbiased / tn) : "   n/a"
            let recallB = r.termClips > 0 ? pct(r.recallBiased / tn) : "   n/a"
            print(
                "\(id.padding(toLength: 22, withPad: " ", startingAt: 0))  "
                + "\(String(format: "%4d", r.clips))   "
                + "\(pct(r.werUnbiased / n))       \(pct(r.werBiased / n))      "
                + "\(recallU)         \(recallB)     \(String(format: "%.3f", r.rtfSum / n))")
        }
        print("\n(RTF < 1.0 = faster than real time. recall = fraction of bias terms recovered.)")
    }

    private static func writeJSON(_ results: [String: EngineResult], to url: URL) {
        var obj: [String: [String: Double]] = [:]
        for (id, r) in results where r.clips > 0 {
            let n = Double(r.clips)
            let tn = max(Double(r.termClips), 1)
            obj[id] = [
                "clips": Double(r.clips),
                "werUnbiased": r.werUnbiased / n,
                "werBiased": r.werBiased / n,
                "recallUnbiased": r.termClips > 0 ? r.recallUnbiased / tn : -1,
                "recallBiased": r.termClips > 0 ? r.recallBiased / tn : -1,
                "rtf": r.rtfSum / n,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
            print("\nwrote \(url.path)")
        }
    }
}
