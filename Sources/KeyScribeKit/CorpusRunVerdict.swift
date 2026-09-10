import Foundation

public struct CorpusRunVerdict: Equatable, Sendable {
    public enum ClipOutcome: Equatable, Sendable {
        case transcribed
        case missingAudio
        case failed(String)
    }

    public struct Failure: Equatable, Sendable {
        public let engine: String?
        public let clip: String?
        public let reason: String

        public init(engine: String?, clip: String?, reason: String) {
            self.engine = engine
            self.clip = clip
            self.reason = reason
        }

        public var line: String {
            let subject = [engine, clip].compactMap { $0 }.joined(separator: " ")
            return subject.isEmpty ? "FAIL — \(reason)" : "FAIL — \(subject): \(reason)"
        }
    }

    public let engineIds: [String]
    public let clipIds: [String]
    private var loadFailures: [String: String] = [:]
    private var outcomes: [String: [String: ClipOutcome]] = [:]

    public init(engineIds: [String], clipIds: [String]) {
        self.engineIds = engineIds
        self.clipIds = clipIds
    }

    public mutating func recordLoadFailure(engine: String, reason: String) {
        loadFailures[engine] = reason
    }

    public mutating func record(engine: String, clip: String, outcome: ClipOutcome) {
        outcomes[engine, default: [:]][clip] = outcome
    }

    public var failures: [Failure] {
        if engineIds.isEmpty { return [Failure(engine: nil, clip: nil, reason: "no engine ran")] }
        if clipIds.isEmpty { return [Failure(engine: nil, clip: nil, reason: "the manifest lists no clips")] }
        var failures: [Failure] = []
        for engine in engineIds {
            if let reason = loadFailures[engine] {
                failures.append(Failure(engine: engine, clip: nil, reason: "failed to load: \(reason)"))
                continue
            }
            for clip in clipIds {
                switch outcomes[engine]?[clip] {
                case .transcribed: continue
                case .missingAudio: failures.append(Failure(engine: engine, clip: clip, reason: "audio missing"))
                case .failed(let reason):
                    failures.append(Failure(engine: engine, clip: clip, reason: "transcription failed: \(reason)"))
                case nil: failures.append(Failure(engine: engine, clip: clip, reason: "not run"))
                }
            }
        }
        return failures
    }

    public var failedEngineIds: Set<String> { Set(failures.compactMap(\.engine)) }

    public var passed: Bool { failures.isEmpty }
}

public enum CorpusRunOutcome: Equatable, Sendable {
    case invocationError(String)
    case ran(CorpusRunVerdict)

    public var exitCode: Int32 {
        switch self {
        case .invocationError: 2
        case .ran(let verdict): verdict.passed ? 0 : 1
        }
    }
}
