import AVFoundation
import Foundation
import KeyScribeKit

// Dev tool: `KeyScribe --commands-check <dir>`. Drives every installed SpeechEngine over recorded
// utterances that contain a spoken command — "scratch that", "verbatim …", "insert new line/
// paragraph/tab", "insert clipboard contents", and whole-utterance replacements — runs the REAL
// local (no-LLM) dictation pipeline the DictationController builds for a plain live-edits mode, and
// checks each case's declarative assertions (CommandCheck). It verifies the commands on the exact
// transcripts real engines produce (spurious terminators, casing, clause segmentation), not
// synthetic ones — the thing unit tests structurally cannot cover. Adding a checked case is a
// manifest row, not code (principles.md §2). Headless: reads wavs, never touches mic/insertion/TCC/
// clipboard; the clipboard value is supplied by the manifest. Engines that aren't installed are skipped.
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

    static func run(dir: URL, only: Set<String>? = nil) async {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            print("error: could not read \(manifestURL.path)")
            return
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
    }

    // The local (no-LLM) dictation pipeline DictationController builds for a plain live-edits mode:
    // live edits + replacements (before verbatim/clipboard tokenize), then restore. Mirrors
    // dictationPipeline + produceDictationText, including the whole-utterance replacement bypass:
    // when one rule owns the entire utterance the generated value is inserted verbatim, skipping the
    // reverse pass — the same short-circuit production takes on `PipelineContext.bareReplacement`.
    static func process(transcript: String, clipboard: String, rules: [ReplacementRule]) -> String {
        var stages: [any PipelineStage] = [LiveEditsStage(), ReplacementsStage(rules: rules)]
        stages.append(TokenizingStage.verbatim())
        // The clipboard stage sorts after verbatim and gates its own read on the post-verbatim text, so
        // a phrase inside a verbatim span stays literal — exactly as dictationPipeline decides.
        stages.append(TokenizingStage.clipboard(read: { clipboard }))
        let pipeline = Pipeline(stages)
        let payload = pipeline.forward(transcript)
        if let bare = payload.bareReplacement { return bare }
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
