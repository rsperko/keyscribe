import Foundation
import KeyScribeKit

// Runs the text-only rewrite-prompt eval corpus (cases.json) through each prompt variant against a
// saved BYOK connection, scores every output with the deterministic checks, and prints a paired
// baseline-vs-variant report split by scenario tag — so a candidate prompt ships on data, not faith.
// Headless: network only, no mic/insertion.
enum RewriteEvalRunner {
    struct AttemptRecord {
        let caseId: String
        let variant: String
        let passed: Bool
        let failedKinds: [String]
        let output: String
        let error: String?
    }

    static func run(
        dir: URL, variantIds: [String], connectionId: String?, repeats: Int, raw: Bool
    ) async -> Bool {
        let manifestURL = dir.appendingPathComponent("cases.json")
        let manifest: RewriteEvalManifest
        do {
            manifest = try RewriteEvalManifest.load(from: manifestURL)
        } catch {
            print("error: could not read \(manifestURL.path): \(error)")
            return false
        }
        guard !manifest.cases.isEmpty else {
            print("error: \(manifestURL.path) has no cases")
            return false
        }

        let known = RewriteEvalVariants.all.map(\.id)
        let unknown = variantIds.filter { !known.contains($0) }
        guard unknown.isEmpty else {
            print("error: unknown variant(s) \(unknown.joined(separator: ", ")) — known: \(known.joined(separator: ", "))")
            return false
        }

        guard let connection = resolveConnection(id: connectionId) else { return false }
        print("Rewrite eval: \(manifest.cases.count) cases × \(variantIds.count) variants × \(repeats) repeat(s) — connection \(connection.id) (\(connection.model))\n")

        let client = HTTPLLMClient()
        var records: [AttemptRecord] = []
        for variant in variantIds {
            var conn = connection
            if let t = RewriteEvalVariants.temperatureOverride(variant: variant) {
                conn.params.temperature = t
            }
            for c in manifest.cases {
                guard let built = RewriteEvalVariants.build(c, variant: variant) else { continue }
                let prompt = PromptAssembler.assemble(built.inputs, options: built.options)
                for _ in 0..<repeats {
                    do {
                        let output = try await client.complete(
                            system: prompt.system, user: prompt.user, connection: conn)
                        let results = RewriteEvalScoring.score(output: output, for: c)
                        let failed = results.filter { !$0.passed }
                        records.append(AttemptRecord(
                            caseId: c.id, variant: variant, passed: failed.isEmpty,
                            failedKinds: failed.map(\.kind.rawValue), output: output, error: nil))
                        if raw {
                            let line = output
                                .replacingOccurrences(of: "\n", with: " ")
                                .replacingOccurrences(of: "\t", with: " ")
                            print("RAW\t\(variant)\t\(c.id)\t\(failed.isEmpty ? "pass" : failed.map(\.kind.rawValue).joined(separator: "+"))\t\(line)")
                        }
                    } catch {
                        records.append(AttemptRecord(
                            caseId: c.id, variant: variant, passed: false,
                            failedKinds: [], output: "", error: String(describing: error)))
                        print("  [\(variant) \(c.id)] transport error: \(error)")
                    }
                }
            }
            let done = records.filter { $0.variant == variant }
            let passed = done.filter(\.passed).count
            print("· \(variant): \(passed)/\(done.count) attempts passed")
        }

        printReport(records: records, manifest: manifest, variantIds: variantIds)
        writeResults(records: records, dir: dir, connection: connection, repeats: repeats)
        return !records.contains { $0.error != nil }
    }

    private static func resolveConnection(id: String?) -> Connection? {
        let set = ConnectionStore.loadOrDefault(supportDir: KeyScribePaths.supportDir)
        guard !set.connections.isEmpty else {
            print("error: no saved connections (\(ConnectionStore.fileName)); add one in Settings → AI Service")
            return nil
        }
        if let id {
            guard let c = set.connection(id: id) else {
                print("error: no connection '\(id)' — saved: \(set.connections.map(\.id).joined(separator: ", "))")
                return nil
            }
            return c
        }
        guard set.connections.count == 1 else {
            print("error: multiple connections saved (\(set.connections.map(\.id).joined(separator: ", "))) — pick one with --connection <id>")
            return nil
        }
        return set.connections[0]
    }

    private static func printReport(
        records: [AttemptRecord], manifest: RewriteEvalManifest, variantIds: [String]
    ) {
        func casePassed(_ caseId: String, _ variant: String) -> Bool {
            let attempts = records.filter { $0.caseId == caseId && $0.variant == variant }
            return !attempts.isEmpty && attempts.allSatisfy(\.passed)
        }

        let width = max(12, (variantIds.map(\.count).max() ?? 12) + 2)
        func pad(_ s: String, _ w: Int) -> String {
            s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
        }

        print("\ncheck failures by variant (attempt-level):")
        let kinds = RewriteEvalCheckResult.Kind.allCases.map(\.rawValue)
        print(pad("variant", width) + kinds.map { pad($0, 15) }.joined() + "errors")
        for v in variantIds {
            let mine = records.filter { $0.variant == v }
            let cells = kinds.map { kind in
                pad("\(mine.filter { $0.failedKinds.contains(kind) }.count)", 15)
            }
            print(pad(v, width) + cells.joined() + "\(mine.filter { $0.error != nil }.count)")
        }

        var tags = Array(Set(manifest.cases.flatMap(\.tags))).sorted()
        if manifest.cases.contains(where: { $0.tags.isEmpty }) { tags.append("(untagged)") }
        let tagWidth = max(14, (tags.map(\.count).max() ?? 14) + 2)
        print("\ncases passed by tag × variant:")
        print(pad("tag", tagWidth) + variantIds.map { pad($0, width) }.joined())
        for tag in tags {
            let cases = manifest.cases.filter {
                tag == "(untagged)" ? $0.tags.isEmpty : $0.tags.contains(tag)
            }
            let cells = variantIds.map { v in
                pad("\(cases.filter { casePassed($0.id, v) }.count)/\(cases.count)", width)
            }
            print(pad(tag, tagWidth) + cells.joined())
        }

        if variantIds.contains("baseline") {
            print("\nvs baseline (cases the variant fixes / breaks):")
            for v in variantIds where v != "baseline" {
                var wins: [String] = [], losses: [String] = []
                for c in manifest.cases {
                    let base = casePassed(c.id, "baseline")
                    let mine = casePassed(c.id, v)
                    if mine && !base { wins.append(c.id) }
                    if base && !mine { losses.append(c.id) }
                }
                var line = "· \(pad(v, width)) +\(wins.count) / -\(losses.count)"
                if !wins.isEmpty { line += "   fixes: \(wins.joined(separator: ", "))" }
                if !losses.isEmpty { line += "   breaks: \(losses.joined(separator: ", "))" }
                print(line)
            }
        }
    }

    private static func writeResults(
        records: [AttemptRecord], dir: URL, connection: Connection, repeats: Int
    ) {
        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: Date())
        }()
        let resultsDir = dir.appendingPathComponent("results")
        let url = resultsDir.appendingPathComponent("\(connection.id)-\(stamp).json")

        var variants: [String: [[String: Any]]] = [:]
        for r in records {
            var attempt: [String: Any] = [
                "case": r.caseId, "passed": r.passed, "failed": r.failedKinds, "output": r.output,
            ]
            if let e = r.error { attempt["error"] = e }
            variants[r.variant, default: []].append(attempt)
        }
        let obj: [String: Any] = [
            "connection": connection.id,
            "model": connection.model,
            "temperature": connection.params.temperature,
            "repeats": repeats,
            "attempts": variants,
        ]
        do {
            try FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
            print("\nwrote \(url.path)")
        } catch {
            print("\nerror: could not write \(url.path): \(error)")
        }
    }
}
