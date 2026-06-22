import Foundation

// What a model install is doing right now, plus a 0...1 completion guess. `fraction` is exact while
// a download reports bytes and a coarse guesstimate during the opaque download/compile steps that
// expose no native progress; `phase` is the human-readable status shown next to the bar. Lives in
// KeyScribeKit so it can be part of the SpeechEngine protocol's load(progress:) requirement.
public struct ModelLoadProgress: Sendable {
    public let phase: String
    public let fraction: Double

    public init(phase: String, fraction: Double) {
        self.phase = phase
        self.fraction = min(max(fraction, 0), 1)
    }
}
