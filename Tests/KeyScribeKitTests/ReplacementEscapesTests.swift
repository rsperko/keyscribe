import Testing
@testable import KeyScribeKit

struct ReplacementEscapesTests {
    @Test func expandsNewlineTabCarriageReturn() {
        #expect(ReplacementEscapes.expandTemplate(#"\n"#) == "\n")
        #expect(ReplacementEscapes.expandTemplate(#"\t"#) == "\t")
        #expect(ReplacementEscapes.expandTemplate(#"\r"#) == "\r")
        #expect(ReplacementEscapes.expandTemplate(#"```\n"#) == "```\n")
        #expect(ReplacementEscapes.expandTemplate(#"a\tb\nc"#) == "a\tb\nc")
    }

    @Test func escapedBackslashPassesThroughUnchanged() {
        #expect(ReplacementEscapes.expandTemplate(#"\\n"#) == #"\\n"#)
        #expect(ReplacementEscapes.expandTemplate(#"\\t"#) == #"\\t"#)
        #expect(ReplacementEscapes.expandTemplate(#"\\"#) == #"\\"#)
    }

    @Test func leavesTemplateRefsForRegexEngine() {
        #expect(ReplacementEscapes.expandTemplate(#"\$$1"#) == #"\$$1"#)
        #expect(ReplacementEscapes.expandTemplate("/$1") == "/$1")
    }

    @Test func loneTrailingBackslashIsPreserved() {
        #expect(ReplacementEscapes.expandTemplate(#"path\"#) == #"path\"#)
    }

    @Test func noBackslashIsUnchanged() {
        #expect(ReplacementEscapes.expandTemplate("plain text") == "plain text")
        #expect(ReplacementEscapes.expandTemplate("") == "")
    }
}
