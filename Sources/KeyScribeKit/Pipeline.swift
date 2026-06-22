import Foundation

// Canonical pipeline positions (design.md §4.2.1). STT, LLM, and the validation gate are not
// stages — they are fixed steps the host runs between these positions. Tokenize/restore land in
// M6; the positions exist now so those stages slot in without reordering anything.
public enum StagePosition: Int, Comparable, Sendable {
    case preSTT = 0
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
    public static let spokenSymbols = 5
    public static let replacements = 10
    public static let numbers = 20
    public static let fuzzy = 30
}

public struct PipelineContext: Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}

public protocol PipelineStage: Sendable {
    var position: StagePosition { get }
    var order: Int { get }
    func run(_ context: inout PipelineContext)
}

public struct Pipeline {
    private let stages: [any PipelineStage]

    public init(_ stages: [any PipelineStage]) {
        self.stages = stages.sorted {
            $0.position != $1.position ? $0.position < $1.position : $0.order < $1.order
        }
    }

    public func run(_ text: String) -> String {
        var context = PipelineContext(text: text)
        for stage in stages { stage.run(&context) }
        return context.text
    }
}
