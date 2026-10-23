import Foundation
import KeyScribeKit

enum AliasDiscoveryRunner {
    struct TranscriptLine: Decodable {
        let heard: String
        let reference: String
        let terms: [String]?
        let biasTerms: [String]?
        let cohort: String?
        enum CodingKeys: String, CodingKey {
            case heard, reference, terms, cohort
            case biasTerms = "bias_terms"
        }
    }

    static func run(path: URL, only: Set<String>?, cohorts: Set<String>?, threshold: Double) async -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
            print("error: \(path.path) does not exist")
            return false
        }
        if isDirectory.boolValue {
            return await runManifest(dir: path, only: only, threshold: threshold)
        }
        return runTranscripts(file: path, cohorts: cohorts, threshold: threshold)
    }

    private static func runTranscripts(file: URL, cohorts: Set<String>?, threshold: Double) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            print("error: could not read \(file.path)")
            return false
        }
        let decoder = JSONDecoder()
        var records: [AliasDiscoveryEvaluation.Record] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let row = try? decoder.decode(TranscriptLine.self, from: Data(line.utf8)) else {
                print("error: unreadable line in \(file.lastPathComponent)")
                return false
            }
            if let cohorts, !cohorts.contains(row.cohort ?? "") { continue }
            records.append(.init(heard: row.heard, reference: row.reference, dictionary: row.terms ?? row.biasTerms ?? []))
        }
        guard !records.isEmpty else {
            print("error: no records to evaluate in \(file.lastPathComponent)")
            return false
        }
        report(records: records, label: file.lastPathComponent, threshold: threshold)
        return true
    }

    struct EngineRun: Equatable {
        var loaded: Bool
        var records = 0
        var transcriptionFailures = 0
    }

    static func passed(_ runs: [EngineRun]) -> Bool {
        !runs.isEmpty && runs.allSatisfy { $0.loaded && $0.records > 0 && $0.transcriptionFailures == 0 }
    }

    private static func runManifest(dir: URL, only: Set<String>?, threshold: Double) async -> Bool {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let manifest = try? BenchmarkManifest.load(from: manifestURL) else {
            print("error: could not read \(manifestURL.path)")
            return false
        }
        let engines = InstalledEngineFilter.filter(EngineRegistry.makeAll(modelsDir: KeyScribePaths.modelsDir))
            .filter { only == nil || only!.contains($0.id) }
        if engines.isEmpty { print("error: no installed engine matches") }
        var runs: [EngineRun] = []
        for engine in engines {
            do {
                try await engine.loadIfNeeded()
            } catch {
                print("· \(engine.id): not installed / load failed")
                runs.append(EngineRun(loaded: false))
                continue
            }
            var records: [AliasDiscoveryEvaluation.Record] = []
            var missing: [String] = [], failed: [String] = []
            for entry in manifest.entries {
                let wav = dir.appendingPathComponent(entry.file)
                guard FileManager.default.fileExists(atPath: wav.path) else { missing.append(entry.id); continue }
                guard let heard = try? await engine.transcribe(wavURL: wav, biasTerms: entry.biasTerms) else {
                    failed.append(entry.id)
                    continue
                }
                records.append(.init(heard: heard, reference: entry.text, dictionary: entry.biasTerms))
            }
            await engine.evict()
            report(records: records, label: engine.id, threshold: threshold)
            print("  coverage               \(records.count)/\(manifest.entries.count) clips")
            if !missing.isEmpty { print("  missing recordings     \(missing.joined(separator: ", "))") }
            if !failed.isEmpty { print("  transcription failed   \(failed.joined(separator: ", "))") }
            runs.append(EngineRun(loaded: true, records: records.count, transcriptionFailures: failed.count))
        }
        return passed(runs)
    }

    private static func report(records: [AliasDiscoveryEvaluation.Record], label: String, threshold: Double) {
        var terms: [String] = []
        var seen = Set<String>()
        for term in records.flatMap(\.dictionary) where seen.insert(term.lowercased()).inserted { terms.append(term) }
        let s = AliasDiscoveryEvaluation.evaluate(records: records, terms: terms, threshold: threshold)
        func ratio(_ a: Int, _ b: Int) -> String {
            "\(a)/\(b) (\(b == 0 ? "—" : String(format: "%.0f%%", 100 * Double(a) / Double(b))))"
        }
        let per100 = s.negativeRecords == 0 ? 0 : 100 * Double(s.wrongSuggestions) / Double(s.negativeRecords)
        print("""

        alias discovery · \(label) · \(records.count) records · \(terms.count) terms · threshold \(String(format: "%.2f", threshold))
          occurrences found      \(ratio(s.occurrencesFound, s.occurrences))
          forms found            \(ratio(s.formsFound, s.forms))
          not auto-corrected     \(ratio(s.notAutoCorrectedFound, s.notAutoCorrected)) found
          wrong suggestions      \(s.wrongSuggestions) over \(s.negativeRecords) term×record negatives (\(String(format: "%.2f", per100)) per 100)
          wrong phrase groups    \(s.wrongGroups)
          top-three precision    \(ratio(s.topThreeHits, s.topThreeSlots))
        """)
        for term in s.terms where term.forms > 0 || !term.wrongGroups.isEmpty {
            var line = "  \(term.term): forms \(term.formsFound)/\(term.forms)"
            if !term.foundForms.isEmpty { line += " found \(term.foundForms)" }
            if !term.missedForms.isEmpty { line += " missed \(term.missedForms)" }
            if !term.wrongGroups.isEmpty { line += " wrong \(Array(term.wrongGroups.prefix(6)))" }
            print(line)
        }
    }
}
