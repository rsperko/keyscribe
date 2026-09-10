import AVFoundation
import Foundation
import KeyScribeKit

// Drives every shipping SpeechEngine adapter over recorded clips and reports WER (biased vs unbiased),
// bias term recall, and RTF per engine — so accuracy and speed are measured on the exact code paths that
// ship (recognition bias is Qwen3 native context and Whisper prompt tokens; other engines ignore terms),
// not a re-implementation. Headless: reads wavs, never touches mic/insertion/TCC. With no --engines, every
// installed engine runs, so you control cost by installing only what you want to compare.
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

    private struct Invocation {
        let manifest: BenchmarkManifest
        let engines: [any SpeechEngine]
    }

    private static func invocation(
        dir: URL, only: Set<String>?, streamingOnly: Bool = false
    ) -> Result<Invocation, InvocationError> {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let manifest = try? BenchmarkManifest.load(from: manifestURL) else {
            return .failure(InvocationError(message: "could not read \(manifestURL.path)"))
        }
        let runnable = InstalledEngineFilter.filter(makeEngines()).filter { !streamingOnly || $0.supportsStreaming }
        switch EngineSelection.resolve(requested: only, runnable: runnable.map(\.id)) {
        case .invalid(let ids):
            let why = streamingOnly
                ? "unknown, not installed, quarantined, or not streaming-capable"
                : "unknown, not installed, quarantined, or not supported on this macOS"
            return .failure(InvocationError(message: "cannot select \(ids.joined(separator: ", ")) (\(why))"))
        case .ok(let ids):
            return .success(Invocation(
                manifest: manifest, engines: ids.compactMap { id in runnable.first { $0.id == id } }))
        }
    }

    struct InvocationError: Error {
        let message: String
    }

    private static func refuse(_ error: InvocationError) -> CorpusRunOutcome {
        FileHandle.standardError.write(Data("error: \(error.message) — nothing was run or written\n".utf8))
        return .invocationError(error.message)
    }

    private static func report(_ verdict: CorpusRunVerdict, toStandardError: Bool = false) {
        let lines = verdict.passed
            ? ["PASS — every engine transcribed every clip"]
            : verdict.failures.map(\.line)
        for line in lines {
            if toStandardError {
                FileHandle.standardError.write(Data("\(line)\n".utf8))
            } else {
                print(line)
            }
        }
    }

    static func run(dir: URL, only: Set<String>? = nil, raw: Bool = false, fuzzy: Bool = false) async -> CorpusRunOutcome {
        let verbose = ProcessInfo.processInfo.environment["KEYSCRIBE_BENCH_VERBOSE"] != nil
        let invocation: Invocation
        switch self.invocation(dir: dir, only: only) {
        case .failure(let error): return refuse(error)
        case .success(let value): invocation = value
        }
        let manifest = invocation.manifest
        let engines = invocation.engines
        if raw {
            let verdict = await runRaw(dir: dir, manifest: manifest, engines: engines)
            report(verdict, toStandardError: true)
            return .ran(verdict)
        }
        print("Benchmark: \(manifest.entries.count) clips × \(engines.count) engines\n")

        var verdict = CorpusRunVerdict(engineIds: engines.map(\.id), clipIds: manifest.entries.map(\.id))
        var results: [String: EngineResult] = [:]
        var clipRows: [String: [String: [String: Double]]] = [:]
        for engine in engines {
            var r = EngineResult()
            var rows: [String: [String: Double]] = [:]
            do {
                try await engine.loadIfNeeded()
            } catch {
                r.status = "load failed"
                results[engine.id] = r
                verdict.recordLoadFailure(engine: engine.id, reason: "\(error)")
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
                    print("  missing \(wav.lastPathComponent)")
                    verdict.record(engine: engine.id, clip: entry.id, outcome: .missingAudio)
                    continue
                }
                let dur = audioDuration(wav)
                let start = Date()
                let biased: String
                let unbiasedRaw: String
                let elapsed: TimeInterval
                do {
                    biased = try await engine.transcribe(wavURL: wav, biasTerms: entry.biasTerms)
                    elapsed = Date().timeIntervalSince(start)
                    unbiasedRaw = try await engine.transcribe(wavURL: wav, biasTerms: [])
                } catch {
                    verdict.record(engine: engine.id, clip: entry.id, outcome: .failed("\(error)"))
                    continue
                }

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
                verdict.record(engine: engine.id, clip: entry.id, outcome: .transcribed)
            }
            await engine.evict()
            results[engine.id] = r
            clipRows[engine.id] = rows
        }
        printTable(results, engineOrder: engines.map(\.id))
        let failed = verdict.failedEngineIds
        let jsonName = fuzzy ? "results-fuzzy.json" : "results.json"
        writeJSON(
            results.filter { !failed.contains($0.key) }, clips: clipRows.filter { !failed.contains($0.key) },
            to: dir.appendingPathComponent(jsonName), fuzzy: fuzzy, replace: only == nil, dropping: failed)
        print("")
        report(verdict)
        return .ran(verdict)
    }

    private static func runRaw(
        dir: URL, manifest: BenchmarkManifest, engines: [any SpeechEngine]
    ) async -> CorpusRunVerdict {
        FileHandle.standardError.write("raw dump: \(manifest.entries.count) clips × \(engines.count) engines\n".data(using: .utf8)!)
        var verdict = CorpusRunVerdict(engineIds: engines.map(\.id), clipIds: manifest.entries.map(\.id))
        for engine in engines {
            do {
                try await engine.loadIfNeeded()
            } catch {
                FileHandle.standardError.write("· \(engine.id): load failed\n".data(using: .utf8)!)
                verdict.recordLoadFailure(engine: engine.id, reason: "\(error)")
                continue
            }
            for entry in manifest.entries {
                let wav = dir.appendingPathComponent(entry.file)
                guard FileManager.default.fileExists(atPath: wav.path) else {
                    verdict.record(engine: engine.id, clip: entry.id, outcome: .missingAudio)
                    continue
                }
                // Honor the manifest's bias terms so a silence/noise sweep can be run with the dictionary
                // active (the silence-with-bias probe). Empty biasTerms (the no-speech table's manifests)
                // reproduce the plain sweep unchanged.
                let hyp: String
                do {
                    hyp = try await engine.transcribe(wavURL: wav, biasTerms: entry.biasTerms)
                    verdict.record(engine: engine.id, clip: entry.id, outcome: .transcribed)
                } catch {
                    hyp = "<error>"
                    verdict.record(engine: engine.id, clip: entry.id, outcome: .failed("\(error)"))
                }
                let line = hyp.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
                print("RAW\t\(engine.id)\t\(entry.id)\t\(line)")
            }
            await engine.evict()
            FileHandle.standardError.write("· \(engine.id): done\n".data(using: .utf8)!)
        }
        return verdict
    }

    // Transcribes each clip BOTH ways — batch and streaming (through the real `StreamingDictationDriver`
    // at realtime cadence, the exact live path: deferred start, chunk replay, backpressure fallback) —
    // and reports WER for each so streaming↔batch accuracy parity is visible. A clip that degrades to
    // batch is scored as batch and counted `fellBack`. No bias.
    static func runStreamingParity(dir: URL, only: Set<String>? = nil, raw: Bool = false) async -> CorpusRunOutcome {
        let invocation: Invocation
        switch self.invocation(dir: dir, only: only, streamingOnly: true) {
        case .failure(let error): return refuse(error)
        case .success(let value): invocation = value
        }
        let manifest = invocation.manifest
        let engines = invocation.engines
        var verdict = CorpusRunVerdict(engineIds: engines.map(\.id), clipIds: manifest.entries.map(\.id))
        let verbose = ProcessInfo.processInfo.environment["KEYSCRIBE_BENCH_VERBOSE"] != nil
        // Raw streamed output per clip (the silence sweep uses this: no reference scoring, just the literal
        // text each streaming session emits so no-speech artifacts on the streaming path are visible).
        if raw {
            FileHandle.standardError.write("streaming raw dump: \(manifest.entries.count) clips × \(engines.count) engine(s)\n".data(using: .utf8)!)
            for engine in engines {
                do { try await engine.loadIfNeeded() } catch {
                    FileHandle.standardError.write("· \(engine.id): load failed\n".data(using: .utf8)!)
                    verdict.recordLoadFailure(engine: engine.id, reason: "\(error)")
                    continue
                }
                for entry in manifest.entries {
                    let wav = dir.appendingPathComponent(entry.file)
                    guard FileManager.default.fileExists(atPath: wav.path) else {
                        verdict.record(engine: engine.id, clip: entry.id, outcome: .missingAudio)
                        continue
                    }
                    let (hyp, outcome) = await rawStreamingTranscript(engine: engine, wav: wav)
                    verdict.record(engine: engine.id, clip: entry.id, outcome: outcome)
                    let line = hyp.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
                    print("RAW\t\(engine.id)\t\(entry.id)\t\(line)")
                }
                await engine.evict()
                FileHandle.standardError.write("· \(engine.id): done\n".data(using: .utf8)!)
            }
            report(verdict, toStandardError: true)
            return .ran(verdict)
        }
        print("Streaming parity: \(manifest.entries.count) clips × \(engines.count) engine(s)\n")

        for engine in engines {
            do { try await engine.loadIfNeeded() } catch {
                print("· \(engine.id): load failed")
                verdict.recordLoadFailure(engine: engine.id, reason: "\(error)")
                continue
            }
            var batchWER = 0.0, streamWER = 0.0, clips = 0, fellBack = 0, failed = 0
            for entry in manifest.entries {
                let wav = dir.appendingPathComponent(entry.file)
                guard FileManager.default.fileExists(atPath: wav.path) else {
                    verdict.record(engine: engine.id, clip: entry.id, outcome: .missingAudio)
                    continue
                }
                let batch: String
                do {
                    batch = try await engine.transcribe(wavURL: wav, biasTerms: [])
                } catch {
                    verdict.record(engine: engine.id, clip: entry.id, outcome: .failed("\(error)"))
                    continue
                }
                let stream: String, note: String
                switch await streamingReplay(engine: engine, wav: wav) {
                case .streamed(let t):
                    stream = t; note = ""
                    verdict.record(engine: engine.id, clip: entry.id, outcome: .transcribed)
                case .fellBack:
                    stream = batch; note = " (fell back to batch)"; fellBack += 1   // app runs batch
                    verdict.record(engine: engine.id, clip: entry.id, outcome: .transcribed)
                case .failed:
                    stream = "<error>"; note = " (setup failed)"; failed += 1
                    verdict.record(engine: engine.id, clip: entry.id, outcome: .failed("streaming replay could not start"))
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
        print("")
        report(verdict)
        return .ran(verdict)
    }

    static func rawStreamingTranscript(
        engine: any SpeechEngine, wav: URL
    ) async -> (text: String, outcome: CorpusRunVerdict.ClipOutcome) {
        switch await streamingReplay(engine: engine, wav: wav) {
        case .streamed(let text):
            return (text, .transcribed)
        case .fellBack:
            do {
                return (try await engine.transcribe(wavURL: wav, biasTerms: []), .transcribed)
            } catch {
                return ("<error>", .failed("fell back to batch, which failed: \(error)"))
            }
        case .failed:
            return ("<error>", .failed("streaming replay could not start"))
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
        to url: URL, fuzzy: Bool, replace: Bool, dropping: Set<String>
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
            existing: existing.engines, fresh: fresh, replace: replace, dropping: dropping)
        let freshClips = clips.filter { !$0.value.isEmpty }
        let clipsObj = BenchmarkResultsMerge.merged(
            existing: existing.clips, fresh: freshClips, replace: replace, dropping: dropping)
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
