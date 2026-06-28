import Testing
@testable import KeyScribe
@testable import KeyScribeKit

struct ModeSummaryTests {
    @Test func customChordSummaryUsesKeyboardGlyphs() {
        var mode = Mode(id: "custom", name: "Custom")
        mode.triggerKeys = [.init(key: "control+option+shift+command+m")]

        #expect(ModeSummary.whenRuns(mode, isDefault: false) == "Triggered by ⌃⌥⇧⌘M")
    }

    @Test func namedModifierKeysRemainPlainLanguage() throws {
        #expect(ModeSummary.triggerLabel(try KeyDescriptor(parsing: "right_option")) == "Right Option")
        #expect(ModeSummary.triggerLabel(try KeyDescriptor(parsing: "right_command")) == "Right Command")
    }

    @Test func hyperSummaryUsesItsModifierSymbols() throws {
        #expect(ModeSummary.triggerLabel(try KeyDescriptor(parsing: "hyper")) == "⌃⌥⇧⌘")
    }
}
