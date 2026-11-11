import Foundation
import Testing
@testable import KeyScribeApp

@MainActor
struct VoiceResidencyTests {
    @MainActor final class Steps {
        var log: [String] = []
        var held: CheckedContinuation<Void, Never>?
        func hold(_ name: String) async {
            log.append("\(name) started")
            await withCheckedContinuation { held = $0 }
            log.append("\(name) ended")
        }
        func open() {
            held?.resume()
            held = nil
        }
    }

    private func settled() async {
        for _ in 0..<200 { await Task.yield() }
    }

    @Test func aReleaseAskedForWhileALoadRunsWaitsForItAndSoWins() async {
        let steps = Steps()
        let voice = VoiceResidency(load: { await steps.hold("load") }, unload: { await MainActor.run { steps.log.append("release") } })
        voice.warm()
        voice.release()
        await settled()
        #expect(steps.log == ["load started"])
        steps.open()
        await settled()
        #expect(steps.log == ["load started", "load ended", "release"])
    }

    @Test func aLoadAskedForWhileAReleaseRunsWaitsForItAndSoWins() async {
        let steps = Steps()
        let voice = VoiceResidency(load: { await MainActor.run { steps.log.append("load") } }, unload: { await steps.hold("release") })
        voice.release()
        voice.warm()
        await settled()
        #expect(steps.log == ["release started"])
        steps.open()
        await settled()
        #expect(steps.log == ["release started", "release ended", "load"])
    }
}
