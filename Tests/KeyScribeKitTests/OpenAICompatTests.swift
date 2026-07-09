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
        #expect(OpenAIAPIError.parse(body: #"{"error":{"message":"x"}}"#) == nil)
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
