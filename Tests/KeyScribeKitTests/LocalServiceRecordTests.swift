import Foundation
import KeyScribeKit
import Testing

struct LocalServiceRecordTests {
    private let written = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aProcessThatStartedBeforeItsRecordWasWrittenIsTrusted() {
        #expect(LocalServiceRecord.trusts(processStarted: written.addingTimeInterval(-60), recordedAt: written))
        #expect(LocalServiceRecord.trusts(processStarted: written.addingTimeInterval(1.5), recordedAt: written))
    }

    @Test func aProcessThatStartedAfterTheRecordReusedItsPidAndIsNotTrusted() {
        #expect(!LocalServiceRecord.trusts(processStarted: written.addingTimeInterval(3), recordedAt: written))
    }

    @Test func aProcessWhoseStartCannotBeReadIsNotTrusted() {
        #expect(!LocalServiceRecord.trusts(processStarted: nil, recordedAt: written))
    }

    @Test(arguments: ["http://127.0.0.1:4096", "https://localhost:8080/x", "http://[::1]:9"])
    func aLoopbackAddressIsAccepted(text: String) {
        #expect(LocalServiceRecord.loopback(text) == URL(string: text))
    }

    @Test(arguments: ["http://10.0.0.2:4096", "ftp://127.0.0.1", "127.0.0.1:80", "http://evil.example/127.0.0.1", ""])
    func anyOtherAddressIsRefused(text: String) {
        #expect(LocalServiceRecord.loopback(text) == nil)
    }
}
