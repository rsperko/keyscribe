import Foundation
import Testing

struct SourceInvariantsTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func theAppSourcesKeepEveryInvariant() throws {
        let sources = try SourceInvariants.swiftFiles(under: Self.repoRoot, in: "Sources")
        #expect(!sources.isEmpty)
        for rule in SourceInvariants.rules {
            let found = rule.violations(in: sources)
            #expect(found.isEmpty, "\(rule.reason)\n\(found.joined(separator: "\n"))")
        }
    }

    @Test func aMatchInAFileOffTheAllowlistIsAViolation() {
        let rule = SourceRule(pattern: #"\bforbidden\("#, allowed: ["Sources/A.swift": 1], reason: "r")
        let found = rule.violations(in: ["Sources/A.swift": "forbidden()", "Sources/B.swift": "x = forbidden()"])
        #expect(found == ["Sources/B.swift:1: x = forbidden()"])
    }

    @Test func anAllowlistedFileMayNotExceedItsCount() {
        let rule = SourceRule(pattern: #"\bforbidden\("#, allowed: ["Sources/A.swift": 1], reason: "r")
        let found = rule.violations(in: ["Sources/A.swift": "forbidden()\nlet y = 1\nforbidden()"])
        #expect(found == ["Sources/A.swift:1: forbidden()", "Sources/A.swift:3: forbidden()"])
    }

    @Test func commentLinesNeverCount() {
        let rule = SourceRule(pattern: #"\bforbidden\("#, allowed: [:], reason: "r")
        let found = rule.violations(in: ["Sources/A.swift": "    // never call forbidden() here\n/// forbidden() too"])
        #expect(found.isEmpty)
    }
}
