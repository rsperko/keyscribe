import Foundation
import KeyScribeKit

final class AgentEventInbox: @unchecked Sendable {
    static let defaultHelloWait: TimeInterval = 0.15

    private let lock = NSLock()
    private let helloWait: TimeInterval
    private let later: @Sendable (TimeInterval, DispatchWorkItem) -> Void
    private let deliver: @MainActor ([AgentEvent]) -> Void
    private var waiting: [AgentEvent] = []
    private var drainQueued = false
    private var burst: DispatchWorkItem?

    init(
        helloWait: TimeInterval = AgentEventInbox.defaultHelloWait,
        later: @escaping @Sendable (TimeInterval, DispatchWorkItem) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) },
        deliver: @escaping @MainActor ([AgentEvent]) -> Void
    ) {
        self.helloWait = helloWait
        self.later = later
        self.deliver = deliver
    }

    func add(_ event: AgentEvent) {
        let (now, timed) = lock.withLock { () -> (Bool, DispatchWorkItem?) in
            waiting.append(event)
            let opens = if case .hello = event { true } else { false }
            guard opens || (burst != nil && Self.joinsBurst(event)) else {
                defer { drainQueued = true }
                return (!drainQueued, nil)
            }
            guard burst == nil, !drainQueued else { return (false, nil) }
            let timed = DispatchWorkItem { MainActor.assumeIsolated { self.drain() } }
            burst = timed
            return (false, timed)
        }
        if now { DispatchQueue.main.async { MainActor.assumeIsolated { self.drain() } } }
        if let timed { later(helloWait, timed) }
    }

    @MainActor func drain() {
        let taken = lock.withLock { () -> [AgentEvent] in
            defer {
                waiting = []
                drainQueued = false
                burst?.cancel()
                burst = nil
            }
            return waiting
        }
        if !taken.isEmpty { deliver(taken) }
    }

    private static func joinsBurst(_ event: AgentEvent) -> Bool {
        switch event {
        case .hello, .title, .shown, .waiting: true
        case .ack, .submitted, .checked, .refused, .undelivered, .focused, .typed, .turnStarted, .absorbed, .turnComplete, .notify: false
        }
    }
}
