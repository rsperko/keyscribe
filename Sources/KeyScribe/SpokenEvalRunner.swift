import Foundation
import KeyScribeKit

enum SpokenEvalRunner {
    static func run(dir: URL, connectionId: String?, repeats: Int, promptFile: URL?) async -> Bool {
        let file = dir.appendingPathComponent("cases.json")
        let cases: [SpokenEvalCase]
        let prompt: String
        do {
            cases = try SpokenEval.cases(from: Data(contentsOf: file))
            prompt = try promptFile.map { try String(contentsOf: $0, encoding: .utf8) } ?? SpokenResultSettings.defaultPrompt
        } catch {
            print("error: \(error)")
            return false
        }
        guard let connection = RewriteEvalRunner.resolveConnection(id: connectionId) else { return false }
        print("Spoken eval: \(cases.count) cases × \(repeats) — \(connection.id) (\(connection.model))\n")
        let client = HTTPLLMClient()
        var failedCases: [String] = []
        for evalCase in cases {
            var failed = false
            for _ in 0..<repeats {
                let request = SpokenResult.request(answer: evalCase.reply, asked: evalCase.asked, prompt: prompt, tokenizer: Tokenizer())
                do {
                    let returned = try await client.complete(system: request.system, user: request.user, connection: connection)
                    let spoken = SpokenResult.held(SpokenResult.spoken(summary: returned)).text
                    let failures = SpokenEval.failures(of: spoken, for: evalCase)
                    failed = failed || !failures.isEmpty
                    print("\(evalCase.id)\t\(failures.isEmpty ? "pass" : failures.joined(separator: "+"))\t\(spoken)")
                } catch {
                    failed = true
                    print("\(evalCase.id)\terror\t\(error)")
                }
            }
            if failed { failedCases.append(evalCase.id) }
        }
        print("\n\(cases.count - failedCases.count)/\(cases.count) cases passed every attempt"
            + (failedCases.isEmpty ? "" : "; short: \(failedCases.joined(separator: ", "))"))
        return failedCases.isEmpty
    }
}
