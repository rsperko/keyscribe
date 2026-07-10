import Testing
@testable import KeyScribeKit

// ReturnSuffix recognizes a terminal `<CR>` on an already-expanded regex template, stripping it and
// requesting a Return submit. `\<CR>` escapes to literal text; a non-terminal unescaped `<CR>` is
// invalid (agent_notes/replace_with_return).
struct ReturnSuffixTests {
    @Test func terminalMarkerRequestsReturn() {
        #expect(ReturnSuffix.parse("/resume<CR>") == .init(template: "/resume", submit: .return))
    }

    @Test func whitespaceBeforeMarkerIsStripped() {
        #expect(ReturnSuffix.parse("/resume <CR>") == .init(template: "/resume", submit: .return))
        #expect(ReturnSuffix.parse("/resume\t<CR>") == .init(template: "/resume", submit: .return))
    }

    @Test func captureTemplateKeepsRefs() {
        #expect(ReturnSuffix.parse("/$1<CR>") == .init(template: "/$1", submit: .return))
    }

    @Test func escapedMarkerIsLiteralNoReturn() {
        #expect(ReturnSuffix.parse(#"/resume\<CR>"#) == .init(template: "/resume<CR>", submit: nil))
        #expect(ReturnSuffix.parse(#"\<CR>"#) == .init(template: "<CR>", submit: nil))
    }

    // A literal backslash survives as a pair through ReplacementEscapes, so `\\<CR>` (even run) is a real
    // marker with a literal backslash before it.
    @Test func doubledBackslashIsRealMarker() {
        #expect(ReturnSuffix.parse(#"\\<CR>"#) == .init(template: #"\\"#, submit: .return))
    }

    @Test func markerOnlyYieldsEmptyTemplate() {
        #expect(ReturnSuffix.parse("<CR>") == .init(template: "", submit: .return))
    }

    @Test func nonTerminalMarkerIsInvalid() {
        #expect(ReturnSuffix.parse("foo<CR>bar") == nil)
        #expect(ReturnSuffix.parse("<CR>tail") == nil)
    }

    @Test func noMarkerPassesThrough() {
        #expect(ReturnSuffix.parse("/resume") == .init(template: "/resume", submit: nil))
        #expect(ReturnSuffix.parse("") == .init(template: "", submit: nil))
    }
}
