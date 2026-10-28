import Foundation
import Testing
@testable import KeyScribeKit

struct ReasoningTests {
    @Test func recommendedReasoningNamesItsPurposeWithoutChangingItsStoredValue() {
        #expect(ReasoningReport.preferenceName(.lowestAvailable) == "Recommended — least reasoning")
        #expect(ReasoningPreference.lowestAvailable.storedValue == "lowest")
    }

    @Test func lowestLadderStartsAtTheLowestRungPerProvider() {
        #expect(ReasoningLadder.rungs(for: .lowestAvailable, provider: .openaiCompatible)
            == [.effort("none"), .effort("minimal"), .effort("low")])
        #expect(ReasoningLadder.rungs(for: .lowestAvailable, provider: .openai)
            == [.effort("none"), .effort("minimal"), .effort("low")])
        #expect(ReasoningLadder.rungs(for: .lowestAvailable, provider: .anthropic)
            == [.anthropicThinking("disabled"), .anthropicThinking("between_tools"), .anthropicEffort("low", adaptive: false)])
        #expect(ReasoningLadder.rungs(for: .lowestAvailable, provider: .gemini)
            == [.geminiLevel("minimal"), .geminiLevel("low"), .geminiBudget(0), .geminiBudget(128)])
        #expect(ReasoningLadder.rungs(for: .modelDefault, provider: .openai).isEmpty)
        #expect(ReasoningLadder.initialShape(for: .modelDefault, provider: .gemini) == .modelDefault(exhausted: false))
    }

    @Test func anExplicitLevelHasOnlyTranslationRungs() {
        #expect(ReasoningLadder.rungs(for: .level("high"), provider: .openaiCompatible) == [.effort("high")])
        #expect(ReasoningLadder.rungs(for: .level("medium"), provider: .anthropic) == [.anthropicEffort("medium", adaptive: true)])
        #expect(ReasoningLadder.rungs(for: .level("low"), provider: .gemini) == [.geminiLevel("low"), .geminiBudget(1024)])
        #expect(ReasoningLadder.rungs(for: .level("xhigh"), provider: .gemini) == [.geminiLevel("xhigh")])
    }

    @Test func anExplicitLevelRejectedRefusesInsteadOfStepping() {
        let step = ReasoningLadder.step(
            from: .rung(.effort("medium")), preference: .level("medium"), provider: .openaiCompatible,
            rejection: .value(listed: ["low", "high", "max"]))
        #expect(step == .refuse(level: "medium"))
        let unknown = ReasoningLadder.step(
            from: .rung(.effort("high")), preference: .level("high"), provider: .openai, rejection: .unknownField)
        #expect(unknown == .refuse(level: "high"))
    }

    @Test func anExplicitGeminiLevelTranslatesToABudgetWhenTheLevelFieldIsUnknown() {
        let step = ReasoningLadder.step(
            from: .rung(.geminiLevel("low")), preference: .level("low"), provider: .gemini, rejection: .unknownField)
        #expect(step == .to(.rung(.geminiBudget(1024))))
        let refused = ReasoningLadder.step(
            from: .rung(.geminiBudget(1024)), preference: .level("low"), provider: .gemini, rejection: .value(listed: []))
        #expect(refused == .refuse(level: "low"))
    }

    @Test func unsupportedValueStepsToTheNextRung() {
        let step = ReasoningLadder.step(
            from: .rung(.effort("none")), preference: .lowestAvailable, provider: .openaiCompatible,
            rejection: .value(listed: []))
        #expect(step == .to(.rung(.effort("minimal"))))
    }

    @Test func unknownParameterBecomesUnknownNotOff() {
        let step = ReasoningLadder.step(
            from: .rung(.effort("none")), preference: .lowestAvailable, provider: .openaiCompatible,
            rejection: .unknownField)
        #expect(step == .to(.unknown))
        #expect(ReasoningLadder.step(
            from: .unknown, preference: .lowestAvailable, provider: .openaiCompatible, rejection: .unknownField) == nil)
    }

    @Test func geminiUnknownFieldSkipsToBudgetRungs() {
        let step = ReasoningLadder.step(
            from: .rung(.geminiLevel("minimal")), preference: .lowestAvailable, provider: .gemini, rejection: .unknownField)
        #expect(step == .to(.rung(.geminiBudget(0))))
        let fromBudget = ReasoningLadder.step(
            from: .rung(.geminiBudget(0)), preference: .lowestAvailable, provider: .gemini, rejection: .value(listed: []))
        #expect(fromBudget == .to(.rung(.geminiBudget(128))))
    }

    @Test func aListedSupportedValueJumpsToTheLowestOneAboveTheCurrentRung() {
        let step = ReasoningLadder.step(
            from: .rung(.effort("none")), preference: .lowestAvailable, provider: .openaiCompatible,
            rejection: .value(listed: ["max", "high", "low"]))
        #expect(step == .to(.rung(.effort("low"))))
        let echoOnly = ReasoningLadder.step(
            from: .rung(.effort("none")), preference: .lowestAvailable, provider: .openaiCompatible,
            rejection: .value(listed: ["none"]))
        #expect(echoOnly == .to(.rung(.effort("minimal"))))
        let aboveTheLadder = ReasoningLadder.step(
            from: .rung(.effort("low")), preference: .lowestAvailable, provider: .openaiCompatible,
            rejection: .value(listed: ["medium", "high"]))
        #expect(aboveTheLadder == .to(.rung(.effort("medium"))))
    }

    @Test func anExhaustedLadderIsModelDefaultExhausted() {
        let step = ReasoningLadder.step(
            from: .rung(.effort("low")), preference: .lowestAvailable, provider: .openaiCompatible,
            rejection: .value(listed: []))
        #expect(step == .to(.modelDefault(exhausted: true)))
        #expect(ReasoningLadder.step(
            from: .modelDefault(exhausted: true), preference: .lowestAvailable, provider: .openaiCompatible,
            rejection: .value(listed: [])) == nil)
    }

    @Test func listedValuesAreReadFromTheListNotFromTheEchoedValue() {
        #expect(ReasoningLadder.listedEffortValues(
            in: "Invalid value for 'reasoning_effort': 'none'. Supported values: high, low, medium, minimal.")
            == ["high", "low", "medium", "minimal"])
        #expect(ReasoningLadder.listedEffortValues(
            in: "400 INVALID_ARGUMENT: Invalid reasoning_effort: minimal. Valid values are: high, low, medium, none")
            == ["high", "low", "medium", "none"])
        #expect(ReasoningLadder.listedEffortValues(in: "Invalid value for 'reasoning_effort': 'none'.") == ["none"])
        #expect(ReasoningLadder.listedEffortValues(in: "reasoning_effort not supported").isEmpty)
    }

    @Test func messagesClassifyAsAnUnknownFieldOrARejectedValue() {
        #expect(ReasoningLadder.classify(message: "Unrecognized request argument supplied: reasoning_effort") == .unknownField)
        #expect(ReasoningLadder.classify(message: "reasoning_effort not supported") == .unknownField)
        #expect(ReasoningLadder.classify(
            message: "Unknown name \"thinkingLevel\" at 'generation_config.thinking_config': Cannot find field.")
            == .unknownField)
        #expect(ReasoningLadder.classify(message: "messages.thinking: Extra inputs are not permitted") == .unknownField)
        #expect(ReasoningLadder.classify(message: "reasoning_effort must be one of low, high, max")
            == .value(listed: ["low", "high", "max"]))
        #expect(ReasoningLadder.classify(message: "Reasoning is mandatory for this endpoint and cannot be disabled.")
            == .value(listed: []))
    }

    @Test func headroomFollowsTheShape() {
        func tokens(_ shape: ReasoningShape, honored: Bool = true, hint: Bool = false, ceiling: Int? = nil) -> Int {
            ReasoningHeadroom.outputTokens(base: 2048, shape: shape, honored: honored, reasoningModelHint: hint, ceiling: ceiling)
        }
        #expect(tokens(.rung(.effort("none"))) == 2048)
        #expect(tokens(.rung(.effort("none")), honored: false) == 8192)
        #expect(tokens(.rung(.effort("none")), hint: true) == 8192)
        #expect(tokens(.rung(.effort("minimal"))) == 8192)
        #expect(tokens(.rung(.anthropicThinking("between_tools"))) == 8192)
        #expect(tokens(.modelDefault(exhausted: false)) == 8192)
        #expect(tokens(.unknown) == 8192)
        #expect(tokens(.unknown, ceiling: 4096) == 4096)
        #expect(ReasoningHeadroom.outputTokens(
            base: 20_000, shape: .unknown, honored: true, reasoningModelHint: false, ceiling: nil) == 26_144)
    }

    @Test func headroomSaturatesInsteadOfOverflowing() {
        #expect(ReasoningHeadroom.outputTokens(
            base: Int.max - 10, shape: .unknown, honored: true, reasoningModelHint: false, ceiling: nil) == Int.max)
        #expect(ReasoningHeadroom.outputTokens(
            base: Int.max, shape: .unknown, honored: true, reasoningModelHint: false, ceiling: 32_000) == 32_000)
    }

    @Test func tokenLimitCapParsesServerCeilings() {
        #expect(TokenLimitCap.parse(message: "max_tokens must be less than or equal to 4096") == 4096)
        #expect(TokenLimitCap.parse(
            message: "max_tokens: 100000 > 64000, which is the maximum allowed number of output tokens for claude-x")
            == 64000)
        #expect(TokenLimitCap.parse(message: "max_completion_tokens is too large: at most 16384 is supported") == 16384)
        #expect(TokenLimitCap.parse(message: "This model's maximum context length is 32768 tokens.") == nil)
        #expect(TokenLimitCap.parse(message: "temperature must be at most 2") == nil)
    }

    @Test func verdictSeparatesLimitBeforeAnswerFromTruncationAndRequiresEvidenceForReasoningCopy() {
        let reasoned = ReplyUsage(outputTokens: 2048, reasoningTokens: 2048)
        #expect(ReplyLimit.verdict(limitHit: true, hasVisibleText: false, usage: reasoned) == .limitBeforeAnswer(reasoningEvidence: true))
        #expect(ReplyLimit.verdict(limitHit: true, hasVisibleText: false, usage: ReplyUsage()) == .limitBeforeAnswer(reasoningEvidence: false))
        #expect(ReplyLimit.verdict(limitHit: true, hasVisibleText: false, usage: nil) == .limitBeforeAnswer(reasoningEvidence: false))
        #expect(ReplyLimit.verdict(limitHit: true, hasVisibleText: false, usage: ReplyUsage(hadReasoningContent: true))
            == .limitBeforeAnswer(reasoningEvidence: true))
        #expect(ReplyLimit.verdict(limitHit: true, hasVisibleText: true, usage: reasoned) == .truncatedAnswer)
        #expect(ReplyLimit.verdict(limitHit: false, hasVisibleText: false, usage: nil) == .empty)
        #expect(ReplyLimit.verdict(limitHit: false, hasVisibleText: true, usage: nil) == .ok)
    }

    @Test func usageParsesOpenAIOpenRouterAnthropicAndGeminiShapes() {
        let chat = ReplyUsage.openAIChat([
            "choices": [["message": ["content": NSNull(), "reasoning_content": "thinking about it"]]],
            "usage": ["completion_tokens": 2048, "completion_tokens_details": ["reasoning_tokens": 2048]],
        ])
        #expect(chat == ReplyUsage(outputTokens: 2048, reasoningTokens: 2048, hadReasoningContent: true))

        let router = ReplyUsage.openAIChat(["choices": [["message": ["content": "", "reasoning": "plan"]]]])
        #expect(router.hadReasoningContent)
        #expect(!ReplyUsage.openAIChat(["choices": [["message": ["content": "ok"]]]]).showsReasoning)

        let responses = ReplyUsage.openAIResponses([
            "output": [["type": "reasoning", "summary": []]],
            "usage": ["output_tokens": 10, "output_tokens_details": ["reasoning_tokens": 0]],
        ])
        #expect(!responses.showsReasoning)

        let anthropic = ReplyUsage.anthropic([
            "content": [["type": "thinking", "thinking": ""]],
            "usage": ["output_tokens": 100, "output_tokens_details": ["thinking_tokens": 100]],
        ])
        #expect(anthropic == ReplyUsage(outputTokens: 100, reasoningTokens: 100, hadReasoningContent: true))

        let gemini = ReplyUsage.gemini([
            "candidates": [["content": ["parts": [["text": "plan", "thought": true]]]]],
            "usageMetadata": ["thoughtsTokenCount": 2000, "candidatesTokenCount": 48],
        ])
        #expect(gemini == ReplyUsage(outputTokens: 2048, reasoningTokens: 2000, hadReasoningContent: true))
    }

    @Test func legacyKeysMapAndPreserveXhighAndMax() {
        #expect(ReasoningPreference(legacyEffort: "none") == .lowestAvailable)
        #expect(ReasoningPreference(legacyEffort: "xhigh") == .level("xhigh"))
        #expect(ReasoningPreference(legacyEffort: "max") == .level("max"))
        #expect(ReasoningPreference(legacyEffort: "LOW") == .level("low"))
        #expect(ReasoningPreference(legacyEffort: "") == nil)
        #expect(ReasoningPreference(legacyEffort: nil) == nil)
        #expect(ReasoningPreference(legacyGeminiLevel: "minimal") == .lowestAvailable)
        #expect(ReasoningPreference(legacyGeminiLevel: "high") == .level("high"))
        #expect(ReasoningPreference(storedValue: "model_default") == .modelDefault)
        #expect(ReasoningPreference(storedValue: "lowest") == .lowestAvailable)
        for preference in [ReasoningPreference.lowestAvailable, .modelDefault, .level("xhigh")] {
            #expect(ReasoningPreference(storedValue: preference.storedValue) == preference)
        }
    }

    @Test func reasoningOutcomeNamesWhereTheLadderLanded() {
        func resolve(_ preference: ReasoningPreference, _ shape: ReasoningShape, _ evidence: ReasoningEvidence) -> ReasoningOutcome {
            ReasoningOutcome.resolve(preference: preference, shape: shape, evidence: evidence)
        }
        #expect(resolve(.lowestAvailable, .rung(.effort("none")), .none).summary == "Off")
        #expect(resolve(.lowestAvailable, .rung(.effort("low")), .unreported).summary == "Low — the lowest this model accepts")
        #expect(resolve(.level("xhigh"), .rung(.effort("xhigh")), .unreported).summary == "Extra high")
        #expect(resolve(.modelDefault, .modelDefault(exhausted: false), .unreported).summary == "Model default")
        let exhausted = resolve(.lowestAvailable, .modelDefault(exhausted: true), .unreported)
        #expect(exhausted.summary == "Model default — no lower level was accepted")
        #expect(exhausted.deservesNotice)
        let reasonedAnyway = resolve(.lowestAvailable, .unknown, .reasoned)
        #expect(reasonedAnyway.summary == "Couldn't be set — the model reasoned on its own")
        #expect(reasonedAnyway.deservesNotice)
        let ignored = resolve(.lowestAvailable, .rung(.effort("none")), .reasoned)
        #expect(ignored.summary == "Not honored — the model reasoned anyway")
        #expect(ignored.deservesNotice)
        #expect(!resolve(.lowestAvailable, .rung(.effort("low")), .unreported).deservesNotice)
    }

    @Test func aRemovedControlIsReportedUnlessTheServiceShowsNoReasoning() {
        let unconfirmed = ReasoningOutcome.resolve(preference: .lowestAvailable, shape: .unknown, evidence: .unreported)
        #expect(unconfirmed.summary == "Couldn't be set — the model decides")
        #expect(unconfirmed.deservesNotice)
        let plainModel = ReasoningOutcome.resolve(preference: .lowestAvailable, shape: .unknown, evidence: .none)
        #expect(plainModel.summary == "Not adjustable — the model reported no reasoning")
        #expect(!plainModel.deservesNotice)
    }

    @Test func anAcceptedOffIsOnlyCalledOffWhenTheServiceConfirmsIt() {
        let unconfirmed = ReasoningOutcome.resolve(preference: .lowestAvailable, shape: .rung(.effort("none")), evidence: .unreported)
        #expect(unconfirmed.summary == "Off — requested; the service doesn't confirm it")
        #expect(!unconfirmed.deservesNotice)
        #expect(ReasoningOutcome.resolve(preference: .lowestAvailable, shape: .rung(.effort("none")), evidence: .none).summary == "Off")
    }

    @Test func anUnenforcedSettingIsNotGuaranteedUnlessTheReplyConfirmsOff() {
        let low = ReasoningOutcome.resolve(
            preference: .lowestAvailable, shape: .rung(.effort("low")), evidence: .reasoned, enforced: false)
        #expect(low.kind == .unenforced)
        #expect(low.summary == "Low requested — not guaranteed; the service may ignore it")
        #expect(low.deservesNotice)
        #expect(ReasoningOutcome.resolve(
            preference: .lowestAvailable, shape: .rung(.effort("none")), evidence: .unreported, enforced: false).kind == .unenforced)
        #expect(ReasoningOutcome.resolve(
            preference: .lowestAvailable, shape: .rung(.effort("none")), evidence: .none, enforced: false).kind == .off)
        #expect(ReasoningOutcome.resolve(
            preference: .lowestAvailable, shape: .rung(.effort("none")), evidence: .reasoned, enforced: false).kind == .notHonored)
    }

    @Test func replyEvidenceNeedsAnExplicitZeroToConfirmNoReasoning() {
        #expect(ReplyUsage(outputTokens: 40).evidence == .unreported)
        #expect(ReplyUsage(outputTokens: 40, reasoningTokens: 0).evidence == .none)
        #expect(ReplyUsage(outputTokens: 40, reasoningTokens: 12).evidence == .reasoned)
        #expect(ReplyUsage(outputTokens: 40, reasoningTokens: 0, hadReasoningContent: true).evidence == .reasoned)
        #expect(ReasoningEvidence.reasoned.merged(with: .none) == .reasoned)
        #expect(ReasoningEvidence.unreported.merged(with: .none) == .none)
        #expect(ReasoningEvidence.none.merged(with: .unreported) == .none)
    }

    @Test func noticesNameTheServiceInAShortHeadingAndAPlainExplanation() {
        let outcome = ReasoningOutcome(kind: .notSettable)
        let notice = outcome.notice(service: "Work proxy", model: "kimi-k3")
        #expect(notice?.contains("Work proxy") == true)
        #expect(notice?.contains("kimi-k3") == true)
        #expect(ReasoningOutcome(kind: .lowestAccepted, level: "low").notice(service: "S", model: "m") == nil)
    }

    @Test func openRouterMetadataNamesLevelsMandatoryReasoningAndTheOutputCeiling() {
        let kimi = ModelReasoningSupport.openRouter([
            "id": "moonshotai/kimi-k3",
            "supported_parameters": ["reasoning", "max_tokens"],
            "reasoning": ["supported_efforts": ["max", "high", "low"], "mandatory": true],
            "top_provider": ["max_completion_tokens": 32768],
        ])
        #expect(kimi == ModelReasoningSupport(levels: ["low", "high", "max"], canTurnOff: false, maxOutputTokens: 32768))

        let plain = ModelReasoningSupport.openRouter(["id": "x", "supported_parameters": ["temperature"]])
        #expect(plain?.levels == [])
        #expect(plain?.canTurnOff == true)

        let anyLevel = ModelReasoningSupport.openRouter([
            "id": "y", "supported_parameters": ["reasoning"], "reasoning": ["supported_efforts": NSNull(), "mandatory": false],
        ])
        #expect(anyLevel?.levels == nil)
        #expect(anyLevel?.canTurnOff == true)

        #expect(ModelReasoningSupport.openRouter(["id": "gpt-4o", "object": "model"]) == nil)
    }

    @Test func anthropicAndGeminiMetadataAreReadWhereTheyArePublished() {
        let sonnet = ModelReasoningSupport.anthropic([
            "id": "claude-sonnet-5-5",
            "capabilities": ["thinking": ["types": ["disabled": ["supported": false], "between_tools": ["supported": true]]]],
        ])
        #expect(sonnet?.canTurnOff == true)
        let fable = ModelReasoningSupport.anthropic([
            "id": "claude-fable-5-1",
            "capabilities": ["thinking": ["types": ["disabled": ["supported": false]]]],
        ])
        #expect(fable?.canTurnOff == false)
        #expect(ModelReasoningSupport.anthropic(["id": "claude-haiku-4-5"]) == nil)

        let gemini = ModelReasoningSupport.gemini(["name": "models/gemini-3", "outputTokenLimit": 65536])
        #expect(gemini?.maxOutputTokens == 65536)
        #expect(gemini?.publishesReasoning == false)
    }

    @Test func pickerCaptionSaysWhenSupportIsUnverifiedOrMandatory() {
        #expect(ReasoningChoices.caption(support: nil).contains("doesn't list supported levels"))
        #expect(ReasoningChoices.caption(support: ModelReasoningSupport(maxOutputTokens: 1)).contains("doesn't list supported levels"))
        #expect(ReasoningChoices.caption(support: ModelReasoningSupport(levels: ["low"], canTurnOff: false)).contains("always uses some reasoning"))
        #expect(ReasoningChoices.options(support: ModelReasoningSupport(levels: ["low"]), current: .level("max"))
            == [.lowestAvailable, .level("low"), .level("max"), .modelDefault])
    }
}
