import Testing
@testable import KeyScribeKit

struct CommandCheckReportTests {
    // Different engines legitimately clean different clips (the clips are transcription-sensitive), so
    // the gate is a regression check against a known-good per-engine baseline — not an absolute floor.

    @Test func passesWhenEveryEngineHoldsItsBaseline() {
        let report = CommandCheckReport(engines: [
            .init(id: "parakeet", clean: 28, total: 35, loaded: true),
            .init(id: "whisper", clean: 24, total: 35, loaded: true),
        ])
        let baseline = CommandCheckBaseline(engines: [
            "parakeet": .init(clean: 28, total: 35),
            "whisper": .init(clean: 24, total: 35),
        ])
        #expect(report.diff(against: baseline).passed)
    }

    @Test func improvingIsNotARegression() {
        let report = CommandCheckReport(engines: [.init(id: "parakeet", clean: 30, total: 35, loaded: true)])
        let baseline = CommandCheckBaseline(engines: ["parakeet": .init(clean: 28, total: 35)])
        #expect(report.diff(against: baseline).passed)
    }

    @Test func aDropBelowBaselineFailsAndIsReported() {
        let report = CommandCheckReport(engines: [.init(id: "parakeet", clean: 22, total: 35, loaded: true)])
        let baseline = CommandCheckBaseline(engines: ["parakeet": .init(clean: 28, total: 35)])
        let diff = report.diff(against: baseline)
        #expect(!diff.passed)
        #expect(diff.regressions.map(\.id) == ["parakeet"])
        #expect(diff.regressions.first?.baseline == 28)
        #expect(diff.regressions.first?.current == 22)
    }

    @Test func aNewlyInstalledEngineIsNotARegression() {
        let report = CommandCheckReport(engines: [
            .init(id: "parakeet", clean: 28, total: 35, loaded: true),
            .init(id: "brand-new", clean: 10, total: 35, loaded: true),
        ])
        let baseline = CommandCheckBaseline(engines: ["parakeet": .init(clean: 28, total: 35)])
        #expect(report.diff(against: baseline).passed)
    }

    @Test func aChangedClipCountMarksTheBaselineStale() {
        let report = CommandCheckReport(engines: [.init(id: "parakeet", clean: 30, total: 37, loaded: true)])
        let baseline = CommandCheckBaseline(engines: ["parakeet": .init(clean: 28, total: 35)])
        let diff = report.diff(against: baseline)
        #expect(!diff.passed)
        #expect(diff.stale == ["parakeet"])
    }

    @Test func nothingRanFailsInsteadOfSilentlyPassing() {
        let report = CommandCheckReport(engines: [.init(id: "parakeet", clean: 0, total: 0, loaded: false)])
        let baseline = CommandCheckBaseline(engines: ["parakeet": .init(clean: 28, total: 35)])
        #expect(!report.diff(against: baseline).passed)
    }

    @Test func baselineRoundTripsFromAReport() {
        let report = CommandCheckReport(engines: [
            .init(id: "parakeet", clean: 28, total: 35, loaded: true),
            .init(id: "notinstalled", clean: 0, total: 0, loaded: false),
        ])
        let baseline = CommandCheckBaseline.from(report)
        #expect(baseline.engines == ["parakeet": .init(clean: 28, total: 35)])
    }
}
