import Foundation

// Canonical pipeline positions (design.md §4.2.1). STT, LLM, and the validation gate are not
// stages — they are fixed steps the host runs between these positions. Tokenize/restore land in
// M6; the positions exist now so those stages slot in without reordering anything.
public enum StagePosition: Int, Comparable, Sendable {
    case preSTT = 0
    case verbatimMark = 20
    case postSTTText = 30
    case postSTTMark = 40
    case assemble = 50
    case preLLM = 60
    case postLLM = 80
    case restore = 100
    case insertion = 110

    public static func < (lhs: StagePosition, rhs: StagePosition) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// Conventional order indices within a position. Explicit, never incidental (design.md §4.2.1):
// live edits run before replacements so a replacement can't rewrite spoken-command output.
public enum StageOrder {
    public static let liveEdits = 0
    public static let replacements = 10
    public static let numbers = 20
    public static let fuzzy = 30
}

public struct PipelineContext: Sendable {
    public var text: String
    // Set by the replacements stage when one rule owned the entire utterance: the verbatim value to
    // insert, bypassing the LLM and the trailing/trim shaping. nil on the normal path. `Pipeline.forward`
    // surfaces it on the returned `TokenizedPayload`.
    public var bareReplacement: String?
    public init(text: String) { self.text = text }
}

// Each stage is a command with a forward `apply` and an inverse `post` (design.md §4.2.1). The
// host runs `forward` (apply, in position/order), then the optional LLM + validation gate on the
// text, then `reverse` (post, in STRICT REVERSE) — so a stage that tokenizes in `apply` and
// restores in `post` unwinds LIFO by construction. One-way text stages leave `post` at its default
// no-op. Verbatim sorts before the text stages (its content is protected from them too); redaction
// sorts after (it tokenizes the fully-transformed text just before the LLM).
//
// `issuedTokens` is part of the contract (default empty): a stage that tokenizes returns its nonces
// here so the host's post-LLM validation gate sees them. Making it a protocol member, not an
// optional downcast, means a tokenizing stage cannot silently escape the gate — a dropped redaction
// token would leak the protected span (AGENTS.md footgun).
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

// The result of a forward pipeline pass: the fully forward-transformed (tokenized) text plus the exact
// nonces issued during it. ONLY `Pipeline.forward` can mint one (the initializer is module-internal, so
// the app target that wires the gate cannot construct it), which is what makes the validation gate's
// token set unforgeable: a caller can no longer hand the gate an empty `[String]` that silently disables
// the exactly-once check. `restore` consumes the gate-approved text, so "gate runs on the forward output
// before restore" stays structural, not conventional (design.md §4.2).
public struct TokenizedPayload: Sendable {
    public let text: String
    public let issuedTokens: [String]
    // Set when one replacement rule owned the entire utterance (whole-utterance replacement): the
    // verbatim value to insert, bypassing the LLM and the trailing/trim shaping. nil on the normal path.
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

    // Forward pass: apply every stage in (position, order). Returns the sealed payload — the tokenized
    // text plus the exact nonces issued — which is the only token set the validation gate accepts.
    public func forward(_ text: String) -> TokenizedPayload {
        var context = PipelineContext(text: text)
        for stage in stages { stage.apply(&context) }
        return TokenizedPayload(
            text: context.text,
            issuedTokens: stages.flatMap { $0.issuedTokens },
            bareReplacement: context.bareReplacement)
    }

    // Restore pass: run every stage's `post` in STRICT REVERSE over `text` (the gate-approved LLM output,
    // or the tokenized text on fallback). Unwinds tokenization LIFO by construction.
    public func restore(_ text: String) -> String {
        var context = PipelineContext(text: text)
        for stage in stages.reversed() { stage.post(&context) }
        return context.text
    }
}
