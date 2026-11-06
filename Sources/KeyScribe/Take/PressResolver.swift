import Foundation
import KeyScribeKit

enum PressResolver {
    struct Choice: Equatable {
        let mode: Mode
        let reason: ModeChoiceReason
        let shortcutCandidates: [ModeCandidate]
        let triggerDisplay: String?
    }

    struct PhaseA: Equatable {
        let eligible: [Mode]
        let consumesOverride: Bool
        let choice: Choice?
    }

    // Phase A (design.md §4.3). A non-nil triggerKey (from a mode's own binding) forces that mode, overriding
    // context. A menu-picked one-shot mode is an explicit choice that bypasses the context gate, so it also
    // outranks a "nothing can serve this press" verdict. The Voice Commands shortcut never speaks into a
    // field, so it leaves the one-shot for the next dictation.
    static func phaseA(modes: [Mode], context: RoutingContext, triggerKey: String?, overrideId: String?) -> PhaseA {
        let eligible = ModeResolver.eligibleModes(modes, context: context)
        // The Direct floor is a persisted system mode, so its user-configured trigger/insertion apply both
        // when its key is pressed and when a trigger falls through to it. The canonical profile is only a
        // fallback for a floor somehow missing on disk.
        let directFallback = modes.first { $0.id == Mode.directId } ?? .direct
        let resolved = ModeResolver.resolvePhaseAWithReason(
            modes: modes, directFallback: directFallback, context: context, triggerKey: triggerKey,
            eligible: eligible)
        let commandPress = resolved?.reason == .triggerKey && resolved?.mode.runsVoiceCommands == true
        let override = commandPress ? nil : overrideId.flatMap { id in modes.first { $0.id == id && $0.enabled } }
        let chosen: (Mode, ModeChoiceReason)?
        if let override {
            chosen = (override, .oneShot)
        } else if let resolved {
            chosen = (resolved.mode, resolved.reason)
        } else {
            chosen = nil
        }
        return PhaseA(eligible: eligible, consumesOverride: !commandPress, choice: chosen.map { mode, reason in
            Choice(
                mode: mode, reason: reason,
                shortcutCandidates: override == nil
                    ? ModeResolver.keyCandidates(modes: modes, context: context, triggerKey: triggerKey) : [],
                triggerDisplay: reason == .triggerKey
                    ? triggerKey.flatMap { try? KeyDescriptor(parsing: $0) }?.displayString : nil)
        })
    }

    // The fuller, secure-aware snapshot is adopted only when the target is unchanged — same bundle AND pid. If
    // it moved, the field cannot be confirmed safe (a dictation begun in a password field must not leak because
    // focus shifted during the probe), so nil: the take goes fully local (KS-01). Secure is sticky: a later
    // non-secure read of the same process never clears it.
    static func adoption(of full: TargetSnapshot, capturedBundle: String?, capturedPid: Int32?, capturedSecure: Bool) -> TargetSnapshot? {
        guard full.bundleId == capturedBundle, full.pid == capturedPid else { return nil }
        var adopted = full
        adopted.isSecureField = adopted.isSecureField || capturedSecure
        return adopted
    }

    // Each probe runs only when a candidate mode's constraints use it: the URL probe needs Apple Events (an
    // Automation prompt), the title probe an extra AX round trip. Both bind to the captured process and window.
    @MainActor static func probeContext(candidates: [Mode], captured: TargetSnapshot?) async -> (url: String?, windowTitle: String?) {
        guard let bundleId = captured?.bundleId else { return (nil, nil) }
        var url: String?
        var windowTitle: String?
        if ModeResolver.requiresURLContext(candidates) {
            url = await ContextProbe.browserURLAsync(
                forBundleId: bundleId, pid: captured?.pid, windowId: captured?.focusedWindowId)
        }
        if ModeResolver.requiresWindowTitleContext(candidates), let pid = captured?.pid {
            windowTitle = ContextProbe.focusedWindowTitle(pid: pid, expectedWindowId: captured?.focusedWindowId)
        }
        return (url, windowTitle)
    }
}
