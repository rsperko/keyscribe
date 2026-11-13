import Foundation

public enum SpokenAudioCheck {
    public enum Problem: String, Sendable, Equatable {
        case empty = "no audio"
        case invalidSamples = "invalid samples"
        case silent = "silent audio"
    }

    public struct Measurements: Sendable, Equatable {
        public var seconds: Double
        public var peak: Float
        public var rms: Float
        public var clippedSamples: Int
    }

    public static let silentPeak: Float = 0.01
    public static let clipLevel: Float = 0.999

    public static func problem(in samples: [Float]) -> Problem? {
        guard !samples.isEmpty else { return .empty }
        var audible = false
        for sample in samples {
            guard sample.isFinite else { return .invalidSamples }
            if abs(sample) > silentPeak { audible = true }
        }
        return audible ? nil : .silent
    }

    public static func measure(_ samples: [Float], sampleRate: Int) -> Measurements {
        var peak: Float = 0
        var squares: Double = 0
        var clipped = 0
        for sample in samples where sample.isFinite {
            let level = abs(sample)
            peak = max(peak, level)
            squares += Double(sample * sample)
            if level >= clipLevel { clipped += 1 }
        }
        return Measurements(
            seconds: sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0, peak: peak,
            rms: samples.isEmpty ? 0 : Float((squares / Double(samples.count)).squareRoot()), clippedSamples: clipped)
    }

    public static func similarity(_ a: [Float], _ b: [Float]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }
        var dot = 0.0, left = 0.0, right = 0.0
        for i in 0..<count {
            dot += Double(a[i]) * Double(b[i])
            left += Double(a[i]) * Double(a[i])
            right += Double(b[i]) * Double(b[i])
        }
        guard left > 0, right > 0 else { return 0 }
        return dot / (left * right).squareRoot()
    }
}
