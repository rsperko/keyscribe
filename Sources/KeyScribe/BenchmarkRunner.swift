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
        var falseFiresUnbiased = 0.0
        var falseFiresBiased = 0.0
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
                r.werBiased += BenchmarkScoring.wer(reference: entry.text, hypothesis: biasedH)
                r.werUnbiased += BenchmarkScoring.wer(reference: entry.text, hypothesis: unbiasedH)
                if dur > 0 { r.rtfSum += elapsed / dur }
                if !entry.biasTerms.isEmpty {
                    r.termClips += 1
                    let recB = BenchmarkScoring.termRecall(terms: entry.biasTerms, in: biasedH)
                    r.recallBiased += recB
                    r.recallUnbiased += BenchmarkScoring.termRecall(terms: entry.biasTerms, in: unbiasedH)
                    r.falseFiresBiased += Double(BenchmarkScoring.termFalseFires(
                        terms: entry.biasTerms, reference: entry.text, hypothesis: biasedH))
                    r.falseFiresUnbiased += Double(BenchmarkScoring.termFalseFires(
                        terms: entry.biasTerms, reference: entry.text, hypothesis: unbiasedH))
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
        let jsonName = fuzzy ? "results-fuzzy.json" : "results.json"
        writeJSON(results, to: dir.appendingPathComponent(jsonName), fuzzy: fuzzy)
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
                let hyp = (try? await engine.transcribe(wavURL: wav, biasTerms: [])) ?? "<error>"
                let line = hyp.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
                print("RAW\t\(engine.id)\t\(entry.id)\t\(line)")
            }
            await engine.evict()
            FileHandle.standardError.write("· \(engine.id): done\n".data(using: .utf8)!)
        }
    }

    // `KeyScribe --benchmark <dir> --streaming`: transcribe each clip BOTH ways — batch and streaming (through the
    // real `StreamingDictationDriver` at realtime cadence, the exact live path: deferred start, chunk replay,
    // backpressure fallback) — and report WER for each so streaming↔batch parity is visible (P3-1: streaming must
    // not regress accuracy). A clip that degrades to batch is scored as batch and counted `fellBack`. No bias.
    static func runStreamingParity(dir: URL, only: Set<String>? = nil, raw: Bool = false) async {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let manifest = try? BenchmarkManifest.load(from: manifestURL) else {
            print("error: could not read \(manifestURL.path)")
            return
        }
        let engines = InstalledEngineFilter.filter(makeEngines())
            .filter { (only == nil || only!.contains($0.id)) && $0.supportsStreaming }
        guard !engines.isEmpty else { print("no installed streaming-capable engines to compare"); return }
        let verbose = ProcessInfo.processInfo.environment["KEYSCRIBE_BENCH_VERBOSE"] != nil
        // Raw streamed output per clip (the silence sweep uses this: no reference scoring, just the literal
        // text each streaming session emits so no-speech artifacts on the streaming path are visible).
        if raw {
            FileHandle.standardError.write("streaming raw dump: \(manifest.entries.count) clips × \(engines.count) engine(s)\n".data(using: .utf8)!)
            for engine in engines {
                do { try await engine.loadIfNeeded() } catch {
                    FileHandle.standardError.write("· \(engine.id): not installed / load failed\n".data(using: .utf8)!); continue
                }
                for entry in manifest.entries {
                    let wav = dir.appendingPathComponent(entry.file)
                    guard FileManager.default.fileExists(atPath: wav.path) else { continue }
                    let hyp: String
                    switch await streamingReplay(engine: engine, wav: wav) {
                    case .streamed(let t): hyp = t
                    case .fellBack: hyp = "<fell back to batch>"
                    case .failed: hyp = "<error>"
                    }
                    let line = hyp.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
                    print("RAW\t\(engine.id)\t\(entry.id)\t\(line)")
                }
                await engine.evict()
                FileHandle.standardError.write("· \(engine.id): done\n".data(using: .utf8)!)
            }
            return
        }
        print("Streaming parity: \(manifest.entries.count) clips × \(engines.count) engine(s)\n")

        for engine in engines {
            do { try await engine.loadIfNeeded() } catch {
                print("· \(engine.id): not installed / load failed"); continue
            }
            var batchWER = 0.0, streamWER = 0.0, clips = 0, fellBack = 0, failed = 0
            for entry in manifest.entries {
                let wav = dir.appendingPathComponent(entry.file)
                guard FileManager.default.fileExists(atPath: wav.path) else { continue }
                guard let batch = try? await engine.transcribe(wavURL: wav, biasTerms: []) else { continue }
                let stream: String, note: String
                switch await streamingReplay(engine: engine, wav: wav) {
                case .streamed(let t): stream = t; note = ""
                case .fellBack: stream = batch; note = " (fell back to batch)"; fellBack += 1   // app runs batch
                case .failed: stream = "<error>"; note = " (setup failed)"; failed += 1
                }
                let bw = BenchmarkScoring.wer(reference: entry.text, hypothesis: batch)
                let sw = BenchmarkScoring.wer(reference: entry.text, hypothesis: stream)
                batchWER += bw; streamWER += sw; clips += 1
                if verbose {
                    print("  [\(entry.id)] batchWER=\(pct(bw)) streamWER=\(pct(sw))\(note)")
                    if batch != stream {
                        print("    batch : \(batch)")
                        print("    stream: \(stream)")
                    }
                }
            }
            await engine.evict()
            let n = Double(max(clips, 1))
            print("· \(engine.id): clips=\(clips) batchWER=\(pct(batchWER / n)) streamWER=\(pct(streamWER / n)) Δ=\(pct((streamWER - batchWER) / n)) fellBack=\(fellBack) failed=\(failed)")
        }
    }

    enum StreamReplayOutcome {
        case streamed(String)   // the session finalized — this is the streamed transcript
        case fellBack           // the driver degraded to batch (short clip / backpressure / failure); the
                                // app would run batch here, so the user gets the batch text
        case failed             // could not even set up the replay (decode error)
    }

    // Drive the streaming session through the SAME production path a live dictation uses: the real
    // `StreamingDictationDriver` (deferred start at 4 s, buffered-chunk replay, backpressure→batch fallback) fed
    // via the same bounded `AsyncStream` + drain task + writer-sink as `DictationController.setUpStreamingIfEnabled`.
    // Chunks are paced to realtime (~0.1 s cadence) so the input queue drains as it does live, not an overrunning
    // burst. `KEYSCRIBE_STREAM_SPEEDUP=N` feeds N× faster (>1 may trip backpressure — a realistic batch fallback).
    private static func streamingReplay(engine: any SpeechEngine, wav: URL) async -> StreamReplayOutcome {
        let sampleRate = engine.captureSampleRate
        guard let samples = try? AudioDecoder.pcmMono(wav, sampleRate: sampleRate) else { return .failed }

        let policy = StreamingStartPolicy(
            thresholdSeconds: DictationController.streamingStartThresholdSeconds, sampleRate: sampleRate)
        let driver = StreamingDictationDriver(policy: policy, makeSession: {
            try await engine.makeStreamingSession(sampleRate: sampleRate, biasTerms: [])
        })
        let (stream, continuation) = AsyncStream.makeStream(
            of: [Float].self,
            bufferingPolicy: .bufferingNewest(DictationController.streamingBackpressureMaxChunks))
        let feedTask = Task { for await chunk in stream { await driver.ingest(chunk) } }

        let chunk = max(1, sampleRate / 10)                     // 0.1 s, the writer's cadence
        let chunkSeconds = Double(chunk) / Double(sampleRate)
        let speedup = max(0.1, Double(ProcessInfo.processInfo.environment["KEYSCRIBE_STREAM_SPEEDUP"] ?? "") ?? 1)
        let start = ProcessInfo.processInfo.systemUptime
        var i = 0, fed = 0
        loop: while i < samples.count {
            let end = min(i + chunk, samples.count)
            switch continuation.yield(Array(samples[i..<end])) {
            case .dropped: await driver.noteBackpressureDrop()  // outer buffer overflowed → trip to batch
            case .terminated: break loop
            default: break
            }
            i = end; fed += 1
            let target = Double(fed) * chunkSeconds / speedup
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            if target > elapsed {
                try? await Task.sleep(nanoseconds: UInt64((target - elapsed) * 1_000_000_000))
            }
        }
        continuation.finish()
        await feedTask.value                                    // drain every remaining ingest
        switch await driver.finish() {
        case .streamed(let text): return .streamed(text)
        case .fallBackToBatch: return .fellBack
        }
    }

    private static func pct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }

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
        print("\nengine                  clips  WER(unbias)  WER(bias)  recall(unbias)  recall(bias)  ff(unbias)  ff(bias)   RTF")
        print(String(repeating: "─", count: 116))
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
            print(
                "\(id.padding(toLength: 22, withPad: " ", startingAt: 0))  "
                + "\(String(format: "%4d", r.clips))   "
                + "\(pct(r.werUnbiased / n))       \(pct(r.werBiased / n))      "
                + "\(recallU)         \(recallB)     \(ffU)     \(ffB)   \(String(format: "%.3f", r.rtfSum / n))")
        }
        print("\n(RTF < 1.0 = faster than real time. recall = fraction of bias terms recovered.")
        print(" ff = total false fires: bias terms in the hypothesis that were absent from the reference.)")
    }

    private static func writeJSON(_ results: [String: EngineResult], to url: URL, fuzzy: Bool) {
        var engineObj: [String: [String: Double]] = [:]
        for (id, r) in results where r.clips > 0 {
            let n = Double(r.clips)
            let tn = max(Double(r.termClips), 1)
            engineObj[id] = [
                "clips": Double(r.clips),
                "termClips": Double(r.termClips),
                "werUnbiased": r.werUnbiased / n,
                "werBiased": r.werBiased / n,
                "recallUnbiased": r.termClips > 0 ? r.recallUnbiased / tn : -1,
                "recallBiased": r.termClips > 0 ? r.recallBiased / tn : -1,
                "falseFiresUnbiased": r.falseFiresUnbiased,
                "falseFiresBiased": r.falseFiresBiased,
                "rtf": r.rtfSum / n,
            ]
        }
        let obj: [String: Any] = ["fuzzy": fuzzy, "engines": engineObj]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
            print("\nwrote \(url.path)")
        }
    }
}
