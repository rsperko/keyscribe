import Foundation

public struct TakeText: Sendable {
    public let pipeline: Pipeline
    public let payload: TokenizedPayload
    public let trimsTrailingPunctuation: Bool

    public init(_ transcript: String, pipeline: Pipeline, trimsTrailingPunctuation: Bool) {
        self.pipeline = pipeline
        self.payload = pipeline.forward(transcript)
        self.trimsTrailingPunctuation = trimsTrailingPunctuation
    }

    public var bare: BareReplacement? { payload.bareReplacement }

    public var isBlank: Bool { payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var localText: String { bare?.text ?? finish(payload.text) }

    // Before restore, so a verbatim span's own punctuation is never trimmed.
    public func finish(_ tokenized: String) -> String {
        pipeline.restore(trimsTrailingPunctuation ? OutputCleanup.trimTrailingPunctuation(tokenized) : tokenized)
    }

    public func leaksIssuedToken(_ text: String) -> Bool {
        Self.leaksIssuedToken(text, issuedTokens: payload.issuedTokens)
    }

    public static func leaksIssuedToken(_ text: String, issuedTokens: [String]) -> Bool {
        issuedTokens.contains { text.contains($0) }
    }
}
