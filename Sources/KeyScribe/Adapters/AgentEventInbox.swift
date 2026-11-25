import Foundation
import KeyScribeKit

final class AgentEventInbox: @unchecked Sendable {
    static let defaultHelloWait: TimeInterval = 0.15
    static let defaultCeiling: TimeInterval = 1

    private let lock = NSLock()
    private let helloWait: TimeInterval
    private let ceiling: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let later: @Sendable (TimeInterval, DispatchWorkItem) -> Void
    private let deliver: @MainActor ([AgentEvent]) -> Void
    private var waiting: [AgentEvent] = []
    private var drainQueued = false
    private var burst: DispatchWorkItem?
    private var opened: TimeInterval = 0
    private var lastJoin: TimeInterval = 0

    init(
        helloWait: TimeInterval = AgentEventInbox.defaultHelloWait,
        ceiling: TimeInterval = AgentEventInbox.defaultCeiling,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        later: @escaping @Sendable (TimeInterval, DispatchWorkItem) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) },
        deliver: @escaping @MainActor ([AgentEvent]) -> Void
    ) {
        self.helloWait = helloWait
        self.ceiling = ceiling
        self.now = now
        self.later = later
        self.deliver = deliver
    }

    func add(_ event: AgentEvent) {
        let (immediate, timed) = lock.withLock { () -> (Bool, DispatchWorkItem?) in
            waiting.append(event)
            let opens = if case .hello = event { true } else { false }
            guard opens || (burst != nil && Self.joinsBurst(event)) else {
                defer { drainQueued = true }
                return (!drainQueued, nil)
            }
            guard burst == nil, !drainQueued else {
                lastJoin = now()
                return (false, nil)
            }
            opened = now()
            lastJoin = opened
            let timed = wakeItem()
            burst = timed
            return (false, timed)
        }
        if immediate { DispatchQueue.main.async { MainActor.assumeIsolated { self.drain() } } }
        if let timed { later(min(helloWait, ceiling), timed) }
    }

    private func wakeItem() -> DispatchWorkItem {
        DispatchWorkItem { MainActor.assumeIsolated { self.wake() } }
    }

    @MainActor private func wake() {
        let rearm = lock.withLock { () -> (TimeInterval, DispatchWorkItem)? in
            let remaining = min(lastJoin + helloWait, opened + ceiling) - now()
            guard burst != nil, !drainQueued, remaining > 0.001 else { return nil }
            let next = wakeItem()
            burst = next
            return (remaining, next)
        }
        if let (remaining, next) = rearm { later(remaining, next) } else { drain() }
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
