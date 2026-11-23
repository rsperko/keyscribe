import Foundation
import Testing
@testable import KeyScribeApp

struct LoginItemTests {
    @Test func anInstanceWithItsOwnConfigurationFolderLeavesTheAppsLoginItemAlone() {
        #expect(!KeyScribePaths.managesLoginItem(configDirOverride: URL(fileURLWithPath: "/tmp/instance")))
    }

    @Test func theAppOnItsOwnConfigurationManagesItsLoginItem() {
        #expect(KeyScribePaths.managesLoginItem(configDirOverride: nil))
    }
}
