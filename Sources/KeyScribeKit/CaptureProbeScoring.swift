import Foundation

// Reference-free scoring for the capture self-test (`--capture-probe`). The RT-thread ring split can only
// fail in ways you cannot HEAR when the audio goes straight to STT — a dropped/duplicated ring slot, a
// resampler glitch, an overrun under load. Feeding a known PURE TONE into the input turns those into a
// number: a clean sine obeys the second-order recurrence x[n] = 2cos(ω)·x[n-1] − x[n-2] exactly, so the
// residual r[n] = x[n] − 2cos(ω)·x[n-1] + x[n-2] is ~0 for clean capture and SPIKES wherever a sample was
// dropped, duplicated, or corrupted. No FFT and no reference signal needed — just the expected tone
// frequency. Pure so it is unit-tested against synthetic clean and deliberately-glitched signals.
public enum CaptureProbeScoring {
    public struct Metrics: Sendable, Equatable {
        public let sampleCount: Int
        public let rms: Float
        public let peak: Float
        // 10·log10(Σx² / Σr²): signal energy over sine-recurrence residual energy. A clean tone drives the
        // residual to ~0 so this is very high (capped); noise, distortion, or glitches lower it.
        public let sinadDB: Float
        // The worst single residual as a fraction of peak amplitude — one dropped ring slot shows here.
        public let maxGlitchRatio: Float
        // How many samples had a residual above `glitchThreshold × peak` (0 for clean capture).
        public let glitchCount: Int
    }

    public static let sinadCeilingDB: Float = 120

    // `samples` mono. `toneHz` is the frequency fed into the input; `sampleRate` the capture rate.
    // `glitchThreshold` is the residual-vs-peak fraction that counts as a glitch (a dropped sample in a sine
    // produces a residual on the order of the amplitude, far above the ~1e-6 floor of a clean sine).
    public static func score(
        samples: [Float], toneHz: Double, sampleRate: Double, glitchThreshold: Float = 0.1
    ) -> Metrics {
        let n = samples.count
        guard n > 0, sampleRate > 0 else {
            return Metrics(sampleCount: n, rms: 0, peak: 0, sinadDB: 0, maxGlitchRatio: 0, glitchCount: 0)
        }
        var sumSq: Double = 0
        var peak: Float = 0
        for x in samples {
            sumSq += Double(x) * Double(x)
            peak = max(peak, abs(x))
        }
        let rms = Float((sumSq / Double(n)).squareRoot())

        guard n >= 3 else {
            return Metrics(sampleCount: n, rms: rms, peak: peak, sinadDB: 0, maxGlitchRatio: 0, glitchCount: 0)
        }
        let coeff = 2 * cos(2 * Double.pi * toneHz / sampleRate)
        var sumX2: Double = 0   // energy over the residual window (n≥2), so the two ratios use the same span
        var sumR2: Double = 0
        var maxAbsR: Double = 0
        var glitchCount = 0
        let glitchAbs = Double(glitchThreshold) * Double(peak)
        for i in 2..<n {
            let r = Double(samples[i]) - coeff * Double(samples[i - 1]) + Double(samples[i - 2])
            sumX2 += Double(samples[i]) * Double(samples[i])
            sumR2 += r * r
            let ar = abs(r)
            if ar > maxAbsR { maxAbsR = ar }
            if peak > 0, ar > glitchAbs { glitchCount += 1 }
        }
        let sinad: Float
        if sumR2 <= 0 {
            sinad = sumX2 > 0 ? sinadCeilingDB : 0
        } else {
            sinad = min(sinadCeilingDB, Float(10 * log10(sumX2 / sumR2)))
        }
        let maxGlitch = peak > 0 ? Float(maxAbsR / Double(peak)) : 0
        return Metrics(
            sampleCount: n, rms: rms, peak: peak, sinadDB: sinad,
            maxGlitchRatio: maxGlitch, glitchCount: glitchCount)
    }
}
