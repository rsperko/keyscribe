import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

struct ModelLoadDiagnosticsWriterTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ks-diag-\(UUID().uuidString).log")
    }

    @Test func recordAppendsOneLinePerFailure() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        ModelLoadDiagnosticsWriter.record(engineId: "parakeet", timedOut: false, error: "boom one", to: file)
        ModelLoadDiagnosticsWriter.record(engineId: "whisper", timedOut: true, error: "boom two", to: file)

        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].contains("parakeet") && lines[0].contains("error") && lines[0].contains("boom one"))
        #expect(lines[1].contains("whisper") && lines[1].contains("timeout"))
    }

    @Test func recordCapsToMaxEntriesKeepingNewest() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let total = ModelLoadDiagnostics.maxEntries + 10
        for i in 0..<total {
            ModelLoadDiagnosticsWriter.record(engineId: "e\(i)", timedOut: false, error: "x", to: file)
        }

        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(lines.count == ModelLoadDiagnostics.maxEntries)
        #expect(lines.first?.contains("\te10\t") == true)
        #expect(lines.last?.contains("\te\(total - 1)\t") == true)
    }
}
