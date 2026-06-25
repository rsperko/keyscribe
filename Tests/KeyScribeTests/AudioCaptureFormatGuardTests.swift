import AVFoundation
import Foundation
import Testing
@testable import KeyScribe

// A degenerate input format (0 ch / 0 Hz, an output-only device) must be rejected before installTap,
// which would otherwise raise an uncatchable NSException → SIGABRT.
struct AudioCaptureFormatGuardTests {
    @Test func zeroRateOrZeroChannelFormatIsRejected() {
        #expect(!AudioCapture.isUsableInputFormat(sampleRate: 0, channelCount: 0))
        #expect(!AudioCapture.isUsableInputFormat(sampleRate: 0, channelCount: 2))
        #expect(!AudioCapture.isUsableInputFormat(sampleRate: 16_000, channelCount: 0))
    }

    @Test func realInputFormatIsAccepted() {
        #expect(AudioCapture.isUsableInputFormat(sampleRate: 16_000, channelCount: 1))
        #expect(AudioCapture.isUsableInputFormat(sampleRate: 48_000, channelCount: 2))
    }
}

// Pinning the input AUHAL breaks engine.start() with -10868 unless the preferred device truly differs
// from both the system default and what is already pinned.
struct PreferredDevicePinTests {
    @Test func noPreferredDeviceSkips() {
        #expect(AudioCapture.pinDecision(preferred: nil, systemDefault: 5, currentlyPinned: nil) == .skip)
    }

    @Test func preferredEqualToSystemDefaultSkips() {
        // The built-in-mic regression: preferred == default, so follow it instead of pinning.
        #expect(AudioCapture.pinDecision(preferred: 5, systemDefault: 5, currentlyPinned: nil) == .skip)
    }

    @Test func preferredAlreadyPinnedSkips() {
        // prewarm pinned it; arm must not re-set the now-initialized unit.
        #expect(AudioCapture.pinDecision(preferred: 7, systemDefault: 5, currentlyPinned: 7) == .skip)
    }

    @Test func preferredDifferentFromDefaultAndUnpinnedPins() {
        #expect(AudioCapture.pinDecision(preferred: 7, systemDefault: 5, currentlyPinned: nil) == .pin(7))
    }

    @Test func preferredDifferentFromADifferentPinRepins() {
        #expect(AudioCapture.pinDecision(preferred: 7, systemDefault: 5, currentlyPinned: 9) == .pin(7))
    }
}

// The shim must turn a raised NSException into a Swift error, and stay transparent on a clean block.
struct ObjCExceptionShimTests {
    @Test func raisedNSExceptionBecomesASwiftError() {
        #expect(throws: (any Error).self) {
            try ObjCException.catching {
                NSException(name: .invalidArgumentException, reason: "required condition is false", userInfo: nil).raise()
            }
        }
    }

    @Test func cleanBlockReturnsWithoutThrowing() throws {
        var ran = false
        try ObjCException.catching { ran = true }
        #expect(ran)
    }
}
