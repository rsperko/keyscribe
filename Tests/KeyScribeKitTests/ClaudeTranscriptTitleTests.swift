import Foundation
import Testing
@testable import KeyScribeKit

struct ClaudeTranscriptTitleTests {
    private func tail(_ lines: [String]) -> Data { Data(lines.joined(separator: "\n").utf8) }

    @Test func theLatestGeneratedTitleIsTheTitle() {
        let data = tail([
            #"{"type":"ai-title","aiTitle":"First idea","sessionId":"s1"}"#,
            #"{"type":"user","message":{"content":"the word ai-title appears here"}}"#,
            #"{"type":"ai-title","aiTitle":"Fix terminal \"focus\"","sessionId":"s1"}"#,
            #"{"type":"assistant","message":{"content":"done"}}"#,
        ])
        #expect(ClaudeTranscriptTitle.latest(in: data) == "Fix terminal \"focus\"")
    }

    @Test func aTitleTheUserGaveWinsOverAGeneratedOne() {
        let data = tail([
            #"{"type":"custom-title","customTitle":"backend work","sessionId":"s1"}"#,
            #"{"type":"ai-title","aiTitle":"Generated later","sessionId":"s1"}"#,
        ])
        #expect(ClaudeTranscriptTitle.latest(in: data) == "backend work")
    }

    @Test func explicitNamesAndGeneratedTitlesKeepTheirProvenance() {
        let data = tail([
            #"{"type":"custom-title","customTitle":"Fix authentication retries"}"#,
            #"{"type":"ai-title","aiTitle":"Generated later"}"#,
        ])
        let titles = ClaudeTranscriptTitle.parse(in: data)
        #expect(titles.explicitName == "Fix authentication retries")
        #expect(titles.generatedTitle == "Generated later")
        #expect(titles.displayTitle == "Fix authentication retries")
        #expect(ClaudeTranscriptTitle.parse(in: tail([#"{"type":"ai-title","aiTitle":"Generated only"}"#])).explicitName == nil)
    }

    @Test func aCutOffFirstLineAndMalformedLinesAreIgnored() {
        let data = tail([
            #"le":"Cut off","sessionId":"s1"}"#,
            #"{"type":"ai-title","aiTitle":"#,
            #"{"type":"ai-title","aiTitle":"   ","sessionId":"s1"}"#,
        ])
        #expect(ClaudeTranscriptTitle.latest(in: data, startsMidLine: true) == nil)
    }

    @Test func aTitleNeverComesFromAMessageThatMerelyQuotesOne() {
        let data = tail([#"{"type":"user","message":{"content":"{\"type\":\"ai-title\",\"aiTitle\":\"Spoof\"}"}}"#])
        #expect(ClaudeTranscriptTitle.latest(in: data) == nil)
    }

    @Test func aProjectFolderIsNamedTheWayClaudeNamesIt() {
        #expect(ClaudeTranscriptTitle.projectFolder(for: "/Users/me/src/github.com/me/keyscribe") == "-Users-me-src-github-com-me-keyscribe")
        #expect(ClaudeTranscriptTitle.projectFolder(for: "/Users/me/src/.local/local_model") == "-Users-me-src--local-local_model")
    }
}
