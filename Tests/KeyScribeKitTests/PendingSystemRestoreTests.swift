import Foundation
import Testing
@testable import KeyScribeKit

struct PendingSystemRestoreModelTests {
    @Test func isEmptyOnlyWhenNoDeviceRecorded() {
        #expect(PendingSystemRestore().isEmpty)
        #expect(!PendingSystemRestore(defaultInputUID: "uid").isEmpty)
        #expect(!PendingSystemRestore(legacyMutedOutputUID: "out").isEmpty)
    }

    @Test func decodingCapturesLegacyOutputMuteForRecovery() throws {
        let legacy = #"{"defaultInputUID":"mic","outputMute":{"deviceUID":"out","previousMute":0}}"#
        let decoded = try #require(PendingSystemRestore.decode(from: Data(legacy.utf8)))
        #expect(decoded.defaultInputUID == "mic")
        #expect(decoded.legacyMutedOutputUID == "out")
    }

    @Test func outputOnlyLegacyMarkerIsNotEmpty() throws {
        let legacy = #"{"outputMute":{"deviceUID":"out","previousMute":0}}"#
        let decoded = try #require(PendingSystemRestore.decode(from: Data(legacy.utf8)))
        #expect(!decoded.isEmpty)
        #expect(decoded.legacyMutedOutputUID == "out")
    }

    @Test func decodeReturnsNilForGarbage() {
        #expect(PendingSystemRestore.decode(from: Data("not json".utf8)) == nil)
    }

    @Test func decodeEmptyObjectIsEmpty() throws {
        let decoded = try #require(PendingSystemRestore.decode(from: Data("{}".utf8)))
        #expect(decoded.isEmpty)
    }
}
