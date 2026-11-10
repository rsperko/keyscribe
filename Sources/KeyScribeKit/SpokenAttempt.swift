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

        public init(
            normalizedText: String?, phonemes: String, predictedDurations: [Int32], stageMilliseconds: [Detail], sampleRate: Int,
            measurements: SpokenAudioCheck.Measurements
        ) {
            self.normalizedText = normalizedText
            self.phonemes = phonemes
            self.predictedDurations = predictedDurations
            self.stageMilliseconds = stageMilliseconds
            self.sampleRate = sampleRate
            self.measurements = measurements
        }
    }

    public let id: String
    public let at: Date
    public let text: String
    public let voice: String
    public var reader: Reader?
    public var macOSReason: String?
    public var audio: Data?
    public var synthesis: Synthesis?
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
        if let synthesis {
            let measured = synthesis.measurements
            lines += [
                "",
                "Normalized text: \(synthesis.normalizedText ?? "(none)")",
                "Phonemes: \(synthesis.phonemes)",
                "Predicted durations: \(synthesis.predictedDurations.map(String.init).joined(separator: " "))",
                "Stage timings (ms): \(synthesis.stageMilliseconds.map { "\($0.label) \($0.value)" }.joined(separator: ", "))",
                String(
                    format: "Audio: %.2f s at %d Hz, peak %.3f, RMS %.3f, clipped samples %d", measured.seconds, synthesis.sampleRate,
                    measured.peak, measured.rms, measured.clippedSamples),
            ]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

public struct SpokenAttemptLog: Sendable {
    public static let keptFor: TimeInterval = 60 * 60
    public static let maxAttempts = 10
    public static let maxAudioBytes = 64 * 1024 * 1024

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
