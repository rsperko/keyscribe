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

    // A proxy fronting another backend (e.g. one wrapping Gemini) can return the error object inside a
    // single-element top-level array instead of a plain object. Accept both.
    @Test func parsesArrayWrappedError() {
        let wrapped = #"[{"error":{"code":400,"message":"Invalid value for 'reasoning_effort': 'none'."}}]"#
        let error = OpenAIAPIError.parse(body: wrapped)
        #expect(error?.code == "400")
        #expect(error?.message?.contains("reasoning_effort") == true)
        // And it feeds remediation exactly like the plain-object shape.
        #expect(remediatedAdaptations(.default(for: .openai), for: error!)?.includeReasoningEffort == false)
    }

    // A proxy fronting a non-OpenAI backend rejects a param with a plain 400: no machine-readable
    // code/param, only a prose message. It must still parse so remediation can scan the message.
    @Test func parsesMessageOnlyError() {
        let body = #"{"error":{"message":"Invalid value for 'reasoning_effort': 'none'. Supported: high, low, medium, minimal."}}"#
        let error = OpenAIAPIError.parse(body: body)
        #expect(error?.code == nil)
        #expect(error?.param == nil)
        #expect(error?.message?.contains("reasoning_effort") == true)
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

    // The core downstream bug: a proxy rejected reasoning_effort = "none" with a generic 400 (no
    // structured param/code), so the structured path missed it and every rewrite silently fell back.
    // Message-scanning recovers by dropping the offending param the message names.
    @Test func remediatesReasoningEffortFromMessageOnly400() {
        let start = RequestAdaptations.default(for: .openai)
        let error = OpenAIAPIError(
            code: nil, param: nil,
            message: "Invalid value for 'reasoning_effort': 'none'. Supported values: high, low, medium, minimal.")
        let after = remediatedAdaptations(start, for: error)
        #expect(after?.includeReasoningEffort == false)
        #expect(after?.includeTemperature == true)
        // Once dropped, the same message can't strip it again — the loop terminates.
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

    // "max_tokens" is not a substring of "max_completion_tokens", and the remap is guarded on currently
    // being on the max_tokens field — so a message about max_completion_tokens can't flip an
    // already-remapped request back the wrong way.
    @Test func messageScanDoesNotRemapWhenAlreadyOnCompletionTokens() {
        var current = RequestAdaptations.default(for: .openaiCompatible)
        current.tokenLimitField = .maxCompletionTokens
        let error = OpenAIAPIError(code: nil, param: nil, message: "max_completion_tokens value is invalid")
        #expect(remediatedAdaptations(current, for: error) == nil)
    }

    // When the message names two params we sent, drop the most-likely-intended one first (reasoning_effort
    // before temperature); the loop revisits and handles the other on the next pass if it recurs.
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

    // A message-only system-role rejection (no structured `messages[N].role` param) folds system into user,
    // the same generic-400 shape the reasoning_effort bug had.
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

    // The two-token guard: a lone "system" or a lone "role" must NOT fold — an incidental mention isn't a
    // role rejection.
    @Test func messageScanRoleFoldRequiresBothTokens() {
        let start = RequestAdaptations.default(for: .openaiCompatible)
        #expect(remediatedAdaptations(start, for: OpenAIAPIError(code: nil, param: nil, message: "The system is busy, try again.")) == nil)
        #expect(remediatedAdaptations(start, for: OpenAIAPIError(code: nil, param: nil, message: "Your account role lacks access.")) == nil)
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
