import FluidAudio
import Foundation
import KeyScribeKit

enum VoiceSweep {
    struct Options {
        var lines: [String]
        var output: URL
        var takes = 2
        var route = "default"
        var voice = SpokenVoices.recommended
        var stopFirst = false
        var stopAfter: Duration = .milliseconds(150)
        var overlap = false
    }

    struct Take: Encodable {
        let line: Int
        let take: Int
        let route: String
        let voice: String
        let file: String
        let seconds: Double
        let peak: Float
        let rms: Float
        let clippedSamples: Int
        let problem: String?
        let similarityToFirstTake: Double?
        let identicalToFirstTake: Bool?
        let predictedDurations: [Int32]
        let stageMilliseconds: [String: Double]
        let error: String?
    }

    static func units(_ route: String) -> KokoroAneComputeUnits? {
        switch route {
        case "default": .default
        case "gpu": .aneTailGpu
        case "cpu": .aneTailCpu
        default: nil
        }
    }

    static func run(_ options: Options) async -> Bool {
        guard let units = units(options.route) else {
            print("Unknown --route \(options.route): use default, gpu or cpu.")
            return false
        }
        let voice = KokoroVoice.shared
        guard voice.isInstalled, voice.isIntact else {
            print("The natural voice is not installed. Download it in Settings first.")
            return false
        }
        let manager = KokoroAneManager(variant: .english, directory: voice.directory, computeUnits: units)
        do {
            try await manager.initialize()
        } catch {
            print("The voice did not load: \(error)")
            return false
        }
        do {
            try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
        } catch {
            print("Could not create \(options.output.path): \(error.localizedDescription)")
            await manager.cleanup()
            return false
        }
        var unwritten = 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var rows: [String] = []
        var flagged = 0
        print("Route: \(options.route) (\(KokoroVoice.route(units))) · voice: \(options.voice) · takes per line: \(options.takes) · output: \(options.output.path)")
        for (index, line) in options.lines.enumerated() {
            if options.stopFirst {
                let cancelled = Task { try await manager.synthesizeDetailed(text: line, voice: options.voice) }
                try? await Task.sleep(for: options.stopAfter)
                cancelled.cancel()
            }
            var results: [Result<KokoroAneSynthesisResult, any Error>] = []
            if options.overlap {
                results = await withTaskGroup(of: (Int, Result<KokoroAneSynthesisResult, any Error>).self) { group in
                    for take in 0..<options.takes {
                        group.addTask {
                            do { return (take, .success(try await manager.synthesizeDetailed(text: line, voice: options.voice))) }
                            catch { return (take, .failure(error)) }
                        }
                    }
                    var gathered: [(Int, Result<KokoroAneSynthesisResult, any Error>)] = []
                    for await item in group { gathered.append(item) }
                    return gathered.sorted { $0.0 < $1.0 }.map(\.1)
                }
            } else {
                for _ in 0..<options.takes {
                    do { results.append(.success(try await manager.synthesizeDetailed(text: line, voice: options.voice))) }
                    catch { results.append(.failure(error)) }
                }
            }
            let first = try? results.first?.get().samples
            for (take, result) in results.enumerated() {
                let row: Take
                switch result {
                case .success(let made):
                    let file = String(format: "line%03d-take%d.wav", index + 1, take + 1)
                    do {
                        let wav = try AudioWAV.data(from: made.samples, sampleRate: Double(made.sampleRate), normalize: false)
                        try wav.write(to: options.output.appendingPathComponent(file))
                    } catch {
                        unwritten += 1
                        print("line \(index + 1) take \(take + 1)  could not write \(file): \(error.localizedDescription)")
                    }
                    let measured = SpokenAudioCheck.measure(made.samples, sampleRate: made.sampleRate)
                    let similarity = take == 0 ? nil : first.map { SpokenAudioCheck.similarity($0, made.samples) }
                    let identical = take == 0 ? nil : first.map { $0 == made.samples }
                    let timings = made.timings
                    row = Take(
                        line: index + 1, take: take + 1, route: options.route, voice: options.voice, file: file,
                        seconds: measured.seconds, peak: measured.peak, rms: measured.rms, clippedSamples: measured.clippedSamples,
                        problem: SpokenAudioCheck.problem(in: made.samples)?.rawValue, similarityToFirstTake: similarity,
                        identicalToFirstTake: identical,
                        predictedDurations: made.predictedDurations,
                        stageMilliseconds: [
                            "albert": timings.albert, "postAlbert": timings.postAlbert, "alignment": timings.alignment,
                            "prosody": timings.prosody, "noise": timings.noise, "vocoder": timings.vocoder, "tail": timings.tail,
                        ],
                        error: nil)
                    print(String(
                        format: "line %3d take %d  %.2f s  peak %.3f  similarity %@%@%@", index + 1, take + 1, measured.seconds,
                        measured.peak, similarity.map { String(format: "%.3f", $0) } ?? "-",
                        identical.map { $0 ? "  identical" : "  differs" } ?? "", row.problem.map { "  \($0)" } ?? ""))
                case .failure(let error):
                    row = Take(
                        line: index + 1, take: take + 1, route: options.route, voice: options.voice, file: "", seconds: 0, peak: 0,
                        rms: 0, clippedSamples: 0, problem: nil, similarityToFirstTake: nil, identicalToFirstTake: nil, predictedDurations: [],
                        stageMilliseconds: [:], error: String(describing: error))
                    print("line \(index + 1) take \(take + 1)  failed: \(error)")
                }
                if row.problem != nil || row.error != nil { flagged += 1 }
                if let data = try? encoder.encode(row), let text = String(data: data, encoding: .utf8) {
                    rows.append(text)
                } else {
                    unwritten += 1
                    print("line \(index + 1) take \(take + 1)  could not be written to results.jsonl")
                }
            }
        }
        var wroteResults = true
        do {
            try (rows.joined(separator: "\n") + "\n").write(
                to: options.output.appendingPathComponent("results.jsonl"), atomically: true, encoding: .utf8)
        } catch {
            wroteResults = false
            print("Could not write results.jsonl: \(error.localizedDescription)")
        }
        print("\(rows.count) takes, \(flagged) rejected or failed. Similarity only points at takes worth listening to; it is not a verdict.")
        if unwritten > 0 { print("\(unwritten) takes could not be saved, so the evidence is incomplete.") }
        await manager.cleanup()
        return wroteResults && unwritten == 0
    }
}
