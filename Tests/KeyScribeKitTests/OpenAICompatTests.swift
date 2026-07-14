import Foundation
import Testing
@testable import KeyScribeKit

struct OpenAICompatTests {
    @Test func defaultsAreLegacySafePerProvider() {
        #expect(RequestAdaptations.default(for: .openai).tokenLimitField == .maxCompletionTokens)
        #expect(RequestAdaptations.default(for: .openaiCompatible).tokenLimitField == .maxTokens)
        #expect(RequestAdaptations.default(for: .anthropic).tokenLimitField == .maxTokens)
        for provider in [Connection.Provider.openai, .openaiCompatible, .anthropic, .gemini] {
            let d = RequestAdaptations.default(for: provider)
            #expect(d.includeTemperature)
            #expect(!d.foldSystemIntoUser)
            #expect(!d.indicatesReasoningModel)
        }
    }

    @Test func parsesUnsupportedMaxTokens() {
        let body = #"{"error":{"message":"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.","type":"invalid_request_error","param":"max_tokens","code":"unsupported_parameter"}}"#
        let error = OpenAIAPIError.parse(body: body)
        #expect(error?.code == "unsupported_parameter")
        #expect(error?.param == "max_tokens")
    }

    @Test func parsesBothTemperatureShapes() {
        let unsupportedValue = #"{"error":{"message":"Unsupported value: 'temperature' does not support 0.2 with this model. Only the default (1) value is supported.","type":"invalid_request_error","param":"temperature","code":"unsupported_value"}}"#
        let unsupportedParam = #"{"error":{"message":"Unsupported parameter: 'temperature' is not supported with this model.","type":"invalid_request_error","param":"temperature","code":"unsupported_parameter"}}"#
        #expect(OpenAIAPIError.parse(body: unsupportedValue)?.code == "unsupported_value")
        #expect(OpenAIAPIError.parse(body: unsupportedValue)?.param == "temperature")
        #expect(OpenAIAPIError.parse(body: unsupportedParam)?.code == "unsupported_parameter")
        #expect(OpenAIAPIError.parse(body: unsupportedParam)?.param == "temperature")
    }

    @Test func parsesRoleRejection() {
        let body = #"{"error":{"message":"Unsupported value: 'messages[0].role' does not support 'system' with this model.","type":"invalid_request_error","param":"messages[0].role","code":"unsupported_value"}}"#
        #expect(OpenAIAPIError.parse(body: body)?.param == "messages[0].role")
    }

    @Test func parseRejectsNonErrorBodies() {
        #expect(OpenAIAPIError.parse(body: nil) == nil)
        #expect(OpenAIAPIError.parse(body: "not json") == nil)
        #expect(OpenAIAPIError.parse(body: #"{"choices":[]}"#) == nil)
        #expect(OpenAIAPIError.parse(body: #"{"error":"just a string"}"#) == nil)
        #expect(OpenAIAPIError.parse(body: #"{"error":{}}"#) == nil)
        #expect(OpenAIAPIError.parse(body: #"[]"#) == nil)
        #expect(OpenAIAPIError.parse(body: #"[{"choices":[]}]"#) == nil)
    }

    // A proxy fronting another backend may wrap the error object in a single-element array instead of
    // a plain object; both must parse.
    @Test func parsesArrayWrappedError() {
        let wrapped = #"[{"error":{"code":400,"message":"Invalid value for 'reasoning_effort': 'none'."}}]"#
        let error = OpenAIAPIError.parse(body: wrapped)
        #expect(error?.code == "400")
        #expect(error?.message?.contains("reasoning_effort") == true)
        #expect(remediatedAdaptations(.default(for: .openai), for: error!)?.includeReasoningEffort == false)
    }

    // A plain-400 rejection (no machine-readable code/param, prose message only) must still parse so
    // remediation can scan the message.
    @Test func parsesMessageOnlyError() {
        let body = #"{"error":{"message":"Invalid value for 'reasoning_effort': 'none'. Supported: high, low, medium, minimal."}}"#
        let error = OpenAIAPIError.parse(body: body)
        #expect(error?.code == nil)
        #expect(error?.param == nil)
        #expect(error?.message?.contains("reasoning_effort") == true)
    }

    // A proxy can return a string-valued `error` (a bare type name) with the actionable remediation in a
    // top-level `reason` field. Parse `reason` as the message so the wire-API auto-upgrade can fire; the
    // generic `description` must not win over it, and the string `error` is kept as the code.
    @Test func parsesTopLevelReasonFromAStringErrorEnvelope() {
        let body = #"""
        {
          "error": "BadRequestError",
          "location": "proxy",
          "description": "The proxy threw an 'BadRequestError' error",
          "reason": "Model responses-only is not supported on /v1/chat/completions because it bypasses prompt caching on the first turn. Please use /v1/responses (OpenAI Responses API) instead."
        }
        """#
        let error = OpenAIAPIError.parse(body: body)
        #expect(error?.message?.contains("Please use /v1/responses") == true)
        #expect(error?.code == "BadRequestError")
        #expect(error?.indicatesRequiresResponsesAPI == true)
        #expect(error?.indicatesRequiresChatCompletionsAPI == false)
    }

    @Test func parsesIntegerCode() {
        let body = #"{"error":{"code":400,"message":"reasoning_effort not supported"}}"#
        #expect(OpenAIAPIError.parse(body: body)?.code == "400")
    }

    @Test func detectsMissingModelErrors() {
        let notFound = #"{"error":{"message":"The model `bogus` does not exist","type":"invalid_request_error","param":null,"code":"model_not_found"}}"#
        #expect(OpenAIAPIError.parse(body: notFound)?.indicatesMissingModel == true)

        let paramModel = #"{"error":{"message":"unknown model","type":"invalid_request_error","param":"model","code":null}}"#
        #expect(OpenAIAPIError.parse(body: paramModel)?.indicatesMissingModel == true)

        let unsupported = OpenAIAPIError(code: "unsupported_parameter", param: "max_tokens")
        #expect(!unsupported.indicatesMissingModel)
    }

    @Test func remediatesMaxTokensThenTemperature() {
        let start = RequestAdaptations.default(for: .openaiCompatible)
        let afterTokens = remediatedAdaptations(start, for: OpenAIAPIError(code: "unsupported_parameter", param: "max_tokens"))
        #expect(afterTokens?.tokenLimitField == .maxCompletionTokens)
        #expect(afterTokens?.includeTemperature == true)

        let afterTemp = remediatedAdaptations(afterTokens!, for: OpenAIAPIError(code: "unsupported_value", param: "temperature"))
        #expect(afterTemp?.tokenLimitField == .maxCompletionTokens)
        #expect(afterTemp?.includeTemperature == false)
        #expect(afterTemp?.indicatesReasoningModel == true)
    }

    @Test func remediatesUnsupportedReasoningEffortByDroppingIt() {
        let start = RequestAdaptations.default(for: .openai)
        let after = remediatedAdaptations(start, for: OpenAIAPIError(code: "unsupported_parameter", param: "reasoning_effort"))
        #expect(after?.includeReasoningEffort == false)
        #expect(after?.includeTemperature == true)

        #expect(remediatedAdaptations(after!, for: OpenAIAPIError(code: "unsupported_parameter", param: "reasoning_effort")) == nil)
    }

    @Test func remediatesRoleByFolding() {
        let start = RequestAdaptations.default(for: .openaiCompatible)
        let folded = remediatedAdaptations(start, for: OpenAIAPIError(code: "unsupported_value", param: "messages[0].role"))
        #expect(folded?.foldSystemIntoUser == true)
        #expect(folded?.indicatesReasoningModel == true)
    }

    @Test func remediationIsIdempotentToPreventLoops() {
        var adapt = RequestAdaptations.default(for: .openaiCompatible)
        adapt.tokenLimitField = .maxCompletionTokens
        #expect(remediatedAdaptations(adapt, for: OpenAIAPIError(code: "unsupported_parameter", param: "max_tokens")) == nil)
        adapt.includeTemperature = false
        #expect(remediatedAdaptations(adapt, for: OpenAIAPIError(code: "unsupported_value", param: "temperature")) == nil)
    }

    @Test func remediationIgnoresUnknownParamsAndCodes() {
        let start = RequestAdaptations.default(for: .openaiCompatible)
        #expect(remediatedAdaptations(start, for: OpenAIAPIError(code: "unsupported_parameter", param: "top_p")) == nil)
        #expect(remediatedAdaptations(start, for: OpenAIAPIError(code: "rate_limit_exceeded", param: "max_tokens")) == nil)
        #expect(remediatedAdaptations(start, for: OpenAIAPIError(code: nil, param: "max_tokens")) == nil)
    }

    // Regression: a proxy rejected reasoning_effort="none" via a generic 400 (no structured
    // param/code), silently breaking every rewrite. Message-scanning recovers by dropping the named param.
    @Test func remediatesReasoningEffortFromMessageOnly400() {
        let start = RequestAdaptations.default(for: .openai)
        let error = OpenAIAPIError(
            code: nil, param: nil,
            message: "Invalid value for 'reasoning_effort': 'none'. Supported values: high, low, medium, minimal.")
        let after = remediatedAdaptations(start, for: error)
        #expect(after?.includeReasoningEffort == false)
        #expect(after?.includeTemperature == true)
        // Idempotent: the same message can't strip it twice.
        #expect(remediatedAdaptations(after!, for: error) == nil)
    }

    @Test func remediatesTemperatureAndMaxTokensFromMessage() {
        let compatStart = RequestAdaptations.default(for: .openaiCompatible)
        let tempError = OpenAIAPIError(code: nil, param: nil, message: "temperature is not supported by this model")
        #expect(remediatedAdaptations(compatStart, for: tempError)?.includeTemperature == false)

        let tokenError = OpenAIAPIError(code: nil, param: nil,
            message: "'max_tokens' is not supported. Use 'max_completion_tokens' instead.")
        #expect(remediatedAdaptations(compatStart, for: tokenError)?.tokenLimitField == .maxCompletionTokens)
    }

    // Remap is guarded on currently being on max_tokens, so a message naming max_completion_tokens
    // can't flip an already-remapped request back.
    @Test func messageScanDoesNotRemapWhenAlreadyOnCompletionTokens() {
        var current = RequestAdaptations.default(for: .openaiCompatible)
        current.tokenLimitField = .maxCompletionTokens
        let error = OpenAIAPIError(code: nil, param: nil, message: "max_completion_tokens value is invalid")
        #expect(remediatedAdaptations(current, for: error) == nil)
    }

    // When a message names two sent params, drop the most-likely-intended one first
    // (reasoning_effort before temperature); the loop revisits the other if it recurs.
    @Test func messageScanDropsReasoningEffortBeforeTemperature() {
        let start = RequestAdaptations.default(for: .openai)
        let error = OpenAIAPIError(code: nil, param: nil,
            message: "unsupported: reasoning_effort and temperature are not allowed together")
        let after = remediatedAdaptations(start, for: error)
        #expect(after?.includeReasoningEffort == false)
        #expect(after?.includeTemperature == true)
    }

    // Message-scanning never strips a param we can't act on or didn't send, even if the message names it.
    @Test func messageScanIgnoresUnactionableAndAlreadyDroppedParams() {
        let start = RequestAdaptations.default(for: .openaiCompatible)
        #expect(remediatedAdaptations(start, for: OpenAIAPIError(code: nil, param: nil, message: "top_p is invalid")) == nil)
        var noTemp = start
        noTemp.includeTemperature = false
        #expect(remediatedAdaptations(noTemp, for: OpenAIAPIError(code: nil, param: nil, message: "temperature not supported")) == nil)
    }

    // A message-only system-role rejection (no structured `messages[N].role` param) folds system into
    // user — same generic-400 shape as the reasoning_effort bug.
    @Test func messageScanFoldsSystemRoleFromMessageOnly400() {
        let start = RequestAdaptations.default(for: .openaiCompatible)
        let systemRole = OpenAIAPIError(code: nil, param: nil, message: "This model does not support the 'system' role.")
        #expect(remediatedAdaptations(start, for: systemRole)?.foldSystemIntoUser == true)

        // "assistant" + "role" also folds (a model requiring the turn start at a user message).
        let assistantRole = OpenAIAPIError(code: nil, param: nil, message: "Conversation must start with a user role, not assistant.")
        #expect(remediatedAdaptations(start, for: assistantRole)?.foldSystemIntoUser == true)

        // Idempotent once folded — no loop.
        var folded = start
        folded.foldSystemIntoUser = true
        #expect(remediatedAdaptations(folded, for: systemRole) == nil)
    }

    // Requires both tokens: a lone "system" or "role" must not fold — an incidental mention isn't a
    // role rejection.
    @Test func messageScanRoleFoldRequiresBothTokens() {
        let start = RequestAdaptations.default(for: .openaiCompatible)
        #expect(remediatedAdaptations(start, for: OpenAIAPIError(code: nil, param: nil, message: "The system is busy, try again.")) == nil)
        #expect(remediatedAdaptations(start, for: OpenAIAPIError(code: nil, param: nil, message: "Your account role lacks access.")) == nil)
    }

    @Test func detectsAnEndpointThatRequiresTheResponsesAPI() {
        let signals = [
            "This model is only supported in v1/responses and not in v1/chat/completions.",
            "This is not a chat model. Did you mean to use v1/responses?",
            "Use the Responses API for this model.",
            "This model requires the responses endpoint.",
        ]
        for message in signals {
            #expect(OpenAIAPIError(code: nil, param: nil, message: message).indicatesRequiresResponsesAPI, "\(message)")
        }
        // Ordinary errors must not trip it — no false switch away from Chat Completions.
        #expect(!OpenAIAPIError(code: "model_not_found", param: nil, message: "The model `x` does not exist").indicatesRequiresResponsesAPI)
        #expect(!OpenAIAPIError(code: nil, param: "temperature", message: "Unsupported parameter: temperature").indicatesRequiresResponsesAPI)
        #expect(!OpenAIAPIError(code: nil, param: nil, message: nil).indicatesRequiresResponsesAPI)
    }

    // The canonical wrong-endpoint error names BOTH endpoints. Each direction must attribute the message to
    // the endpoint it recommends and NOT the one it rejects — otherwise the responses path could read a
    // "use responses" error as "use chat" and bounce.
    @Test func requiredAPIDetectorsAreMutuallyExclusive() {
        func err(_ m: String) -> OpenAIAPIError { OpenAIAPIError(code: nil, param: nil, message: m) }

        let useResponses = err("This is not a chat model and thus not supported in the v1/chat/completions endpoint. Did you mean to use v1/responses?")
        #expect(useResponses.indicatesRequiresResponsesAPI)
        #expect(!useResponses.indicatesRequiresChatCompletionsAPI)

        let useResponsesBoth = err("This model is only supported in v1/responses and not in v1/chat/completions.")
        #expect(useResponsesBoth.indicatesRequiresResponsesAPI)
        #expect(!useResponsesBoth.indicatesRequiresChatCompletionsAPI)

        let useChat = err("This model is only supported in v1/chat/completions and not in v1/responses.")
        #expect(useChat.indicatesRequiresChatCompletionsAPI)
        #expect(!useChat.indicatesRequiresResponsesAPI)

        let useChatType = err("This is not a responses model. Use the chat completions endpoint.")
        #expect(useChatType.indicatesRequiresChatCompletionsAPI)
        #expect(!useChatType.indicatesRequiresResponsesAPI)
    }

    @Test func cleanStripsReasoningTags() {
        #expect(ReasoningOutput.clean("<think>plan the reply</think>Hello there") == "Hello there")
        #expect(ReasoningOutput.clean("<THINK>a\nb</THINK>\n\nDone") == "Done")
        #expect(ReasoningOutput.clean("<thinking>x</thinking>Yes") == "Yes")
        #expect(ReasoningOutput.clean("<reasoning>step</reasoning>Answer") == "Answer")
        #expect(ReasoningOutput.clean("<thought>hmm</thought>Reply") == "Reply")
        #expect(ReasoningOutput.clean("no tags here") == "no tags here")
    }

    @Test func cleanReturnsNilWhenNothingRemains() {
        #expect(ReasoningOutput.clean("<think>only reasoning</think>") == nil)
        #expect(ReasoningOutput.clean("   \n  ") == nil)
        #expect(ReasoningOutput.clean("") == nil)
    }

    @Test func reasoningFloorRaisesOnlyBelowFloor() {
        #expect(reasoningSafeMaxTokens(2048) == 8192)
        #expect(reasoningSafeMaxTokens(16000) == 16000)
    }
}
