import Foundation

// With privacy on, the spoken instruction is user content too (design.md §4.4), so it is redacted through the
// selection's own tokenizer; its tokens are allowed back, not required.
public struct SelectionText: Sendable {
    public let take: TakeText
    public let instruction: String
    public let instructionTokens: [String]

    public init(selection: String, instruction: String, liveEdits: Bool, privacy: Bool, trimsTrailingPunctuation: Bool) {
        let tokenizer = Tokenizer()
        let pipeline = TakeStages.selection(liveEdits: liveEdits, redaction: privacy ? tokenizer : nil)
        take = TakeText(selection, pipeline: pipeline, trimsTrailingPunctuation: trimsTrailingPunctuation)
        let contentTokens = tokenizer.issuedTokens.count
        self.instruction = privacy ? RedactionTokenizer.apply(instruction, into: tokenizer) : instruction
        instructionTokens = Array(tokenizer.issuedTokens.dropFirst(contentTokens))
    }
}
