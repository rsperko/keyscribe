import AVFoundation
import Foundation
import KeyScribeKit

// Drives every installed SpeechEngine over recorded command utterances through the REAL local (no-LLM)
// dictation pipeline, checking each case's declarative assertions against the exact transcripts real
// engines produce (spurious terminators, casing, clause segmentation) — what unit tests structurally
// can't cover. Adding a case is a manifest row, not code (principles.md §2). Headless: reads wavs, never
// touches mic/insertion/TCC/clipboard (clipboard value comes from the manifest).
enum CommandCheckRunner {
    struct Manifest: Decodable {
        let context: Context?
        let clips: [Clip]
        struct Context: Decodable {
            let clipboard: String?
            let replacements: [Replacement]?
        }
        struct Replacement: Decodable {
            let heard: String
            let replace: String
            let isRegex: Bool?
        }
        struct Clip: Decodable {
            let id: String
            let file: String?
            let text: String
            let checks: Checks
            struct Checks: Decodable { let command: CommandCheck.Assertion }
            var wavName: String { file ?? "\(id).wav" }
        }
    }

    enum Run {
        case invocationError(String)
        case ran(CommandCheckReport)
    }

    static func run(dir: URL, only: Set<String>? = nil) async -> Run {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return .invocationError("could not read \(manifestURL.path)")
        }
        let runnable = InstalledEngineFilter.filter(EngineRegistry.makeAll(modelsDir: KeyScribePaths.modelsDir))
        let engines: [any SpeechEngine]
        switch EngineSelection.resolve(requested: only, runnable: runnable.map(\.id)) {
        case .invalid(let ids):
            return .invocationError(
                "cannot select \(ids.joined(separator: ", ")) (unknown, not installed, quarantined, or not supported on this macOS)")
        case .ok(let ids):
            engines = ids.compactMap { id in runnable.first { $0.id == id } }
        }
        let rules = (manifest.context?.replacements ?? []).map {
            ReplacementRule(heard: $0.heard, replace: $0.replace, isRegex: $0.isRegex ?? false)
        }
        let clipboard = manifest.context?.clipboard ?? ""
        print("Commands check: \(manifest.clips.count) clips × \(engines.count) engines\n")

        var summary: [(id: String, clean: Int, total: Int, status: String, failedClips: [String])] = []
        for engine in engines {
            do { try await engine.loadIfNeeded() } catch {
                summary.append((engine.id, 0, 0, "load failed", []))
                print("· \(engine.id): load failed (\(error))\n")
                continue
            }
            print("── \(engine.id) " + String(repeating: "─", count: max(0, 40 - engine.id.count)))
            var clean = 0, total = 0
            var failedClips: [String] = []
            for c in manifest.clips {
                let wav = dir.appendingPathComponent(c.wavName)
                guard FileManager.default.fileExists(atPath: wav.path) else {
                    print("  ✗ \(c.id): missing \(wav.lastPathComponent)")
                    failedClips.append(c.id)
                    continue
                }
                let transcript: String
                do {
                    transcript = try await engine.transcribe(wavURL: wav, biasTerms: [])
                } catch {
                    print("  ✗ \(c.id): transcription failed (\(error))")
                    failedClips.append(c.id)
                    continue
                }
                total += 1
                let output = process(transcript: transcript, clipboard: clipboard, rules: rules)
                let outcome = CommandCheck.evaluate(output: output, assertion: c.checks.command)
                if outcome.passed { clean += 1 }
                let flags = outcome.passed ? "" : "  [\(outcome.failures.joined(separator: ", "))]"
                print("  \(outcome.passed ? "✓" : "✗") \(c.id)\(flags)")
                print("      heard : \(oneLine(transcript))")
                print("      out   : \(oneLine(output))")
            }
            await engine.evict()
            summary.append((engine.id, clean, total, "ok", failedClips))
            print("")
        }
        printSummary(summary.map { ($0.id, $0.clean, $0.total, $0.status) })
        return .ran(CommandCheckReport(engines: summary.map {
            .init(id: $0.id, clean: $0.clean, total: $0.total, loaded: $0.status == "ok", failedClips: $0.failedClips)
        }))
    }

    static func failureLines(_ report: CommandCheckReport) -> [String] {
        report.engines.flatMap { engine -> [String] in
            guard engine.loaded else { return ["FAIL — \(engine.id): failed to load"] }
            return engine.failedClips.map { "FAIL — \(engine.id) \($0): audio missing or transcription failed" }
        }
    }

    // Mirrors the local (no-LLM) pipeline DictationController builds for a plain live-edits mode —
    // dictationPipeline + produceDictationText, including the whole-utterance replacement bypass (a rule
    // owning the entire utterance is inserted verbatim, short-circuited via `bareReplacement`).
    static func process(transcript: String, clipboard: String, rules: [ReplacementRule]) -> String {
        var stages: [any PipelineStage] = [LiveEditsStage(), ReplacementsStage(rules: rules)]
        stages.append(TokenizingStage.verbatim())
        // Clipboard sorts after verbatim and reads the post-verbatim text, so a phrase inside a verbatim
        // span stays literal — exactly as dictationPipeline decides.
        stages.append(TokenizingStage.clipboard(read: { clipboard }))
        let pipeline = Pipeline(stages)
        let payload = pipeline.forward(transcript)
        if let bare = payload.bareReplacement { return bare.text }
        return pipeline.restore(payload.text)
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\t", with: "⇥")
    }

    private static func printSummary(_ rows: [(id: String, clean: Int, total: Int, status: String)]) {
        print("summary            clean / total")
        print(String(repeating: "─", count: 40))
        for r in rows {
            let name = r.id.padding(toLength: 18, withPad: " ", startingAt: 0)
            print(r.status == "ok" ? "\(name) \(r.clean) / \(r.total)" : "\(name) \(r.status)")
        }
        print("\n✓ = every declared assertion held on the real transcript.")
    }
}
