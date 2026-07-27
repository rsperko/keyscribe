import Testing
@testable import KeyScribeKit

// Field facts are content-free affordances derived from the focused element's AX role. v1 claims only
// what a role states unambiguously: a text field is single-line, a text area is multi-line; anything
// else (web areas, custom views, unknown roles) stays nil rather than guessed.
struct FieldFactsTests {
    @Test func textFieldIsSingleLine() {
        let facts = FieldFacts.derive(role: "AXTextField")
        #expect(facts.singleLine == true)
        #expect(facts.plainText == nil)
    }

    @Test func textAreaIsMultiLine() {
        let facts = FieldFacts.derive(role: "AXTextArea")
        #expect(facts.singleLine == false)
        #expect(facts.plainText == nil)
    }

    @Test func unknownOrMissingRolesClaimNothing() {
        #expect(FieldFacts.derive(role: "AXWebArea") == FieldFacts(singleLine: nil, plainText: nil))
        #expect(FieldFacts.derive(role: "AXGroup") == FieldFacts(singleLine: nil, plainText: nil))
        #expect(FieldFacts.derive(role: nil) == FieldFacts(singleLine: nil, plainText: nil))
    }
}
