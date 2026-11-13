import Foundation
import Testing

struct SourceInvariantsTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func theConnectorsNameNoTerminalOrMultiplexer() throws {
        let connectors = ["Sources/KeyScribe/Resources/ClaudeConnector/register.js", "Sources/KeyScribe/Resources/PiConnector/index.ts"]
        var sources: [String: String] = [:]
        for path in connectors { sources[path] = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8) }
        let rule = SourceRule(
            pattern: #"(?i)herdr|tmux|zellij|ghostty|iterm|cmux|warp"#, allowed: [:],
            reason: "A connector reads the keys and runs the focus commands its configuration lists, generated from the "
                + "routes; a surface's name in a connector is a fallback no route controls (docs/development/areas/voice-commands.md).")
        #expect(sources.count == connectors.count)
        #expect(rule.violations(in: sources).isEmpty, "\(rule.reason)\n\(rule.violations(in: sources).joined(separator: "\n"))")
    }

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

    @Test func onlyAFileInsideOneIntegrationsToolFolderMayNameItsOwnToolAndNoOther() {
        #expect(SourceInvariants.integrationTool("Sources/KeyScribeKit/Integrations/Example/ExampleRoute.swift") == "Example")
        #expect(SourceInvariants.integrationTool("Sources/KeyScribe/Integrations/Example/Reader.swift") == "Example")
        #expect(SourceInvariants.integrationTool("Sources/KeyScribeKit/Integrations/Shared.swift") == nil)
        #expect(SourceInvariants.integrationTool("Sources/KeyScribeKit/TerminalRoutes/ExampleRoute.swift") == nil)
        let rule = SourceRule(pattern: #"(?i)herdr|tmux"#, allowed: [:], reason: "r", own: SourceInvariants.integrationTool)
        let found = rule.violations(in: [
            "Sources/KeyScribeKit/Integrations/Herdr/HerdrRoute.swift": "let name = \"herdr\"\nstruct HerdrRoute {}",
            "Sources/KeyScribeKit/Integrations/Herdr/HerdrPlaces.swift": "let inner = \"tmux\"",
            "Sources/KeyScribe/Adapters/HerdrPlaceReader.swift": "let name = \"herdr\"",
        ])
        #expect(found == [
            "Sources/KeyScribe/Adapters/HerdrPlaceReader.swift:1: let name = \"herdr\"",
            "Sources/KeyScribeKit/Integrations/Herdr/HerdrPlaces.swift:1: let inner = \"tmux\"",
        ])
    }

    @Test func commentLinesNeverCount() {
        let rule = SourceRule(pattern: #"\bforbidden\("#, allowed: [:], reason: "r")
        let found = rule.violations(in: ["Sources/A.swift": "    // never call forbidden() here\n/// forbidden() too"])
        #expect(found.isEmpty)
    }
}
