import Foundation
import Testing
@testable import KeyScribeApp

struct StopGateTests {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _wanted = true
        private var _asked = 0
        var wanted: Bool {
            get { lock.withLock { _wanted } }
            set { lock.withLock { _wanted = newValue } }
        }
        var asked: Int { lock.withLock { _asked } }
        func read() -> Bool { lock.withLock { _asked += 1; return _wanted } }
    }

    @Test func aGateClosesOnceTheStopCheckFailsAndStopsAskingWhenFinished() async {
        let flag = Flag()
        let registry = StopGate.Registry()
        let gate = StopGate.watching({ flag.read() }, every: .milliseconds(1), in: registry)
        for _ in 0..<200 where flag.asked < 3 { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(gate.isOpen)
        flag.wanted = false
        for _ in 0..<500 where gate.isOpen { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(!gate.isOpen)
        await gate.finish()
        flag.wanted = true
        let open = StopGate.watching({ flag.read() }, every: .milliseconds(1), in: registry)
        await open.finish()
        let asked = flag.asked
        try? await Task.sleep(for: .milliseconds(20))
        #expect(flag.asked == asked)
        #expect(open.isOpen)
    }

    @Test func aStopClosesEveryOpenGateAtOnceWithoutWaitingForAPoll() async {
        let registry = StopGate.Registry()
        let gate = StopGate.watching({ true }, every: .seconds(10), in: registry)
        let finished = StopGate.watching({ true }, every: .seconds(10), in: registry)
        await finished.finish()
        StopGate.closeAll(in: registry)
        #expect(!gate.isOpen)
        #expect(finished.isOpen)
        await gate.finish()
    }
}
