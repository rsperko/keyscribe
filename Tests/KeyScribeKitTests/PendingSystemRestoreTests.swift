import Foundation
import Testing
@testable import KeyScribeKit

struct PendingSystemRestoreModelTests {
    @Test func isEmptyOnlyWhenNoDeviceRecorded() {
        #expect(PendingSystemRestore().isEmpty)
        #expect(!PendingSystemRestore(defaultInputUID: "uid").isEmpty)
        #expect(!PendingSystemRestore(legacyMutedOutputUID: "out").isEmpty)
    }

    // An older (pre-duck) build wrote an `outputMute` object; decoding such a marker must keep the input
    // restore AND surface the muted device UID so launch reconcile can unmute the pre-upgrade strand.
    @Test func decodingCapturesLegacyOutputMuteForRecovery() throws {
        let legacy = #"{"defaultInputUID":"mic","outputMute":{"deviceUID":"out","previousMute":0}}"#
        let decoded = try #require(PendingSystemRestore.decode(from: Data(legacy.utf8)))
        #expect(decoded.defaultInputUID == "mic")
        #expect(decoded.legacyMutedOutputUID == "out")
    }

    // An output-only legacy marker (the common shape — no input override) must not decode as empty, or
    // reconcile would skip it and leave the user stranded muted.
    @Test func outputOnlyLegacyMarkerIsNotEmpty() throws {
        let legacy = #"{"outputMute":{"deviceUID":"out","previousMute":0}}"#
        let decoded = try #require(PendingSystemRestore.decode(from: Data(legacy.utf8)))
        #expect(!decoded.isEmpty)
        #expect(decoded.legacyMutedOutputUID == "out")
    }

    // Undecodable bytes must decode to nil so the launch reconcile leaves an unreadable marker on disk
    // rather than treating it as empty and clearing it.
    @Test func decodeReturnsNilForGarbage() {
        #expect(PendingSystemRestore.decode(from: Data("not json".utf8)) == nil)
    }

    // A well-formed but empty object decodes to a non-nil, empty value — reconcile then leaves it alone.
    @Test func decodeEmptyObjectIsEmpty() throws {
        let decoded = try #require(PendingSystemRestore.decode(from: Data("{}".utf8)))
        #expect(decoded.isEmpty)
    }
}
