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

// The tail-drain backstop must not resume a drain that has already been superseded by a newer dictation —
// otherwise dictation N's stale 300 ms timer resumes dictation N+1's drain early and clips its final word.
struct TailDrainResumeArbitrationTests {
    @Test func currentBackstopResumes() {
        #expect(AudioCapture.shouldResumeDrain(backstopID: 7, currentDrainID: 7))
    }

    @Test func staleBackstopDoesNotResume() {
        #expect(!AudioCapture.shouldResumeDrain(backstopID: 7, currentDrainID: 8))
    }

    @Test func wildcardAlwaysResumes() {
        #expect(AudioCapture.shouldResumeDrain(backstopID: nil, currentDrainID: 8))
    }
}

struct CaptureReplacementUnitStartTests {
    @Test func currentActiveCaptureCanStartReplacementUnit() {
        #expect(AudioCapture.shouldStartReplacementUnit(
            generation: 4, currentGeneration: 4, captureActive: true))
    }

    @Test func staleGenerationCannotStartReplacementUnit() {
        #expect(!AudioCapture.shouldStartReplacementUnit(
            generation: 4, currentGeneration: 5, captureActive: true))
    }

    @Test func endedCaptureCannotStartReplacementUnit() {
        #expect(!AudioCapture.shouldStartReplacementUnit(
            generation: 4, currentGeneration: 4, captureActive: false))
    }
}

// V1: the queued step-4 unit teardown may only touch the unit while its scheduling generation is current.
struct CaptureUnitTeardownGuardTests {
    @Test func currentGenerationTearsDownUnit() {
        #expect(AudioCapture.shouldTeardownUnit(generation: 3, currentGeneration: 3))
    }

    @Test func supersededGenerationSkipsTeardown() {
        #expect(!AudioCapture.shouldTeardownUnit(generation: 3, currentGeneration: 4))
    }
}

// Capture-device resolution: a present preferred device wins; else the system default; else nothing is
// available. `isPreferredPresent` drives the error policy — a failed PRESENT preferred device is surfaced
// (don't silently record from a different mic), while a default-follow failure is retried. The AUHAL binds
// whichever device this resolves to on its OWN CurrentDevice, so there is no system-default flip.
struct CaptureDeviceResolutionTests {
    private func resolve(_ map: [String: AudioDeviceID]) -> (String) -> AudioDeviceID? { { map[$0] } }

    @Test func noPreferredFollowsSystemDefault() {
        let target = AudioCapture.captureTarget(
            preferredUID: nil, resolvePreferred: resolve([:]), systemDefault: 5)
        #expect(target == .systemDefault(5))
        #expect(!target.isPreferredPresent)
        #expect(target.deviceID == 5)
    }

    @Test func emptyPreferredFollowsSystemDefault() {
        let target = AudioCapture.captureTarget(
            preferredUID: "", resolvePreferred: resolve(["": 9]), systemDefault: 5)
        #expect(target == .systemDefault(5))
    }

    @Test func presentPreferredWins() {
        let target = AudioCapture.captureTarget(
            preferredUID: "DeskMic", resolvePreferred: resolve(["DeskMic": 7]), systemDefault: 5)
        #expect(target == .preferred(7))
        #expect(target.isPreferredPresent)
        #expect(target.deviceID == 7)
    }

    @Test func disconnectedPreferredFallsBackToDefaultAndIsRetryable() {
        // Preferred configured but not connected: follow the default, and a failure there is retried
        // (isPreferredPresent == false) rather than surfaced as "Could not start <mic>".
        let target = AudioCapture.captureTarget(
            preferredUID: "DeskMic", resolvePreferred: resolve([:]), systemDefault: 5)
        #expect(target == .systemDefault(5))
        #expect(!target.isPreferredPresent)
    }

    @Test func noDeviceAtAllIsUnavailable() {
        let target = AudioCapture.captureTarget(
            preferredUID: "DeskMic", resolvePreferred: resolve([:]), systemDefault: nil)
        #expect(target == .unavailable)
        #expect(target.deviceID == nil)
    }
}

// The client format we set on the AUHAL after binding the device must match the device's OWN native rate
// and channel count — matching (never forcing an unsupported rate/channels) is exactly how -10868 is
// avoided. A degenerate native format yields nil so the caller fails the bring-up cleanly.
struct ClientStreamFormatTests {
    @Test func matchesNativeRateAndChannels() throws {
        let format = try #require(AudioCapture.clientStreamFormat(nativeSampleRate: 48_000, nativeChannels: 2))
        #expect(format.sampleRate == 48_000)
        #expect(format.channelCount == 2)
        #expect(format.commonFormat == .pcmFormatFloat32)
        #expect(!format.isInterleaved)
    }

    @Test func bluetoothHFPMonoIsAccepted() throws {
        let format = try #require(AudioCapture.clientStreamFormat(nativeSampleRate: 16_000, nativeChannels: 1))
        #expect(format.sampleRate == 16_000)
        #expect(format.channelCount == 1)
    }

    @Test func degenerateNativeFormatIsRejected() {
        #expect(AudioCapture.clientStreamFormat(nativeSampleRate: 0, nativeChannels: 0) == nil)
        #expect(AudioCapture.clientStreamFormat(nativeSampleRate: 48_000, nativeChannels: 0) == nil)
        #expect(AudioCapture.clientStreamFormat(nativeSampleRate: 0, nativeChannels: 2) == nil)
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
