import Foundation

// One structured record per capture start. Written from three threads (the start task, the control queue, the
// writer thread), so every field is lock-guarded.
//
// Timings are milliseconds from `AudioCapture.start()`, NOT from the trigger. GROUPING RULE: the transport
// that delivered is `bound-transport` when present, else `transport`. Both are documented in AGENTS.md.
final class CaptureStartRecord: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = DispatchTime.now()
    private let transport: String
    private let policy: String
    private var stages: [(name: String, ms: Double)] = []
    private var events: [String] = []
    private var target: String?
    private var bound: String?
    private var boundTransport: String?
    private var deliveringFrozen = false

    private static func transportName(isBluetooth: Bool) -> String { isBluetooth ? "bluetooth" : "other" }

    init(targetIsBluetooth: Bool, explicitDevice: Bool, target: String?) {
        transport = Self.transportName(isBluetooth: targetIsBluetooth)
        policy = explicitDevice ? "explicit" : "default"
        self.target = target
    }

    func stage(_ name: String) {
        let ms = millisSinceOrigin()
        lock.withLock { stages.append((name, ms)) }
    }

    private func millisSinceOrigin() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - origin.uptimeNanoseconds) / 1e6
    }

    func event(_ text: String) {
        lock.withLock { events.append(text) }
    }

    // Ignored once frozen.
    func noteBound(_ name: String?, isBluetooth: Bool) {
        lock.withLock {
            guard !deliveringFrozen else { return }
            bound = name
            boundTransport = Self.transportName(isBluetooth: isBluetooth)
        }
    }

    // Called at the first valid buffer: whatever is bound at that instant is what delivered it, so record the
    // timing and stop tracking later binds — in ONE critical section, or a noteBound landing between the two
    // files this timing under a device that never delivered it.
    func noteFirstBuffer() {
        let ms = millisSinceOrigin()
        lock.withLock {
            stages.append(("first-buffer", ms))
            deliveringFrozen = true
        }
    }

    func summary(outcome: String) -> String {
        lock.withLock {
            var parts = ["outcome=\(outcome)", "policy=\(policy)", "transport=\(transport)"]
            if let boundTransport, boundTransport != transport { parts.append("bound-transport=\(boundTransport)") }
            parts.append("target=\(target ?? "none")")
            if bound != target { parts.append("bound=\(bound ?? "none")") }
            parts.append(contentsOf: stages.map { "\($0.name)=\(Int($0.ms.rounded()))ms" })
            if !events.isEmpty { parts.append("events=[\(events.joined(separator: ","))]") }
            return parts.joined(separator: " ")
        }
    }
}
