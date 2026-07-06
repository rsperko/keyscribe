import Foundation

// Reference-free scoring for the capture self-test (`--capture-probe`). Capture defects (dropped/duplicated
// ring slot, resampler glitch, overrun) are inaudible when audio goes straight to STT. A pure tone turns
// them into a number: a clean sine obeys x[n] = 2cos(ω)·x[n-1] − x[n-2] exactly, so the residual
// r[n] = x[n] − 2cos(ω)·x[n-1] + x[n-2] is ~0 for clean capture and SPIKES at any dropped/duplicated/corrupt
// sample. No FFT, no reference signal — just the expected tone frequency.
public enum CaptureProbeScoring {
    public struct Metrics: Sendable, Equatable {
        public let sampleCount: Int
        public let rms: Float
        public let peak: Float
        // 10·log10(Σx² / Σr²): signal over sine-recurrence residual energy. Very high (capped) for a clean
        // tone; noise/distortion/glitches lower it.
        public let sinadDB: Float
        // The worst single residual as a fraction of peak amplitude — one dropped ring slot shows here.
        public let maxGlitchRatio: Float
        // How many samples had a residual above `glitchThreshold × peak` (0 for clean capture).
        public let glitchCount: Int
    }

    public static let sinadCeilingDB: Float = 120

    // `samples` mono; `toneHz` the input frequency; `sampleRate` the capture rate. `glitchThreshold` is the
    // residual-vs-peak fraction counting as a glitch (a dropped sample yields a residual near the amplitude,
    // far above a clean sine's ~1e-6 floor).
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
