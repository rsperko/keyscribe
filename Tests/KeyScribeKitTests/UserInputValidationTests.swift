import Foundation
import Testing
@testable import KeyScribeKit

@Suite struct UserInputValidationTests {
    @Test func namesRequireVisibleSingleLineTextWithinLimit() {
        #expect(UserInputValidation.nameIssue("  Daily notes  ") == nil)
        #expect(UserInputValidation.nameIssue("   ") == .empty)
        #expect(UserInputValidation.nameIssue("Daily\nnotes") == .multipleLines)
        #expect(UserInputValidation.nameIssue(String(repeating: "a", count: 257)) == .tooLong(limit: 256))
    }

    @Test func identifiersAndPhrasesRejectControlCharactersAndOversizedPastes() {
        #expect(UserInputValidation.identifierIssue("model-2026.07") == nil)
        #expect(UserInputValidation.identifierIssue("model\u{0000}name") == .controlCharacters)
        #expect(UserInputValidation.identifierIssue(String(repeating: "m", count: 513)) == .tooLong(limit: 512))
        #expect(UserInputValidation.phraseIssue("as a note") == nil)
        #expect(UserInputValidation.phraseIssue("as a\nnote") == .multipleLines)
        #expect(UserInputValidation.phraseIssue(String(repeating: "a", count: 257)) == .tooLong(limit: 256))
    }

    @Test func endpointsMustBeHTTPURLsWithoutCredentials() {
        #expect(UserInputValidation.endpointIssue("https://example.com/v1") == nil)
        #expect(UserInputValidation.endpointIssue("example.com/v1") == .invalidURL)
        #expect(UserInputValidation.endpointIssue("ftp://example.com") == .invalidURL)
        #expect(UserInputValidation.endpointIssue("https://user:pass@example.com") == .credentialsNotAllowed)
    }

    @Test func regularExpressionsHaveBoundedValidSyntax() {
        #expect(UserInputValidation.regexIssue("(?i)draft") == nil)
        #expect(UserInputValidation.regexIssue("[") == .invalidRegex)
        #expect(UserInputValidation.regexIssue(String(repeating: "a", count: 4_097)) == .tooLong(limit: 4_096))
    }
}
