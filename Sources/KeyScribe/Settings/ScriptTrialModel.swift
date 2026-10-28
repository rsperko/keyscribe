import Foundation
import KeyScribeKit

// Runs a draft script once through the same resolver and runner a spoken run uses, so it fails exactly where
// speaking would. Every result belongs to the snapshot that produced it, so an edit clears it even mid-run.
// A new run waits for the last one to end, even one whose result was cleared, so a press never runs two at once.
@MainActor
final class ScriptTrialModel: ObservableObject {
    struct Result: Equatable {
        let script: VoiceCommandScript
        let sample: String
        var outcome: VoiceCommandOutcome
        var finishedLate = false
        var output: ScriptOutput

        var statusText: String {
            if let status = output.status { return String(status) }
            if case .started = outcome { return HUDState.commandStillRunningDetail }
            return "Not started"
        }
    }

    private struct Snapshot: Equatable {
        let script: VoiceCommandScript
        let sample: String
    }

    private final class Arrival {
        var shown = false
        var early: VoiceCommandOutcome?
    }

    @Published private(set) var result: Result?
    @Published private(set) var isRunning = false

    private let system: VoiceCommandSystem
    private var generation = 0
    private var active: Snapshot?

    init(system: VoiceCommandSystem = LiveVoiceCommandSystem.shared) {
        self.system = system
    }

    var choices: [VoiceCommandChoiceRow] {
        guard case .needsChoice(let pending) = result?.outcome else { return [] }
        return pending.rows
    }

    static func sample(_ script: VoiceCommandScript, _ sample: String) -> String {
        script.takesText ? sample.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    static func missingSample(_ script: VoiceCommandScript, sample: String) -> String? {
        script.takesText && Self.sample(script, sample).isEmpty ? VoiceCommandRunner.needsTextMessage(script: script.name) : nil
    }

    func run(_ script: VoiceCommandScript, sample: String) async {
        let text = Self.sample(script, sample)
        let resolution = VoiceCommandResolver.resolve(
            .script(script), text: text, reach: .opening, catalog: VoiceCommandCatalog(places: [], scripts: [script]))
        await perform(script: script, sample: text) { runner, late in
            await runner.run(resolution, origin: nil, onLateResult: late)
        }
    }

    func choose(_ identity: String) async {
        guard let current = result, case .needsChoice(let pending) = current.outcome else { return }
        await perform(script: current.script, sample: current.sample) { runner, late in
            let selection = await runner.runChoice(
                pending, candidate: identity, places: [], scripts: [current.script], onLateResult: late)
            return selection?.outcome ?? .abandoned
        }
    }

    func draftChanged(to script: VoiceCommandScript, sample: String) {
        guard let active, active != Snapshot(script: script, sample: Self.sample(script, sample)) else { return }
        generation += 1
        self.active = nil
        result = nil
    }

    private func perform(
        script: VoiceCommandScript, sample: String,
        _ body: (VoiceCommandRunner, @escaping @MainActor (VoiceCommandOutcome) -> Void) async -> VoiceCommandOutcome
    ) async {
        guard !isRunning else { return }
        generation += 1
        let mine = generation
        active = Snapshot(script: script, sample: sample)
        isRunning = true
        let capture = ScriptOutputCapture()
        let runner = VoiceCommandRunner(system: system, scriptCapture: capture)
        let arrival = Arrival()
        let outcome = await body(runner) { [weak self] late in
            guard let self else { return }
            self.isRunning = false
            guard self.generation == mine else { return }
            guard arrival.shown, var current = self.result else { arrival.early = late; return }
            current.outcome = late
            current.finishedLate = true
            current.output = capture.snapshot
            self.result = current
        }
        if case .started = outcome {} else { isRunning = false }
        guard generation == mine else { return }
        var shown = Result(script: script, sample: sample, outcome: outcome, output: capture.snapshot)
        if let early = arrival.early {
            shown.outcome = early
            shown.finishedLate = true
        }
        arrival.shown = true
        result = shown
    }
}
