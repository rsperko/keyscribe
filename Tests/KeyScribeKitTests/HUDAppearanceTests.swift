import Testing
@testable import KeyScribeKit

struct HUDAppearanceTests {
    @Test(arguments: [false, true])
    func systemDefersToTheSystemAppearance(_ systemIsDark: Bool) {
        #expect(HUDAppearance.system.resolved(systemIsDark: systemIsDark) == nil)
    }

    @Test(arguments: [false, true])
    func lightAndDarkIgnoreTheSystemAppearance(_ systemIsDark: Bool) {
        #expect(HUDAppearance.light.resolved(systemIsDark: systemIsDark) == .light)
        #expect(HUDAppearance.dark.resolved(systemIsDark: systemIsDark) == .dark)
    }

    @Test func oppositeInvertsTheSystemAppearance() {
        #expect(HUDAppearance.opposite.resolved(systemIsDark: true) == .light)
        #expect(HUDAppearance.opposite.resolved(systemIsDark: false) == .dark)
    }
}
