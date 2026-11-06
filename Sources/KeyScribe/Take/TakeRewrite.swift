import Foundation
import KeyScribeKit
import os

struct RewriteDetails {
    let connectionId: String
    let connection: String
    let model: String
    let redaction: Bool
    let contextCategories: [String]
    let prompt: String
    let fellBack: Bool
    // nil when the rewrite succeeded or when fallback was pre-committed before the cause was known (selection
    // path).
    var fallbackReason: String? = nil
    var received: String? = nil
    var reasoning: ReasoningOutcome? = nil
    var skippedAfterMs: Double? = nil
}

@MainActor
final class TakeRewrite {
    struct Checkpoint {
        let startedAt: DispatchTime
        let localText: String
        let issuedTokens: [String]
        let details: RewriteDetails
    }

    struct Finished {
        let milliseconds: Double
        let modelOutput: String?
        let fallbackReason: String?
    }

    struct Result {
        let text: String
        let ok: Bool
        let details: RewriteDetails
        // nil when the take was cancelled before the reply: a skip already froze the timing and owns the record.
        let finished: Finished?
    }

    private let log = Logger(subsystem: "com.keyscribe.app", category: "dictation")
    private let client: any LLMClient
    private let permits: @Sendable (Connection) -> Bool
    private let hud: HUDChannel
    var deadlineSecondsOverride: Double?

    init(client: any LLMClient, permits: @escaping @Sendable (Connection) -> Bool, hud: HUDChannel) {
        self.client = client
        self.permits = permits
        self.hud = hud
    }

    // `checkpoint` is dictation only: it is what the escape hatch inserts, so a selection never offers its
    // captured text back.
    func rewrite(
        _ take: TakeText, localText: String, mode: Mode, connection: Connection, instructionTokens: [String] = [],
        request build: () async -> RewriteRequestBuilder.Assembled,
        checkpoint: ((Checkpoint) -> Void)?
    ) async -> Result {
        if mode.commands.privacy {
            log.debug("redaction: \(take.payload.issuedTokens.count, privacy: .public) span(s) tokenized before cloud rewrite")
        }
        // Built BEFORE the HUD render so the "shared context" badges reflect what actually crossed — a probe
        // that returned nil must not display "Preceding text shared" (KS-02).
        let request = await build()
        let pending = RewriteDetails(
            connectionId: connection.id, connection: connection.name, model: connection.model,
            redaction: mode.commands.privacy,
            contextCategories: request.contextCategories, prompt: request.promptForHistory, fellBack: true)
        // `.rewriting` holds key focus, so a render after cancel already hid the HUD re-takes it on a machine
        // state that is no longer cancellable, and the panel swallows keystrokes meant for the user's app (X-2).
        if Task.isCancelled { return Result(text: localText, ok: false, details: pending, finished: nil) }

        let start = DispatchTime.now()
        checkpoint?(Checkpoint(startedAt: start, localText: localText, issuedTokens: take.payload.issuedTokens, details: pending))
        hud.present(.rewriting(
            connection: connection.name, mode: mode.name, redacted: mode.commands.privacy,
            contextCategories: request.contextCategories, offerLocalTranscript: false))

        let outcome = await RewriteService(
            client: client, permits: permits,
            deadlineSeconds: deadlineSecondsOverride ?? RewriteService.defaultDeadlineSeconds
        ).rewrite(
            payload: take.payload, inputs: request.inputs, connection: request.sized,
            allowedTokens: instructionTokens, prompt: request.prompt)
        if Task.isCancelled { return Result(text: localText, ok: false, details: pending, finished: nil) }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        let gateApproved: String
        let finished: Finished
        let received: String?
        switch outcome {
        case .rewritten(let out, let raw):
            gateApproved = out; received = raw
            finished = Finished(milliseconds: milliseconds, modelOutput: out, fallbackReason: nil)
        case .localFallback(let local, let reason, let raw):
            gateApproved = local; received = raw
            log.notice("rewrite fell back to local: \(reason ?? "unknown", privacy: .public)")
            finished = Finished(milliseconds: milliseconds, modelOutput: nil, fallbackReason: reason)
        }
        let fellBack = finished.modelOutput == nil
        let details = RewriteDetails(
            connectionId: connection.id, connection: connection.name, model: connection.model,
            redaction: mode.commands.privacy,
            contextCategories: request.contextCategories, prompt: request.promptForHistory, fellBack: fellBack,
            fallbackReason: finished.fallbackReason, received: received,
            reasoning: fellBack ? nil : await client.reasoningOutcome(for: request.sized))
        return Result(text: take.finish(gateApproved), ok: !fellBack, details: details, finished: finished)
    }
}
