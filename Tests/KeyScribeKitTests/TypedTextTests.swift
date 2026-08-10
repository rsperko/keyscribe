import Testing
@testable import KeyScribeKit

struct TypedTextTests {
    private func rejoined(_ chunks: [[UInt16]]) -> String {
        String(decoding: chunks.flatMap { $0 }, as: UTF16.self)
    }

    private func endsOnAHighSurrogate(_ chunk: [UInt16]) -> Bool {
        guard let last = chunk.last else { return false }
        return (0xD800...0xDBFF).contains(last)
    }

    @Test func emptyTextProducesNoChunks() {
        #expect(TypedText.keyEventChunks("").isEmpty)
    }

    @Test func plainTextPostsOneCharacterPerEvent() {
        let chunks = TypedText.keyEventChunks("hello there")
        #expect(chunks.map(\.count) == Array(repeating: 1, count: 11))
        #expect(rejoined(chunks) == "hello there")
    }

    @Test func aMultiUnitGraphemeClusterStaysInOneEvent() {
        let family = "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let chunks = TypedText.keyEventChunks("hi " + family)
        #expect(chunks.map(\.count) == [1, 1, 1, 11])
        #expect(rejoined(chunks) == "hi " + family)
    }

    @Test func aGraphemeLargerThanOneEventIsSplitRatherThanTruncated() {
        let text = "a" + String(repeating: "\u{0301}", count: 30)
        let chunks = TypedText.keyEventChunks(text)
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.count <= TypedText.maxUnitsPerKeyEvent })
        #expect(rejoined(chunks) == text)
    }

    @Test func anOversizedGraphemeBreaksBeforeAHighSurrogate() {
        let joined = "\u{1F469}\u{200D}\u{1F469}"
        let chunks = TypedText.keyEventChunks(joined, maxUnits: 4)
        #expect(chunks.map(\.count) == [3, 2])
        #expect(rejoined(chunks) == joined)
    }

    @Test(arguments: [
        "",
        "hello",
        String(repeating: "a", count: 45),
        String(repeating: "\u{1F3A4}", count: 15),
        "a" + String(repeating: "\u{0301}", count: 30),
        "caf\u{00E9} \u{2014} na\u{00EF}ve \u{1F3A4} ok",
        String(repeating: "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", count: 5),
        String(repeating: "swift dictation ", count: 20),
    ]) func everyChunkIsPostableAndTheTextRoundTrips(text: String) {
        let chunks = TypedText.keyEventChunks(text)
        #expect(chunks.allSatisfy { !$0.isEmpty })
        #expect(chunks.allSatisfy { $0.count <= TypedText.maxUnitsPerKeyEvent })
        #expect(chunks.allSatisfy { !endsOnAHighSurrogate($0) })
        #expect(rejoined(chunks) == text)
        #expect(chunks.count >= text.count)
    }
}
