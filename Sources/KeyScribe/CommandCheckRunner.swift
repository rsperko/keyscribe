import AVFoundation
import Foundation
import KeyScribeKit

// Dev tool: `KeyScribe --commands-check <dir>`. Drives every installed SpeechEngine over recorded
// command utterances, runs the REAL local (no-LLM) dictation pipeline for a plain live-edits mode, and
// checks each case's declarative assertions (CommandCheck) against the exact transcripts real engines
// produce (spurious terminators, casing, clause segmentation) — what unit tests structurally can't cover.
// Adding a case is a manifest row, not code (principles.md §2). Headless: reads wavs, never touches
// mic/insertion/TCC/clipboard (clipboard value from the manifest). Uninstalled engines are skipped.
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

    @discardableResult
    static func run(dir: URL, only: Set<String>? = nil) async -> CommandCheckReport {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            print("error: could not read \(manifestURL.path)")
            return CommandCheckReport(engines: [])
        }
        let engines = InstalledEngineFilter.filter(EngineRegistry.makeAll(modelsDir: KeyScribePaths.modelsDir))
            .filter { only == nil || only!.contains($0.id) }
        let rules = (manifest.context?.replacements ?? []).map {
            ReplacementRule(heard: $0.heard, replace: $0.replace, isRegex: $0.isRegex ?? false)
        }
        let clipboard = manifest.context?.clipboard ?? ""
        print("Commands check: \(manifest.clips.count) clips × \(engines.count) engines\n")

        var summary: [(id: String, clean: Int, total: Int, status: String)] = []
        for engine in engines {
            do { try await engine.loadIfNeeded() } catch {
                summary.append((engine.id, 0, 0, "not installed / load failed"))
                print("· \(engine.id): not installed / load failed\n")
                continue
            }
            print("── \(engine.id) " + String(repeating: "─", count: max(0, 40 - engine.id.count)))
            var clean = 0, total = 0
            for c in manifest.clips {
                let wav = dir.appendingPathComponent(c.wavName)
                guard FileManager.default.fileExists(atPath: wav.path) else {
                    print("  \(c.id): missing \(wav.lastPathComponent)"); continue
                }
                guard let transcript = try? await engine.transcribe(wavURL: wav, biasTerms: []) else {
                    print("  \(c.id): <transcribe error>"); continue
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
            summary.append((engine.id, clean, total, "ok"))
            print("")
        }
        printSummary(summary)
        return CommandCheckReport(engines: summary.map {
            .init(id: $0.id, clean: $0.clean, total: $0.total, loaded: $0.status == "ok")
        })
    }

    // The local (no-LLM) pipeline DictationController builds for a plain live-edits mode. Mirrors
    // dictationPipeline + produceDictationText, including the whole-utterance replacement bypass (a rule
    // owning the entire utterance is inserted verbatim, skipping the reverse pass — the `bareReplacement`
    // short-circuit).
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
