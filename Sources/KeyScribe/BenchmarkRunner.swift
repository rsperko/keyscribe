import AVFoundation
import Foundation
import KeyScribeKit

// Drives every shipping SpeechEngine adapter over recorded clips and reports WER (biased vs unbiased),
// bias term recall, and RTF per engine — so accuracy and speed are measured on the exact code paths that
// ship (recognition bias is Qwen3 native context and Whisper prompt tokens; other engines ignore terms),
// not a re-implementation. Headless: reads wavs, never touches mic/insertion/TCC. Engines whose models
// aren't installed are skipped, so you control cost by installing only what you want to compare.
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
        var falseFiresUnbiased = 0.0
        var falseFiresBiased = 0.0
        var substFiresUnbiased = 0.0
        var substFiresBiased = 0.0
        var orthoFiresUnbiased = 0.0
        var orthoFiresBiased = 0.0
    }

    static func announceAppleModel(_ engines: [any SpeechEngine]) async {
        guard let apple = engines.first(where: { $0.id == "apple" }), #available(macOS 26, *) else { return }
        try? await apple.loadIfNeeded()
        FileHandle.standardError.write("· apple: \(await AppleEngine.statusText())\n".data(using: .utf8)!)
    }

    static func run(dir: URL, only: Set<String>? = nil, raw: Bool = false, fuzzy: Bool = false) async {
        let verbose = ProcessInfo.processInfo.environment["KEYSCRIBE_BENCH_VERBOSE"] != nil
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let manifest = try? BenchmarkManifest.load(from: manifestURL) else {
            print("error: could not read \(manifestURL.path)")
            return
        }
        let engines = InstalledEngineFilter.filter(makeEngines())
            .filter { only == nil || only!.contains($0.id) }
        await announceAppleModel(engines)
        if raw {
            await runRaw(dir: dir, manifest: manifest, engines: engines)
            return
        }
        print("Benchmark: \(manifest.entries.count) clips × \(engines.count) engines\n")

        var results: [String: EngineResult] = [:]
        var clipRows: [String: [String: [String: Double]]] = [:]
        for engine in engines {
            var r = EngineResult()
            var rows: [String: [String: Double]] = [:]
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
                    wavURL: dir.appendingPathComponent(first.file), biasTerms: [])
            }
            for entry in manifest.entries {
                let wav = dir.appendingPathComponent(entry.file)
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
                let clipWerB = BenchmarkScoring.wer(reference: entry.text, hypothesis: biasedH)
                let clipWerU = BenchmarkScoring.wer(reference: entry.text, hypothesis: unbiasedH)
                r.werBiased += clipWerB
                r.werUnbiased += clipWerU
                var row = ["werBiased": clipWerB, "werUnbiased": clipWerU]
                if dur > 0 { r.rtfSum += elapsed / dur }
                if !entry.biasTerms.isEmpty {
                    r.termClips += 1
                    let recB = BenchmarkScoring.termRecall(terms: entry.biasTerms, in: biasedH)
                    let recU = BenchmarkScoring.termRecall(terms: entry.biasTerms, in: unbiasedH)
                    row["recallBiased"] = recB
                    row["recallUnbiased"] = recU
                    r.recallBiased += recB
                    r.recallUnbiased += recU
                    // The breakdown's two classes sum to the total false fires, so derive ff from it
                    // rather than scoring termFalseFires a second time.
                    let breakdownB = BenchmarkScoring.termFalseFireBreakdown(
                        terms: entry.biasTerms, reference: entry.text, hypothesis: biasedH)
                    let breakdownU = BenchmarkScoring.termFalseFireBreakdown(
                        terms: entry.biasTerms, reference: entry.text, hypothesis: unbiasedH)
                    r.orthoFiresBiased += Double(breakdownB.orthographic)
                    r.substFiresBiased += Double(breakdownB.substitution)
                    r.orthoFiresUnbiased += Double(breakdownU.orthographic)
                    r.substFiresUnbiased += Double(breakdownU.substitution)
                    r.falseFiresBiased += Double(breakdownB.orthographic + breakdownB.substitution)
                    r.falseFiresUnbiased += Double(breakdownU.orthographic + breakdownU.substitution)
                    if verbose, recB < 1 {
                        let missed = entry.biasTerms.filter { biasedH.range(of: $0, options: .caseInsensitive) == nil }
                        print("  [\(engine.id) \(entry.id)] MISS \(missed)")
                        print("    want : \(entry.text)")
                        print("    bias : \(biasedH)")
                        print("    plain: \(unbiasedH)")
                    }
                }
                rows[entry.id] = row
            }
            await engine.evict()
            results[engine.id] = r
            clipRows[engine.id] = rows
        }
        printTable(results, engineOrder: engines.map(\.id))
        let jsonName = fuzzy ? "results-fuzzy.json" : "results.json"
        writeJSON(
            results, clips: clipRows, to: dir.appendingPathComponent(jsonName),
            fuzzy: fuzzy, replace: only == nil)
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
                let wav = dir.appendingPathComponent(entry.file)
                guard FileManager.default.fileExists(atPath: wav.path) else { continue }
                // Honor the manifest's bias terms so a silence/noise sweep can be run with the dictionary
                // active (the silence-with-bias probe). Empty biasTerms (the no-speech table's manifests)
                // reproduce the plain sweep unchanged.
                let hyp = (try? await engine.transcribe(wavURL: wav, biasTerms: entry.biasTerms)) ?? "<error>"
                let line = hyp.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
                print("RAW\t\(engine.id)\t\(entry.id)\t\(line)")
                fflush(stdout)
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
        print("\nengine                  clips  WER(unbias)  WER(bias)  recall(unbias)  recall(bias)  ff(unbias)  ff(bias)  sub(bias)   RTF")
        print(String(repeating: "─", count: 127))
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
            let ffU = r.termClips > 0 ? String(format: "%6d", Int(r.falseFiresUnbiased)) : "   n/a"
            let ffB = r.termClips > 0 ? String(format: "%6d", Int(r.falseFiresBiased)) : "   n/a"
            let subB = r.termClips > 0 ? String(format: "%6d", Int(r.substFiresBiased)) : "   n/a"
            print(
                "\(id.padding(toLength: 22, withPad: " ", startingAt: 0))  "
                + "\(String(format: "%4d", r.clips))   "
                + "\(pct(r.werUnbiased / n))       \(pct(r.werBiased / n))      "
                + "\(recallU)         \(recallB)     \(ffU)    \(ffB)    \(subB)   \(String(format: "%.3f", r.rtfSum / n))")
        }
        print("\n(RTF < 1.0 = faster than real time. recall = fraction of bias terms recovered.")
        print(" ff = total false fires (bias terms in the hypothesis, absent from the reference).")
        print(" sub(bias) = the substitution subset: fires whose words are NOT in the reference — different")
        print(" words the dictionary put in; the disqualifying class. ff − sub = orthographic snaps, tolerated.)")
    }

    private static func writeJSON(
        _ results: [String: EngineResult], clips: [String: [String: [String: Double]]],
        to url: URL, fuzzy: Bool, replace: Bool
    ) {
        var fresh: [String: [String: Double]] = [:]
        for (id, r) in results where r.clips > 0 {
            let n = Double(r.clips)
            let tn = max(Double(r.termClips), 1)
            fresh[id] = [
                "clips": Double(r.clips),
                "termClips": Double(r.termClips),
                "werUnbiased": r.werUnbiased / n,
                "werBiased": r.werBiased / n,
                "recallUnbiased": r.termClips > 0 ? r.recallUnbiased / tn : -1,
                "recallBiased": r.termClips > 0 ? r.recallBiased / tn : -1,
                "falseFiresUnbiased": r.falseFiresUnbiased,
                "falseFiresBiased": r.falseFiresBiased,
                "substFiresUnbiased": r.substFiresUnbiased,
                "substFiresBiased": r.substFiresBiased,
                "orthoFiresUnbiased": r.orthoFiresUnbiased,
                "orthoFiresBiased": r.orthoFiresBiased,
                "rtf": r.rtfSum / n,
            ]
        }
        let existing = readResults(from: url)
        let engineObj = BenchmarkResultsMerge.merged(
            existing: existing.engines, fresh: fresh, replace: replace)
        let freshClips = clips.filter { !$0.value.isEmpty }
        let clipsObj = BenchmarkResultsMerge.merged(
            existing: existing.clips, fresh: freshClips, replace: replace)
        let obj: [String: Any] = ["fuzzy": fuzzy, "engines": engineObj, "clips": clipsObj]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
            print("\nwrote \(url.path)")
        }
    }

    private static func readResults(
        from url: URL
    ) -> (engines: [String: [String: Double]], clips: [String: [String: [String: Double]]]) {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([:], [:]) }
        return (
            obj["engines"] as? [String: [String: Double]] ?? [:],
            obj["clips"] as? [String: [String: [String: Double]]] ?? [:]
        )
    }
}
