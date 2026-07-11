import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

@MainActor
struct GeneralPanePointerTests {
    // The "Change in Modes…" pointer selects the Direct mode and routes to the Modes pane. Drives the
    // production helper the SwiftUI closure calls, not a hand-copied duplicate of its effect.
    @Test func openPlainDictationSelectsDirectAndRoutesToModes() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-general-pointer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: support.appendingPathComponent("modes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let repository = ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support))
        let modes = ModesSettingsModel(repository: repository)
        let navigation = SettingsNavigationModel()
        navigation.destination = .general
        modes.selectedID = nil

        PlainDictationPointer.open(modes: modes, navigation: navigation)

        #expect(modes.selectedID == Mode.directId)
        #expect(navigation.destination == .modes)
    }
}
