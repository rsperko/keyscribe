import Foundation
import Testing

@testable import KeyScribeKit

private let sentinels = [
    "SENTINELHEARD", "SENTINELTRANSFORMED", "SENTINELRESULT",
    "SENTINELPROMPT", "SENTINELRECEIVED", "SENTINELROUTED",
]

private func contentBearingEntry(outcome: HistoryEntry.Outcome = .inserted) -> HistoryEntry {
    HistoryEntry(
        timestamp: Date(timeIntervalSince1970: 1_760_000_000),
        modeName: "Direct",
        engine: "Parakeet TDT v3",
        device: "MacBook Pro Microphone",
        heard: "SENTINELHEARD",
        transformed: "SENTINELTRANSFORMED",
        result: "SENTINELRESULT",
        outcome: outcome,
        cloudInvolved: true,
        redaction: true,
        contextCategories: ["selection"],
        connection: "fast",
        model: "gemini-3.1-flash-lite",
        prompt: "SENTINELPROMPT",
        received: "SENTINELRECEIVED",
        modeChoice: .spokenPhrase,
        routedPhrase: "SENTINELROUTED",
        triggerKey: "Right-⌥",
        fallbackReason: "The AI service could not be reached.")
}

private func report(
    dictations: [DiagnosticsReport.DictationLine] = [],
    modes: [DiagnosticsReport.ModeLine] = [],
    modelLoadFailures: [String] = [],
    configErrors: [String] = []
) -> DiagnosticsReport {
    DiagnosticsReport(
        build: .init(
            appName: "KeyScribe", version: "0.5.1", build: "412",
            revision: "68b8f19", bundleId: "com.keyscribe.app",
            variant: "production", osVersion: "26.5.0"),
        permissions: .init(microphone: "granted", accessibility: "granted"),
        speech: .init(selectedEngine: "parakeet-tdt-v3", installed: ["parakeet-tdt-v3"]),
        historyEnabled: true,
        historyRetentionDays: 30,
        supportDir: "~/Library/Application Support/KeyScribe",
        modes: modes,
        dictations: dictations,
        modelLoadFailures: modelLoadFailures,
        configErrors: configErrors,
        enabledFeatures: [])
}

@Suite struct DiagnosticsReportTests {
    @Test func dictationLineCarriesNoTranscriptContent() {
        let line = DiagnosticsReport.DictationLine(contentBearingEntry())
        let mirrored = String(describing: Mirror(reflecting: line).children.map { "\($0.value)" })
        for sentinel in sentinels {
            #expect(!mirrored.contains(sentinel), "\(sentinel) leaked into DictationLine")
        }
    }

    @Test func renderedReportNeverContainsTranscriptContent() {
        let rendered = report(dictations: [.init(contentBearingEntry())]).render()
        for sentinel in sentinels {
            #expect(!rendered.contains(sentinel), "\(sentinel) leaked into the rendered report")
        }
    }

    @Test func dictationLineKeepsTheDiagnosticFields() {
        let line = DiagnosticsReport.DictationLine(contentBearingEntry(outcome: .localFallback))
        #expect(line.mode == "Direct")
        #expect(line.engine == "Parakeet TDT v3")
        #expect(line.device == "MacBook Pro Microphone")
        #expect(line.outcome == "local_fallback")
        #expect(line.cloudInvolved)
        #expect(line.redaction)
        #expect(line.connection == "fast")
        #expect(line.model == "gemini-3.1-flash-lite")
        #expect(line.fallbackReason == "The AI service could not be reached.")
    }

    @Test func renderIncludesBuildPermissionsAndEngine() {
        let rendered = report().render()
        #expect(rendered.contains("0.5.1"))
        #expect(rendered.contains("68b8f19"))
        #expect(rendered.contains("com.keyscribe.app"))
        #expect(rendered.contains("parakeet-tdt-v3"))
        #expect(rendered.contains("microphone: granted"))
        #expect(rendered.contains("accessibility: granted"))
    }

    @Test func renderShowsModeDeliverySettings() {
        let mode = DiagnosticsReport.ModeLine(
            name: "Edit Selection", id: "edit-selection", source: "selection",
            output: "replace_selection", insertion: "paste", usesLLM: true,
            privacy: false, excludeFromHistory: false, triggers: ["Right-⌘"])
        let rendered = report(modes: [mode]).render()
        #expect(rendered.contains("Edit Selection"))
        #expect(rendered.contains("insertion=paste"))
        #expect(rendered.contains("output=replace_selection"))
        #expect(rendered.contains("source=selection"))
    }

    @Test func renderFlagsAModeExcludedFromHistory() {
        let mode = DiagnosticsReport.ModeLine(
            name: "Secrets", id: "secrets", source: "dictation",
            output: "cursor", insertion: "paste", usesLLM: false,
            privacy: true, excludeFromHistory: true, triggers: [])
        let rendered = report(modes: [mode]).render()
        #expect(rendered.contains("no-history"))
        #expect(rendered.contains("privacy"))
    }

    @Test func renderNotesWhyACopiedOutcomeHasNoReason() {
        let rendered = report(dictations: [.init(contentBearingEntry(outcome: .copied))]).render()
        #expect(rendered.contains("copied"))
        #expect(rendered.lowercased().contains("not recorded"))
    }

    @Test func renderReportsAnEmptyHistoryExplicitly() {
        let rendered = report().render()
        #expect(rendered.lowercased().contains("no dictations recorded"))
    }

    @Test func renderSurfacesModelLoadAndConfigFailures() {
        let rendered = report(
            modelLoadFailures: ["2026-08-13T10:00:00Z\tqwen3-asr-0.6b\terror\tcompile failed"],
            configErrors: ["modes/direct.toml: unexpected key"]
        ).render()
        #expect(rendered.contains("qwen3-asr-0.6b"))
        #expect(rendered.contains("modes/direct.toml"))
    }

    @Test func renderOmitsFailureSectionsWhenClean() {
        let rendered = report().render()
        #expect(!rendered.contains("Model load failures"))
        #expect(!rendered.contains("Config errors"))
    }

    @Test func historyDisabledIsCalledOutSoAnEmptyListIsNotMisread() {
        var r = report()
        r.historyEnabled = false
        #expect(r.render().lowercased().contains("history is off"))
    }
}
