import AVFoundation
import Foundation
import KeyScribeKit

// Headless capture self-test (`--capture-probe`). Drives the REAL capture path (`AudioCapture.start →
// record → finishDraining`), exercising the RT-thread ring, writer thread, drain gate, and teardown as a
// live dictation does (which the WAV-fed `--benchmark`/`--commands-check` do NOT). Feed a known pure tone
// into the input (via an Aggregate/loopback device); the probe reports SINAD, a glitch count, CoreAudio's
// overload count, and the ring's drop count — all should be 0, a non-zero value being ear-free proof the
// RT path dropped or corrupted audio.
enum CaptureProbeRunner {
    static func run(seconds: Double, toneHz: Double) async {
        guard Permissions.microphoneStatus() == .granted else {
            print("capture-probe: microphone permission is not granted — grant it and retry.")
            return
        }
        let rate = 16_000
        let audio = AudioCapture()
        // Let the idle prewarm settle so the first bring-up is on the hot path (as in real use).
        audio.prewarm()
        try? await Task.sleep(for: .milliseconds(300))

        print("capture-probe: recording \(String(format: "%.1f", seconds))s at \(rate) Hz — "
            + "feed a \(Int(toneHz)) Hz tone into the selected input now.")
        do {
            _ = try await audio.start(sampleRate: rate)
        } catch {
            print("capture-probe: bring-up failed: \(error)")
            return
        }
        try? await Task.sleep(for: .seconds(seconds))
        guard let finalURL = await audio.finishDraining() else {
            print("capture-probe: capture produced no file.")
            return
        }
        // Mainline dictation now transcribes the writer's in-memory samples, NOT the WAV — so verify the two
        // are identical here (P2-4). Read before the WAV so a divergence surfaces even if the file read fails.
        let drained = audio.takeDrainedSamples()
        let diag = audio.captureDiagnostics()

        let samples: [Float]
        do { samples = try readMonoFloat(finalURL) } catch {
            print("capture-probe: could not read \(finalURL.path): \(error)")
            return
        }
        let samplesMatchWAV = drained == samples
        // The commit path already archived a copy if KEYSCRIBE_KEEP_CAPTURE is set; drop the working file.
        try? FileManager.default.removeItem(at: finalURL)

        let m = CaptureProbeScoring.score(samples: samples, toneHz: Double(toneHz), sampleRate: Double(rate))
        let durationS = Double(m.sampleCount) / Double(rate)
        let clean = diag.ringDropped == 0 && diag.overloads == 0 && m.glitchCount == 0 && samplesMatchWAV

        let samplesLine: String
        if let drained {
            samplesLine = samplesMatchWAV
                ? "\(drained.count) == WAV (in-memory STT path matches the file)"
                : "MISMATCH — \(drained.count) samples vs \(samples.count) in the WAV (STT would diverge from the probe)"
        } else {
            samplesLine = "nil — writer did not accumulate (engine can't consume samples)"
        }

        print("""
        == capture-probe ==
          samples          : \(m.sampleCount)  (\(String(format: "%.2f", durationS))s @ \(rate) Hz)
          rms / peak        : \(String(format: "%.4f", m.rms)) / \(String(format: "%.4f", m.peak))
          tone \(Int(toneHz)) Hz SINAD  : \(String(format: "%.1f", m.sinadDB)) dB   (higher = cleaner; a clean tone is >80)
          glitches          : \(m.glitchCount)   maxGlitchRatio: \(String(format: "%.3f", m.maxGlitchRatio))
          in-memory samples : \(samplesLine)
          ring dropped      : \(diag.ringDropped)   (writer-keep-up canary; must be 0)
          CoreAudio overloads: \(diag.overloads)   (RT-deadline canary; must be 0)
          verdict           : \(clean ? "CLEAN" : "SUSPECT — investigate the non-zero counters above")
        """)
        if m.peak < 0.001 {
            print("  note: near-silent capture — no tone was detected on the input; check the loopback routing.")
        }
    }

    private static func readMonoFloat(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            return []
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }
}
