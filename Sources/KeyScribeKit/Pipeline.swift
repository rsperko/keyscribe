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
    public init(text: String) { self.text = text }
}

// Each stage is a command with a forward `apply` and an inverse `post` (design.md §4.2.1). The
// host runs `forward` (apply, in position/order), then the optional LLM + validation gate on the
// text, then `reverse` (post, in STRICT REVERSE) — so a stage that tokenizes in `apply` and
// restores in `post` unwinds LIFO by construction. One-way text stages leave `post` at its default
// no-op. Verbatim sorts before the text stages (its content is protected from them too); redaction
// sorts after (it tokenizes the fully-transformed text just before the LLM).
public protocol PipelineStage: Sendable {
    var position: StagePosition { get }
    var order: Int { get }
    func apply(_ context: inout PipelineContext)
    func post(_ context: inout PipelineContext)
}

public extension PipelineStage {
    func post(_ context: inout PipelineContext) {}
}

// A stage that issues nonce tokens (verbatim / redaction). The host collects these for the
// post-LLM validation gate.
public protocol TokenizingStage {
    var issuedTokens: [String] { get }
}

public struct Pipeline {
    private let stages: [any PipelineStage]

    public init(_ stages: [any PipelineStage]) {
        self.stages = stages.sorted {
            $0.position != $1.position ? $0.position < $1.position : $0.order < $1.order
        }
    }

    public func forward(_ context: inout PipelineContext) {
        for stage in stages { stage.apply(&context) }
    }

    public func reverse(_ context: inout PipelineContext) {
        for stage in stages.reversed() { stage.post(&context) }
    }

    // Forward-only convenience for a pipeline with no tokenization (apply all, no LLM bracket).
    public func run(_ text: String) -> String {
        var context = PipelineContext(text: text)
        forward(&context)
        return context.text
    }

    // Tokens issued during `forward`, across every tokenizing stage — fed to the validation gate.
    public var issuedTokens: [String] {
        stages.compactMap { $0 as? any TokenizingStage }.flatMap { $0.issuedTokens }
    }
}
