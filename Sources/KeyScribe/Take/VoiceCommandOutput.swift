import Foundation
import KeyScribeKit

@MainActor
protocol VoiceCommandHost: AnyObject {
    var isBusy: Bool { get }
    var isArming: Bool { get }
    var takeStarts: Int { get }
    var answeringChoiceId: Int? { get }
    var voiceCommandsEnabled: Bool { get }
    var voiceCommandsAvailable: Bool { get }
    var savedCommands: VoiceCommandConfig { get }
    var voiceCommandShortcut: String? { get }
    func cancelTake()
    func whenIdle(_ work: @escaping () -> Void)
    func hide(after seconds: Double)
    func alert(_ cue: DuringDictationEffects.EndCue)
}

@MainActor
final class VoiceCommandOutput {
    struct Presentation {
        let state: HUDState
        let cue: DuringDictationEffects.EndCue
        let hideAfter: Double
        let outcome: HistoryEntry.Outcome
        let result: String
        let failure: String?
        var reported: String?
    }

    final class LateResult {
        var started = false
        var entry: HistoryEntry?
        var outcome: VoiceCommandOutcome?
        var applied = false
    }

    private let runner: VoiceCommandRunning
    private let hud: HUDChannel
    private let reporter: TakeReporter
    weak var host: VoiceCommandHost?
    private(set) var prompt: VoiceCommandChoicePrompt?
    private var entry: HistoryEntry?
    private var expiryTask: Task<Void, Never>?
    private var clickedTask: Task<Void, Never>?
    private(set) var stops = 0
    var expirySleep: @MainActor (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }

    private static let unrecognizedCommandTitle = "Command not recognized"

    init(runner: VoiceCommandRunning, hud: HUDChannel, reporter: TakeReporter) {
        self.runner = runner
        self.hud = hud
        self.reporter = reporter
    }

    private var isBusy: Bool { host?.isBusy ?? false }

    var pendingPrompt: VoiceCommandChoicePrompt? {
        guard let prompt, runner.pendingChoice?.id == prompt.id else { return nil }
        return prompt
    }

    func offer(_ pending: VoiceCommandPendingChoice) -> VoiceCommandChoicePrompt {
        let prompt = prompt(for: pending)
        self.prompt = prompt
        entry = nil
        return prompt
    }

    func noteAsked(_ entry: HistoryEntry, choice id: Int) {
        guard prompt?.id == id else { return }
        self.entry = entry
    }

    func pauseExpiry() {
        expiryTask?.cancel()
    }

    func scheduleExpiry(_ id: Int) {
        expiryTask?.cancel()
        guard let seconds = runner.choiceSecondsLeft(id) else { return }
        expiryTask = Task { @MainActor [weak self, sleep = expirySleep] in
            await sleep(seconds)
            guard let self, !Task.isCancelled else { return }
            if self.runner.expireChoice(id) {
                self.clear()
                if !self.isBusy { self.hud.present(.hidden) }
            } else if self.runner.choiceSecondsLeft(id) != nil {
                self.scheduleExpiry(id)
            }
        }
    }

    func clear() {
        expiryTask?.cancel()
        expiryTask = nil
        prompt = nil
        entry = nil
    }

    func dismiss() {
        let shown = prompt != nil
        if let pending = runner.pendingChoice { runner.dismissChoice(pending.id) }
        clear()
        guard shown, !isBusy || host?.isArming == true else { return }
        hud.present(.hidden)
    }

    func stop() {
        stops += 1
        StopGate.closeAll()
        clickedTask?.cancel()
        clickedTask = nil
        dismiss()
    }

    func noteAppActivated(bundleId: String) {
        guard let pending = runner.pendingChoice, bundleId != pending.origin?.bundleId else { return }
        dismiss()
    }

    func configurationChanged() {
        guard let pending = runner.pendingChoice, let host else { return }
        let current = host.savedCommands
        guard !host.voiceCommandsAvailable || current.places != pending.places || current.scripts != pending.scripts else { return }
        dismiss()
    }

    func choose(choice id: Int, candidate identity: String) {
        guard let host, host.voiceCommandsEnabled, let pending = runner.takeChoice(id) else { return }
        let wasAnswering = host.answeringChoiceId == id
        let entry = entry
        clear()
        if wasAnswering { host.cancelTake() }
        let commands = host.savedCommands
        let late = LateResult()
        let startsAtClick = host.takeStarts
        let stopsAtClick = stops
        clickedTask?.cancel()
        clickedTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stillWanted: @MainActor () -> Bool = { [weak self] in
                guard let self, let host = self.host else { return false }
                return !Task.isCancelled && host.takeStarts == startsAtClick && self.stops == stopsAtClick
                    && host.voiceCommandsEnabled
            }
            guard let selection = await self.runner.runChoice(
                pending, candidate: identity, places: commands.places, scripts: commands.scripts,
                stillWanted: stillWanted,
                onLateResult: { [weak self] outcome in
                    late.outcome = outcome
                    self?.applyLateResult(late)
                })
            else { self.abandonClicked(entry, startsAtClick: startsAtClick); return }
            self.finishClicked(selection, entry: entry, late: late, startsAtClick: startsAtClick)
        }
    }

    func cancel(choice id: Int) {
        guard runner.takeChoice(id) != nil else { return }
        let wasAnswering = host?.answeringChoiceId == id
        let entry = entry
        clear()
        if wasAnswering { host?.cancelTake() }
        if !isBusy { hud.present(.hidden) }
        markCancelled(entry)
    }

    private func finishClicked(
        _ selection: VoiceCommandSelection, entry: HistoryEntry?, late: LateResult, startsAtClick: Int
    ) {
        if case .needsChoice(let pending) = selection.outcome {
            askAgainAfterClick(pending, selection: selection, entry: entry, startsAtClick: startsAtClick)
            return
        }
        guard let shown = Self.presentation(of: selection.outcome, resultPrefix: Self.selectionPrefix(selection)) else {
            abandonClicked(entry, startsAtClick: startsAtClick)
            return
        }
        if let entry {
            var updated = entry
            updated.outcome = shown.outcome
            updated.result = shown.result
            updated.failureReason = shown.failure
            updated.reported = shown.reported
            late.entry = updated
            reporter.replace(entry, with: updated)
        }
        let show = { [weak self] in
            guard let self, let host = self.host, host.takeStarts == startsAtClick, !host.isBusy,
                  self.runner.pendingChoice == nil else { return }
            host.alert(shown.cue)
            self.hud.present(shown.state)
            host.hide(after: shown.hideAfter)
        }
        host?.whenIdle(show)
        if shown.outcome == .commandStarted {
            late.started = true
            applyLateResult(late)
        }
    }

    private func abandonClicked(_ entry: HistoryEntry?, startsAtClick: Int) {
        markCancelled(entry)
        guard host?.takeStarts == startsAtClick, !isBusy, runner.pendingChoice == nil else { return }
        hud.present(.hidden)
    }

    private func askAgainAfterClick(
        _ pending: VoiceCommandPendingChoice, selection: VoiceCommandSelection, entry: HistoryEntry?, startsAtClick: Int
    ) {
        var asked = entry
        if let entry {
            let rows = pending.rows.map { "\($0.number). \($0.name)" }.joined(separator: ", ")
            asked?.result = Self.selectionPrefix(selection) + "Asked to choose: \(rows)"
            let updated = asked ?? entry
            reporter.replace(entry, with: updated)
        }
        host?.whenIdle { [weak self] in
            guard let self, self.runner.pendingChoice?.id == pending.id else { return }
            guard self.host?.takeStarts == startsAtClick else {
                self.runner.dismissChoice(pending.id)
                return
            }
            let prompt = self.prompt(for: pending)
            self.prompt = prompt
            self.entry = asked
            self.hud.present(.choice(prompt, status: .waiting(note: nil)))
            self.scheduleExpiry(pending.id)
        }
    }

    private func markCancelled(_ entry: HistoryEntry?) {
        guard let entry else { return }
        var updated = entry
        updated.outcome = .commandCancelled
        reporter.replace(entry, with: updated)
    }

    func applyLateResult(_ late: LateResult) {
        guard late.started, !late.applied, let outcome = late.outcome else { return }
        late.applied = true
        let failure: String?
        let report: ScriptReport.Message?
        let summary: String
        switch outcome {
        case .failed(let message, _, _, _): (failure, report, summary) = (message, nil, "")
        case .done(let name, _, let message): (failure, report, summary) = (nil, message, name)
        case .started, .needsChoice, .cancelled, .abandoned: return
        }
        if let entry = late.entry {
            var updated = entry
            updated.outcome = failure == nil ? .command : .commandFailed
            updated.failureReason = failure
            updated.reported = report?.text
            reporter.replace(entry, with: updated)
        }
        guard !isBusy, runner.pendingChoice == nil else { return }
        if let failure {
            hud.present(.error(message: failure, action: nil))
        } else if let report {
            hud.present(Self.commandDoneState(summary: summary, report: report))
        } else {
            return
        }
        host?.hide(after: 4)
    }

    private func prompt(for pending: VoiceCommandPendingChoice) -> VoiceCommandChoicePrompt {
        let use = host?.voiceCommandShortcut.map { "Use \($0)" } ?? "Use your Voice Commands shortcut"
        let hint = (pending.choice.note.map { "\($0) " } ?? "")
            + "\(use) and say \u{201C}two\u{201D} or \u{201C}the second one\u{201D}. "
            + "Say \u{201C}cancel\u{201D} to dismiss, or give a new command."
        return VoiceCommandChoicePrompt(id: pending.id, title: pending.choice.title, rows: pending.rows, hint: hint)
    }

    static func selectionPrefix(_ selection: VoiceCommandSelection) -> String {
        "Selected \(selection.name) for \u{201C}\(selection.request)\u{201D}: "
    }

    static func presentation(
        of outcome: VoiceCommandOutcome, resultPrefix: String, excerpt: HeardExcerpt? = nil
    ) -> Presentation? {
        switch outcome {
        case .done(let summary, let command, let report):
            Presentation(state: commandDoneState(summary: summary, report: report), cue: .success,
                         hideAfter: report == nil ? 1.5 : 3, outcome: .command,
                         result: resultPrefix + command, failure: nil, reported: report?.text)
        case .started(let summary, let command):
            Presentation(state: .commandDone(summary: summary, detail: HUDState.commandStillRunningDetail),
                         cue: .success, hideAfter: 1.5, outcome: .commandStarted, result: resultPrefix + command,
                         failure: nil)
        case .failed(let message, let command, let action, let kind):
            Presentation(state: .error(message: kind == .unrecognizedCommand ? unrecognizedCommandTitle : message,
                                       action: action, heard: kind == .other ? nil : excerpt),
                         cue: .error, hideAfter: 3,
                         outcome: .commandFailed, result: resultPrefix + (command ?? ""), failure: message)
        case .needsChoice, .cancelled, .abandoned:
            nil
        }
    }

    static func commandDoneState(summary: String, report: ScriptReport.Message?) -> HUDState {
        switch report?.level {
        case nil: .commandDone(summary: summary)
        case .done: .commandDone(summary: report?.text ?? summary, detail: summary)
        case .info: .advisory(message: report?.text ?? summary)
        }
    }

    // A replacement counts only when the command it shaped reached its destination, like a dictation that was
    // inserted; asking which one is not a destination, and a failure ran nothing.
    static func ranACommand(_ reply: VoiceCommandAnswer) -> Bool {
        let outcome: VoiceCommandOutcome
        switch reply {
        case .command(let commandOutcome): outcome = commandOutcome
        case .selected(let selection): outcome = selection.outcome
        case .cancelled, .retry: return false
        }
        switch outcome {
        case .done, .started: return true
        case .failed, .needsChoice, .cancelled, .abandoned: return false
        }
    }
}
