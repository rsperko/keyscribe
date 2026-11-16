import CoreGraphics
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct CarbonHotKeysConsumedTests {
    @Test func aChordIsMatchedByItsGenericModifiersOnly() {
        #expect(CarbonHotKeys.modifiers(of: [.maskCommand, .maskAlternate]) == [.command, .option])
        #expect(CarbonHotKeys.modifiers(of: [.maskControl, .maskShift, .maskNumericPad]) == [.control, .shift])
        #expect(CarbonHotKeys.modifiers(of: []) == [])
    }
}
