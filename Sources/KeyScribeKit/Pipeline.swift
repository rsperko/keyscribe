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

// A whole-utterance replacement: one rule owned the entire utterance, so its generated value is inserted
// verbatim (bypassing the LLM and trim/trailing). `submit` is set iff that rule's regex template ended in
// a `<CR>` marker, requesting a physical Return after the insert.
public struct BareReplacement: Sendable, Equatable {
    public let text: String
    public let submit: Mode.Submit?
    public init(text: String, submit: Mode.Submit? = nil) {
        self.text = text
        self.submit = submit
    }
}

// A whole-utterance replacement's output, split into the rule's own text and the words it captured.
public enum BareSegment: Sendable, Equatable {
    case literal(String)
    case captured(String)
}

public struct PipelineContext: Sendable {
    public var text: String
    public var bareReplacement: BareReplacement?
    public var bareSegments: [BareSegment]?
    public var firedReplacements: [ReplacementRule] = []
    public var replacementEffects: [ReplacementEffect] = []
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
    public let bareReplacement: BareReplacement?
    public let bareSegments: [BareSegment]?
    public let firedReplacements: [ReplacementRule]
    public let replacementEffects: [ReplacementEffect]

    init(
        text: String, issuedTokens: [String], bareReplacement: BareReplacement? = nil, bareSegments: [BareSegment]? = nil,
        firedReplacements: [ReplacementRule] = [], replacementEffects: [ReplacementEffect] = []
    ) {
        self.text = text
        self.issuedTokens = issuedTokens
        self.bareReplacement = bareReplacement
        self.bareSegments = bareSegments
        self.firedReplacements = firedReplacements
        self.replacementEffects = replacementEffects
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
        for stage in stages {
            let ownedBefore = context.bareReplacement != nil
            stage.apply(&context)
            // The owning rule's text is frozen, but what it captured is dictation, so the text stages after it
            // still reach those words. Tokenizers at other positions never do: the bare path skips the LLM.
            if ownedBefore, stage.position == .postSTTText, let segments = context.bareSegments {
                context.bareSegments = Self.applying(stage, toCapturesIn: segments)
            }
        }
        return TokenizedPayload(
            text: context.text,
            issuedTokens: stages.flatMap { $0.issuedTokens },
            bareReplacement: Self.rebuilt(context.bareReplacement, from: context.bareSegments),
            bareSegments: context.bareSegments,
            firedReplacements: context.firedReplacements,
            replacementEffects: context.replacementEffects)
    }

    // A capture's edge whitespace is what joins it to the rule's text or the next capture, and the text stages
    // normalize edges away, so only the words between them are handed over.
    public static func applying(_ stage: any PipelineStage, toCapturesIn segments: [BareSegment]) -> [BareSegment] {
        segments.map { segment in
            guard case .captured(let words) = segment,
                  let first = words.firstIndex(where: { !$0.isWhitespace }),
                  let last = words.lastIndex(where: { !$0.isWhitespace })
            else { return segment }
            var captured = PipelineContext(text: String(words[first...last]))
            stage.apply(&captured)
            return .captured(String(words[..<first]) + captured.text + String(words[words.index(after: last)...]))
        }
    }

    public static func joined(_ segments: [BareSegment]) -> String {
        SentinelText.neutralizeOpen(segments.map { segment in
            switch segment {
            case .literal(let s), .captured(let s): s
            }
        }.joined())
    }

    private static func rebuilt(_ bare: BareReplacement?, from segments: [BareSegment]?) -> BareReplacement? {
        guard let bare, let segments else { return bare }
        return BareReplacement(text: joined(segments), submit: bare.submit)
    }

    public func restore(_ text: String) -> String {
        var context = PipelineContext(text: text)
        for stage in stages.reversed() { stage.post(&context) }
        return context.text
    }
}
