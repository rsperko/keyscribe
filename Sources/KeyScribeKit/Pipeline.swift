import Foundation

// Canonical pipeline positions. STT, LLM, and the validation gate are fixed host steps that run between
// these stage positions.
public enum StagePosition: Int, Comparable, Sendable {
    case verbatimMark = 20
    case postSTTText = 30
    case postSTTMark = 40

    public static func < (lhs: StagePosition, rhs: StagePosition) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// Explicit order within a position; live edits run before replacements so replacements cannot rewrite
// spoken-command output.
public enum StageOrder {
    public static let liveEdits = 0
    public static let replacements = 10
    public static let numbers = 20
    public static let fuzzy = 30
}

public struct PipelineContext: Sendable {
    public var text: String
    public var bareReplacement: String?
    public init(text: String) { self.text = text }
}

// Stages run forward by position/order, then restore in strict reverse so tokenizers unwind LIFO.
// Tokenizing stages must expose their issued nonces through `issuedTokens`; the host's validation gate
// uses that exact set before restore.
public protocol PipelineStage: Sendable {
    var position: StagePosition { get }
    var order: Int { get }
    func apply(_ context: inout PipelineContext)
    func post(_ context: inout PipelineContext)
    var issuedTokens: [String] { get }
}

public extension PipelineStage {
    func post(_ context: inout PipelineContext) {}
    var issuedTokens: [String] { [] }
}

// Only `Pipeline.forward` can mint this payload, so the app target cannot forge an empty token set and
// silently bypass the validation gate.
public struct TokenizedPayload: Sendable {
    public let text: String
    public let issuedTokens: [String]
    public let bareReplacement: String?

    init(text: String, issuedTokens: [String], bareReplacement: String? = nil) {
        self.text = text
        self.issuedTokens = issuedTokens
        self.bareReplacement = bareReplacement
    }
}

public struct Pipeline: Sendable {
    private let stages: [any PipelineStage]

    public init(_ stages: [any PipelineStage]) {
        self.stages = stages.sorted {
            $0.position != $1.position ? $0.position < $1.position : $0.order < $1.order
        }
    }

    public func forward(_ text: String) -> TokenizedPayload {
        var context = PipelineContext(text: text)
        for stage in stages { stage.apply(&context) }
        return TokenizedPayload(
            text: context.text,
            issuedTokens: stages.flatMap { $0.issuedTokens },
            bareReplacement: context.bareReplacement)
    }

    public func restore(_ text: String) -> String {
        var context = PipelineContext(text: text)
        for stage in stages.reversed() { stage.post(&context) }
        return context.text
    }
}
