import Foundation
import KeyScribeKit
import os

@MainActor
final class InsertOutput {
    struct Request {
        let text: String
        let heard: String
        let mode: Mode?
        let captured: TargetSnapshot?
        let trailing: String
        let submit: Mode.Submit
        let submitOverride: Mode.Submit?
        let stoppedAtLimit: String?
        let paste: ClipboardPaste
    }

    enum Result: Equatable {
        case preempted
        case abandoned
        case refused(message: String, action: HUDErrorAction?)
        case done(DictationOutcome)
    }

    struct Report {
        var targetCheckMs: Double?
        var insertMs: Double?
        var targetBundleId: String?
        var delivery: String?
        var clipboardReason: String?
    }

    private let log = Logger(subsystem: "com.keyscribe.app", category: "dictation")
    private let snapshotAsync: @MainActor () async -> TargetSnapshot
    private let accessibilityGranted: @MainActor () -> Bool
    private let insert: (InsertionDecision, Mode.Insertion, ClipboardPaste, String, Bool) async -> Bool
    private let submitKey: (Mode.Submit) async -> Void

    init(
        snapshotAsync: @escaping @MainActor () async -> TargetSnapshot,
        accessibilityGranted: @escaping @MainActor () -> Bool,
        insert: @escaping (InsertionDecision, Mode.Insertion, ClipboardPaste, String, Bool) async -> Bool,
        submitKey: @escaping (Mode.Submit) async -> Void
    ) {
        self.snapshotAsync = snapshotAsync
        self.accessibilityGranted = accessibilityGranted
        self.insert = insert
        self.submitKey = submitKey
    }

    func perform(
        _ request: Request, lease: TakeLease, onTextReady: (String) -> Void
    ) async -> (Result, Report) {
        var report = Report()
        guard lease.stillWanted() else { return (.abandoned, report) }
        guard lease.beginActing() else { return (.preempted, report) }
        let captured = request.captured ?? TargetSnapshot(bundleId: nil)
        let targetCheckStart = DispatchTime.now()
        let current = await snapshotAsync()
        report.targetCheckMs = Self.elapsedMs(since: targetCheckStart)
        let targetDecision = decideInsertion(captured: captured, current: current)
        let decision = accessibilityGranted() ? targetDecision : .clipboardFallback(reason: .accessibilityDenied)
        let method = request.mode?.insertion ?? .paste
        report.targetBundleId = request.captured?.bundleId ?? current.bundleId
        report.delivery = Self.delivery(decision, method: method)
        if case .clipboardFallback(let reason) = decision { report.clipboardReason = String(describing: reason) }
        let initialOutcome = DictationMachine.outcomeForTranscript(
            finalText: request.text, heard: request.heard, decision: decision)
        switch initialOutcome {
        case .noSpeech:
            if request.submitOverride != nil, request.text.isEmpty, let limit = request.stoppedAtLimit {
                return (.refused(message: "Stopped at the \(limit) limit — Return not pressed", action: nil), report)
            }
            guard let submitOverride = request.submitOverride, request.text.isEmpty else { return (.done(.noSpeech), report) }
            if decision == .insert, await submitTargetStillFocused(captured), lease.stillWanted() {
                await submitKey(submitOverride)
                return (.done(.inserted), report)
            }
            let refusal = Self.submitRefusal(for: decision)
            return (.refused(message: refusal.message, action: refusal.action), report)
        case .inserted, .copied:
            onTextReady(request.text)
            let submitFollows = initialOutcome == .inserted && request.submit != .none
            let insertStart = DispatchTime.now()
            let modeId = request.mode?.id ?? ""
            for (key, value) in request.mode?.invalidClipboardChords ?? [:] {
                log.error("mode \(modeId, privacy: .public): \(key, privacy: .public) = \"\(value, privacy: .public)\" is not a chord; falling back to the default")
            }
            guard lease.stillWanted() else { return (.abandoned, report) }
            // Actuation suspends inside (the clipboard settle, every typed character). Task-local, so the
            // abort reaches this insertion's call tree and nothing else, such as Paste Last.
            let actuated = await TextInserter.$shouldAbortInsertion.withValue(lease.abortsActuation) {
                await insert(decision, method, request.paste, request.text + request.trailing, submitFollows)
            }
            report.insertMs = Self.elapsedMs(since: insertStart)
            guard lease.stillWanted() else { return (.abandoned, report) }
            guard actuated else { return (.done(.failed), report) }
            if initialOutcome == .inserted, request.submit != .none,
               await submitTargetStillFocused(captured), lease.stillWanted() {
                await submitKey(request.submit)
            }
            return (.done(initialOutcome), report)
        case .failed:
            return (.done(.failed), report)
        }
    }

    // The submit Return fires after the paste-settle window and lands outside the insert atom, so the same
    // focus-race decision runs again against a fresh snapshot.
    private func submitTargetStillFocused(_ captured: TargetSnapshot) async -> Bool {
        let decision = decideInsertion(captured: captured, current: await snapshotAsync())
        if decision == .insert { return true }
        log.notice("submit skipped: focus moved before Return (\(String(describing: decision), privacy: .public))")
        return false
    }

    static func submitRefusal(for decision: InsertionDecision) -> (message: String, action: HUDErrorAction?) {
        switch decision {
        case .clipboardFallback(.accessibilityDenied):
            return ("Accessibility is off — \(Branding.appName) can't press Return for you.", .openAccessibilitySettings)
        case .clipboardFallback(.secureField):
            return ("Return not sent — the focused field is a password field.", nil)
        case .clipboardFallback, .insert:
            return ("Return not sent — the target window changed.", nil)
        }
    }

    static func delivery(_ decision: InsertionDecision, method: Mode.Insertion) -> String {
        let action = String(describing: insertionAction(decision: decision, method: method))
        guard case .clipboardFallback(let reason) = decision else { return action }
        return "\(action) (\(reason))"
    }

    private static func elapsedMs(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    }
}
