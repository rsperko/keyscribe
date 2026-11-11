import Foundation
import Testing
@testable import KeyScribeApp

struct InputTransportCacheTests {
    private final class Lookups: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var answer = true
        var count: Int { lock.withLock { _count } }
        func look() -> Bool { lock.withLock { _count += 1 }; return answer }
    }

    @Test func theBluetoothAnswerIsLookedUpOnceUntilTheInputChanges() {
        let capture = AudioCapture()
        let lookups = Lookups()
        capture.bluetoothLookup = { lookups.look() }
        #expect(capture.inputIsBluetooth)
        #expect(capture.inputIsBluetooth)
        #expect(lookups.count == 1)
        lookups.answer = false
        capture.forgetInputTransport()
        #expect(!capture.inputIsBluetooth)
        #expect(lookups.count == 2)
    }

    @Test func anAnswerLookedUpAcrossAnInputChangeIsNotKept() {
        let capture = AudioCapture()
        let lookups = Lookups()
        capture.bluetoothLookup = { [weak capture] in
            capture?.forgetInputTransport()
            return lookups.look()
        }
        _ = capture.inputIsBluetooth
        _ = capture.inputIsBluetooth
        #expect(lookups.count == 2)
    }
}
