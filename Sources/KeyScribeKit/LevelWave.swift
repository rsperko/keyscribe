import Foundation

// Maps a most-recent-last level history onto `count` symmetric bar heights for the HUD's red-wave
// recording visual (UX2 phase 6a). Newest sample is the center bar; older samples mirror outward
// (the ▂▅▇▅▂ shape), so a spike propagates from center to edge over successive calls. Pure logic.
public enum LevelWave {
    public static func bars(history: [Float], count: Int = 5) -> [Float] {
        guard count > 0 else { return [] }
        let clamped = history.map { Float(min(1, max(0, $0))) }
        let center = count / 2
        var bars = [Float](repeating: 0, count: count)
        // ring 0 = newest sample, ring 1 = mean of the next-older pair, etc. Missing history pads with 0.
        for ring in 0...center {
            let value = ringValue(clamped, ring: ring)
            bars[center - ring] = value
            bars[center + ring] = value
        }
        return bars
    }

    private static func ringValue(_ history: [Float], ring: Int) -> Float {
        // ring 0 consumes the single newest sample; each subsequent ring averages the next pair back.
        if ring == 0 {
            return history.last ?? 0
        }
        let hiIndex = history.count - 1 - (2 * ring - 1)
        let loIndex = history.count - 1 - (2 * ring)
        let samples = [hiIndex, loIndex].compactMap { $0 >= 0 && $0 < history.count ? history[$0] : nil }
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0, +) / Float(samples.count)
    }
}
