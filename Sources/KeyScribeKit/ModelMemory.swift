import Foundation

// Whether a speech model's resident footprint is comfortable on the machine it is looking at. The fit is
// hardware-relative on purpose: the same model can be comfortable on a 32 GB Mac and heavy on an 8 GB one,
// so the verdict is computed against the running Mac's installed RAM at display time, never a fixed cutoff.
public enum ModelFitVerdict: Equatable, Sendable {
    case comfortable
    case heavy
}

public enum ModelMemory {
    // Flag "heavy" once a model would claim ~40% of installed RAM. 0.40 (not 0.50) so an 8 GB Mac warns on
    // the 3+ GB engines (Whisper Turbo, Qwen 1.7B) — which genuinely crowd the OS + a browser there — while a
    // 16 GB+ Mac stays quiet for every shipping model. These are background models sharing RAM with the
    // user's real work, so under-warning is worse than a gentle heads-up.
    public static let heavyFraction = 0.40

    public static func verdict(
        peakBytes: Int64, physicalBytes: UInt64, heavyFraction: Double = ModelMemory.heavyFraction
    ) -> ModelFitVerdict {
        // Unknown footprint or RAM → don't cry wolf.
        guard peakBytes > 0, physicalBytes > 0 else { return .comfortable }
        return Double(peakBytes) >= Double(physicalBytes) * heavyFraction ? .heavy : .comfortable
    }
}
