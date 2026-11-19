import KeyScribeKit
import Testing

struct CodexPaneTitleTests {
    let first = "019a8b2c-1234-7abc-8def-0123456789ab"
    let second = "019a8b2c-9999-7abc-8def-0123456789ab"

    @Test func aTitleShowingTheShortenedThreadIdNamesThatThread() {
        #expect(CodexPaneTitle.thread(in: "⠋ keyscribe | 019a8b2c-1234-7abc-8def-01234...", among: [first, second]) == first)
        #expect(CodexPaneTitle.thread(in: "019a8b2c-1234-7abc-8def-0123456789ab", among: [second, first]) == first)
    }

    @Test func aTitleWithNoThreadIdOrOnlyItsCommonStartNamesNone() {
        #expect(CodexPaneTitle.thread(in: "keyscribe", among: [first]) == nil)
        #expect(CodexPaneTitle.thread(in: "019a8b2c-…", among: [first, second]) == nil)
        #expect(CodexPaneTitle.thread(in: "", among: [first]) == nil)
    }

    @Test func twoThreadsTheShownPrefixCannotTellApartNameNone() {
        let twin = "019a8b2c-1234-7abc-8def-01234ffffffff"
        #expect(CodexPaneTitle.thread(in: "019a8b2c-1234-7abc-8def-01234...", among: [first, twin]) == nil)
    }

    @Test func anIdShorterThanTheShownPrefixIsNeverMatched() {
        #expect(CodexPaneTitle.thread(in: "pane abc", among: ["abc", first]) == nil)
        #expect(CodexPaneTitle.thread(in: "pane abcdef", among: ["abcdef"]) == nil)
    }
}
