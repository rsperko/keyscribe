import Foundation

public struct SpokenAttempt: Sendable, Equatable, Identifiable {
    public enum Reader: String, Sendable, Equatable {
        case natural
        case macOS = "macos"

        public var label: String {
            switch self {
            case .natural: "natural voice"
            case .macOS: "macOS voice"
            }
        }
    }

    public enum Playback: String, Sendable, Equatable {
        case preparing, playing, finished, interrupted, failed
    }

    public struct Detail: Sendable, Equatable {
        public var label: String
        public var value: String
        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct Synthesis: Sendable, Equatable {
        public var normalizedText: String?
        public var phonemes: String
        public var predictedDurations: [Int32]
        public var stageMilliseconds: [Detail]
        public var sampleRate: Int
        public var measurements: SpokenAudioCheck.Measurements
        public var conditions: RenderConditions?

        public init(
            normalizedText: String?, phonemes: String, predictedDurations: [Int32], stageMilliseconds: [Detail], sampleRate: Int,
            measurements: SpokenAudioCheck.Measurements, conditions: RenderConditions? = nil
        ) {
            self.conditions = conditions
            self.normalizedText = normalizedText
            self.phonemes = phonemes
            self.predictedDurations = predictedDurations
            self.stageMilliseconds = stageMilliseconds
            self.sampleRate = sampleRate
            self.measurements = measurements
        }
    }

    public struct Segment: Sendable, Equatable {
        public var text: String
        public var synthesis: Synthesis
        public init(text: String, synthesis: Synthesis) {
            self.text = text
            self.synthesis = synthesis
        }
    }

    public static let determinismNote =
        "The natural voice takes no random seed, so another render of the same phonemes, voice, route and model files differs only through how the hardware computed it. A render far from the others points at the hardware or the conditions above, not at chance."

    public let id: String
    public let at: Date
    public let text: String
    public let voice: String
    public var reader: Reader?
    public var macOSReason: String?
    public var audio: Data?
    public var segments: [Segment] = []
    public var check: SpokenReplyCheck.Result?
    public var synthesis: Synthesis? { segments.first?.synthesis }
    public var normalizedText: String? {
        let parts = segments.compactMap(\.synthesis.normalizedText)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
    public var details: [Detail] = []
    public var notes: [String] = []
    public var playback: Playback = .preparing

    public init(id: String = UUID().uuidString, at: Date, text: String, voice: String) {
        self.id = id
        self.at = at
        self.text = text
        self.voice = voice
    }

    nonisolated(unsafe) private static let timestamp = ISO8601DateFormatter()

    public var diagnosticLine: String {
        let detail = { (label: String) in details.first { $0.label == label }?.value ?? "unknown" }
        var parts = [
            Self.timestamp.string(from: at), "read-by=\(reader?.rawValue ?? "none")", "playback=\(playback.rawValue)",
            "voice=\(voice)",
        ]
        if let macOSReason { parts.append("reason=\(macOSReason)") }
        parts += ["route=\(detail("Voice route"))", "output=\(detail("Output"))", "fluidaudio=\(detail("FluidAudio"))"]
        return parts.joined(separator: "  ")
    }

    public func report(appName: String) -> String {
        var lines = [
            "Spoken reply report",
            "The audio beside this report is what \(appName) generated and handed to the speaker, not a recording of what played.",
            "",
            "When: \(Self.timestamp.string(from: at))",
            "Text read: \(text)",
            "Voice: \(voice)",
            "Read by: \(reader.map { $0 == .macOS ? "\($0.label)\(macOSReason.map { " (\($0))" } ?? "")" : $0.label } ?? "nothing")",
            "Playback: \(playback.rawValue)",
        ]
        lines += details.map { "\($0.label): \($0.value)" }
        lines += notes.map { "Note: \($0)" }
        if let check { lines.append(Self.checkLine(check)) }
        for (index, segment) in segments.enumerated() {
            let synthesis = segment.synthesis
            let measured = synthesis.measurements
            lines += [
                "",
                segments.count > 1 ? "Sentence \(index + 1) of \(segments.count): \(segment.text)" : "Sentence: \(segment.text)",
                "Normalized text: \(synthesis.normalizedText ?? "(none)")",
                "Phonemes: \(synthesis.phonemes)",
                "Predicted durations: \(synthesis.predictedDurations.map(String.init).joined(separator: " "))",
                "Stage timings (ms): \(synthesis.stageMilliseconds.map { "\($0.label) \($0.value)" }.joined(separator: ", "))",
                String(
                    format: "Audio: %.2f s at %d Hz, peak %.3f, RMS %.3f, clipped samples %d", measured.seconds, synthesis.sampleRate,
                    measured.peak, measured.rms, measured.clippedSamples),
            ]
            lines += (synthesis.conditions?.details ?? []).map { "\($0.label): \($0.value)" }
        }
        if !segments.isEmpty { lines += ["", Self.determinismNote] }
        return lines.joined(separator: "\n") + "\n"
    }

    private static let checkPrefix = "Check of the generated audio by speech recognition"

    static func checkLine(_ check: SpokenReplyCheck.Result) -> String {
        "\(checkPrefix)\(check.checkerName.map { " (\($0))" } ?? ""): \(check.summary), error rate "
            + String(format: "%.2f", check.errorRate) + " · heard: \(check.heard)"
    }

    public static func report(_ saved: String, checked check: SpokenReplyCheck.Result) -> String {
        let kept = saved.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.hasPrefix(checkPrefix) }
        return kept.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n\n" + checkLine(check) + "\n"
    }
}

public struct SpokenAttemptLog: Sendable {
    public static let keptFor: TimeInterval = 60 * 60
    public static let maxAttempts = 10
    public static let maxAudioBytes = maxAttempts * 30 * 24_000 * 2

    public private(set) var attempts: [SpokenAttempt] = []
    private var kept: Set<String> = []

    public init() {}

    public mutating func begin(_ attempt: SpokenAttempt) {
        attempts.removeAll { !kept.contains($0.id) }
        attempts.append(attempt)
        trim(now: attempt.at)
    }

    public mutating func update(_ id: String, now: Date, _ change: (inout SpokenAttempt) -> Void) {
        guard let index = attempts.firstIndex(where: { $0.id == id }) else { return }
        change(&attempts[index])
        trim(now: now)
    }

    public mutating func keep(_ id: String) {
        guard attempts.contains(where: { $0.id == id }) else { return }
        kept.insert(id)
    }

    public mutating func release(_ id: String) {
        kept.remove(id)
    }

    public mutating func discard(_ ids: some Sequence<String>) {
        let gone = Set(ids)
        attempts.removeAll { gone.contains($0.id) }
        kept.subtract(gone)
    }

    public func attempt(_ id: String, now: Date) -> SpokenAttempt? {
        attempts.first { $0.id == id && now.timeIntervalSince($0.at) < Self.keptFor }
    }

    public var nextExpiry: Date? { attempts.map(\.at).min().map { $0 + Self.keptFor } }

    public mutating func expire(now: Date) {
        trim(now: now)
    }

    private mutating func trim(now: Date) {
        attempts.removeAll { now.timeIntervalSince($0.at) >= Self.keptFor }
        while attempts.count > Self.maxAttempts
            || (attempts.count > 1 && attempts.reduce(0, { $0 + ($1.audio?.count ?? 0) }) > Self.maxAudioBytes)
        {
            attempts.removeFirst()
        }
        kept.formIntersection(attempts.map(\.id))
    }
}
