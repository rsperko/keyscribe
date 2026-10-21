import AppKit
import Testing
import KeyScribeKit
@testable import KeyScribeApp

@MainActor
struct HUDAppearanceStyleTests {
    @Test func systemLeavesTheInheritedAppearanceInPlace() {
        #expect(HUDAppearance.system.nsAppearance(systemIsDark: true, increaseContrast: false) == nil)
    }

    @Test func oppositeInADarkSystemPinsLight() {
        #expect(HUDAppearance.opposite.nsAppearance(systemIsDark: true, increaseContrast: false)?.name == .aqua)
    }

    @Test func oppositeInALightSystemPinsDark() {
        #expect(HUDAppearance.opposite.nsAppearance(systemIsDark: false, increaseContrast: false)?.name == .darkAqua)
    }

    @Test func pinnedAppearancesKeepIncreaseContrast() {
        #expect(HUDAppearance.appearanceName(.light, increaseContrast: true) == .accessibilityHighContrastAqua)
        #expect(HUDAppearance.appearanceName(.dark, increaseContrast: true) == .accessibilityHighContrastDarkAqua)
    }

    @Test func previewAppearanceIsReadFromItsFlag() {
        let args = ["KeyScribe", "--hud-preview", "recording", "--hud-appearance", "light"]
        #expect(HUDPreview.appearance(from: args, isDevelopmentBuild: true) == .light)
        #expect(HUDPreview.appearance(from: args, isDevelopmentBuild: false) == nil)
        #expect(HUDPreview.appearance(from: ["KeyScribe"], isDevelopmentBuild: true) == nil)
    }
}

@MainActor
struct HUDControllerAppearanceTests {
    private func panelScheme(_ hud: HUDController) -> NSAppearance.Name? {
        hud.panelAppearance?.bestMatch(from: [.aqua, .darkAqua])
    }

    @Test func theRealizedPanelTakesThePinnedAppearance() {
        let hud = HUDController()
        hud.appearance = .dark
        hud.prewarm()
        #expect(panelScheme(hud) == .darkAqua)
    }

    @Test func changingTheAppearanceRestylesAnExistingPanel() {
        let hud = HUDController()
        hud.prewarm()
        #expect(hud.panelAppearance == nil)
        hud.appearance = .light
        #expect(panelScheme(hud) == .aqua)
        hud.appearance = .system
        #expect(hud.panelAppearance == nil)
    }
}
