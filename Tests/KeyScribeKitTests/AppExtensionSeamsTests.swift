import XCTest
@testable import KeyScribeKit

final class AppExtensionSeamsTests: XCTestCase {
    @MainActor
    final class FakeUpdater: AppUpdater {
        var finishedCount = 0
        var performedCount = 0
        var onUpdateAvailable: (@MainActor () -> Void)?
        func dictationDidFinish() { finishedCount += 1 }
        func performUpdate() { performedCount += 1 }
    }

    @MainActor
    func testUpdaterSeamReportsAndActs() {
        let updater = FakeUpdater()
        var reported = false
        updater.onUpdateAvailable = { reported = true }

        updater.dictationDidFinish()
        updater.dictationDidFinish()
        XCTAssertEqual(updater.finishedCount, 2)

        updater.onUpdateAvailable?()
        XCTAssertTrue(reported)

        updater.performUpdate()
        XCTAssertEqual(updater.performedCount, 1)
    }

    func testOnlyProductionInjectsBundledUpdater() {
        XCTAssertTrue(AppVariant.production.injectsBundledUpdater)
        XCTAssertTrue(AppVariant(bundleID: "com.keyscribe.app").injectsBundledUpdater)
        XCTAssertFalse(AppVariant.dev.injectsBundledUpdater)
        XCTAssertFalse(AppVariant(bundleID: "com.keyscribe.app.dev").injectsBundledUpdater)
        XCTAssertFalse(AppVariant(bundleID: "com.acme.customvoice", bundleName: "CustomVoice").injectsBundledUpdater)
    }

    struct FakeImporter: LegacyConfigImporter {
        final class Box { var imported: URL? }
        let box = Box()
        func importIfNeeded(into supportDir: URL) throws { box.imported = supportDir }
    }

    func testLegacyImporterSeamReceivesSupportDir() throws {
        let importer = FakeImporter()
        let dir = URL(fileURLWithPath: "/tmp/keyscribe-test-support", isDirectory: true)
        try importer.importIfNeeded(into: dir)
        XCTAssertEqual(importer.box.imported, dir)
    }
}
