import AVFoundation
import Foundation
import KeyScribeKit

// Dev tool: `KeyScribe --clipboard-check <dir>`. Drives every installed SpeechEngine over recorded
// "insert clipboard contents" utterances, runs the REAL local dictation pipeline (verbatim + clipboard
// tokenize + bracketed-terminator fold + restore) with a fixed clipboard value, and reports whether the
// command fired, was consumed, and left no punctuation artifact before the pasted value — so the
// clipboard behavior is verified on the exact transcripts real engines produce, not synthetic ones.
// Headless: reads wavs, never touches mic/insertion/TCC/clipboard. Engines that aren't installed are skipped.
enum ClipboardCheckRunner {
    struct Manifest: Decodable {
        let clipboard: String
        let cases: [Case]
        struct Case: Decodable { let id: String; let say: String }
    }

    static func run(dir: URL, only: Set<String>? = nil) async {
        let manifestURL = dir.appendingPathComponent("clipboard.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            print("error: could not read \(manifestURL.path)")
            return
        }
        let engines = EngineRegistry.makeAll(modelsDir: KeyScribePaths.modelsDir)
            .filter { only == nil || only!.contains($0.id) }
        let clip = manifest.clipboard
        print("Clipboard check: \(manifest.cases.count) clips × \(engines.count) engines · clipboard = \"\(clip)\"\n")

        var summary: [(id: String, clean: Int, total: Int, status: String)] = []
        for engine in engines {
            do { try await engine.loadIfNeeded() } catch {
                summary.append((engine.id, 0, 0, "not installed / load failed"))
                print("· \(engine.id): not installed / load failed\n")
                continue
            }
            print("── \(engine.id) " + String(repeating: "─", count: max(0, 40 - engine.id.count)))
            var clean = 0, total = 0
            for c in manifest.cases {
                let wav = dir.appendingPathComponent("\(c.id).wav")
                guard FileManager.default.fileExists(atPath: wav.path) else {
                    print("  \(c.id): missing \(wav.lastPathComponent)"); continue
                }
                guard let transcript = try? await engine.transcribe(wavURL: wav, biasTerms: []) else {
                    print("  \(c.id): <transcribe error>"); continue
                }
                total += 1
                let output = process(transcript: transcript, clipboard: clip)
                let inserted = output.contains(clip)
                let consumed = output.range(of: "clipboard", options: .caseInsensitive) == nil
                let artifact = inserted && leadingPunct(before: clip, in: output)
                let ok = inserted && consumed && !artifact
                if ok { clean += 1 }
                let flags = [inserted ? nil : "NOT-INSERTED", consumed ? nil : "NOT-CONSUMED",
                             artifact ? "LEADING-PUNCT" : nil].compactMap { $0 }
                print("  \(ok ? "✓" : "✗") \(c.id)\(flags.isEmpty ? "" : "  [\(flags.joined(separator: ", "))]")")
                print("      heard : \(oneLine(transcript))")
                print("      out   : \(oneLine(output))")
            }
            await engine.evict()
            summary.append((engine.id, clean, total, "ok"))
            print("")
        }
        printSummary(summary)
    }

    // The local (no-LLM) dictation pipeline the DictationController builds for a plain live-edits mode:
    // verbatim + clipboard tokenize (before the text stages), live edits, then restore.
    static func process(transcript: String, clipboard: String) -> String {
        var stages: [any PipelineStage] = [LiveEditsStage(), ReplacementsStage(rules: [])]
        stages.append(TokenizingStage.verbatim())
        stages.append(TokenizingStage.clipboard(clipboard))
        let pipeline = Pipeline(stages)
        var ctx = PipelineContext(text: transcript)
        pipeline.forward(&ctx)
        pipeline.reverse(&ctx)
        return ctx.text
    }

    // True if the char immediately before the pasted value (skipping one run of spaces) is sentence or
    // clause punctuation — the spurious-terminator-before-paste artifact the fold is meant to remove.
    private static func leadingPunct(before value: String, in text: String) -> Bool {
        guard let r = text.range(of: value) else { return false }
        var i = r.lowerBound
        while i > text.startIndex {
            let prev = text.index(before: i)
            if text[prev] == " " { i = prev } else { return ".,;:!?".contains(text[prev]) }
        }
        return false
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
        print("\n✓ = command fired, consumed, and no punctuation artifact before the pasted value.")
    }
}
