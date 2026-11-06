import Foundation

enum AutomationVerdict: Equatable, Sendable {
    case allowed, denied, needsAsking, unknown
}

enum AutomationConsent {
    struct Settled: Equatable, Sendable {
        var readable: [String] = []
        var refused: [String] = []
        var unanswered: [String] = []
    }

    static let checkDeadline: TimeInterval = 0.5
    static let answerDeadline: TimeInterval = 60
    private static let consentQueue = DeadlineQueue(label: "com.keyscribe.voice-commands.automation-consent")

    static func settle(
        _ bundleIds: [String], queue: DeadlineQueue = consentQueue, checkWithin: TimeInterval = checkDeadline,
        answerWithin: TimeInterval = answerDeadline, mayAsk: Bool = true,
        verdict: @escaping @Sendable (String, Bool) -> AutomationVerdict = AutomationConsent.verdict(of:asking:),
        willAsk: @Sendable (String) async -> Void = { _ in }
    ) async -> Settled {
        var settled = Settled()
        for bundleId in bundleIds {
            var answer = await queue.run(within: checkWithin) { verdict(bundleId, false) }
            if mayAsk, case .finished(.needsAsking) = answer {
                await willAsk(bundleId)
                answer = await queue.run(within: answerWithin) { verdict(bundleId, true) }
            }
            switch answer {
            case .finished(.allowed): settled.readable.append(bundleId)
            case .finished(.unknown): mayAsk ? settled.readable.append(bundleId) : settled.unanswered.append(bundleId)
            case .finished(.denied): settled.refused.append(bundleId)
            case .finished(.needsAsking), .expired: settled.unanswered.append(bundleId)
            }
        }
        return settled
    }

    nonisolated static func verdict(of bundleId: String, asking: Bool) -> AutomationVerdict {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        switch AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, asking) {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .needsAsking
        default: return .unknown
        }
    }
}
