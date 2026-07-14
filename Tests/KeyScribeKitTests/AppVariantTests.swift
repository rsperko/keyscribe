import XCTest
@testable import KeyScribeKit

final class AppVariantTests: XCTestCase {
    func testProductionBundleID() {
        XCTAssertEqual(AppVariant(bundleID: "com.keyscribe.app"), .production)
    }

    func testDevBundleID() {
        XCTAssertEqual(AppVariant(bundleID: "com.keyscribe.app.dev"), .dev)
    }

    func testNilBundleIDDefaultsToProduction() {
        XCTAssertEqual(AppVariant(bundleID: nil), .production)
    }

    func testSupportFolderNames() {
        XCTAssertEqual(AppVariant.production.supportFolderName, "KeyScribe")
        XCTAssertEqual(AppVariant.dev.supportFolderName, "KeyScribeDev")
    }

    func testKeychainServicesAreDistinct() {
        XCTAssertEqual(AppVariant.production.keychainService, "com.keyscribe.llm")
        XCTAssertEqual(AppVariant.dev.keychainService, "com.keyscribe.dev.llm")
        XCTAssertNotEqual(AppVariant.production.keychainService, AppVariant.dev.keychainService)
    }

    func testModelsAreSharedAcrossVariants() {
        XCTAssertEqual(AppVariant.sharedModelsFolderName, AppVariant.production.supportFolderName)
    }

    func testOnlyProductionInjectsBundledUpdater() {
        XCTAssertTrue(AppVariant.production.injectsBundledUpdater)
        XCTAssertTrue(AppVariant(bundleID: "com.keyscribe.app").injectsBundledUpdater)
        XCTAssertFalse(AppVariant.dev.injectsBundledUpdater)
        XCTAssertFalse(AppVariant(bundleID: "com.keyscribe.app.dev").injectsBundledUpdater)
        XCTAssertFalse(AppVariant(bundleID: "com.acme.customvoice", bundleName: "CustomVoice").injectsBundledUpdater)
    }

    func testCustomBundleIDIsCustomVariant() {
        let variant = AppVariant(bundleID: "com.acme.notes", bundleName: "Acme Notes")
        XCTAssertEqual(variant, .custom(displayName: "Acme Notes", keychainService: "com.acme.notes.llm"))
        XCTAssertFalse(variant.isDev)
    }

    func testCustomVariantFallsBackToBundleIDWhenNameMissing() {
        XCTAssertEqual(AppVariant(bundleID: "com.acme.notes").displayName, "com.acme.notes")
        XCTAssertEqual(AppVariant(bundleID: "com.acme.notes", bundleName: "").displayName, "com.acme.notes")
    }

    func testCustomVariantIsIsolatedFromProductionAndDev() {
        let custom = AppVariant(bundleID: "com.acme.notes", bundleName: "Acme Notes")
        XCTAssertNotEqual(custom.supportFolderName, AppVariant.production.supportFolderName)
        XCTAssertNotEqual(custom.supportFolderName, AppVariant.dev.supportFolderName)
        XCTAssertNotEqual(custom.keychainService, AppVariant.production.keychainService)
        XCTAssertNotEqual(custom.keychainService, AppVariant.dev.keychainService)
    }

    func testProductionAndDevDetectionUnchanged() {
        XCTAssertEqual(AppVariant(bundleID: "com.keyscribe.app", bundleName: "Anything"), .production)
        XCTAssertEqual(AppVariant(bundleID: "com.keyscribe.app.dev", bundleName: "Anything"), .dev)
        XCTAssertFalse(AppVariant.production.isDev)
        XCTAssertTrue(AppVariant.dev.isDev)
    }
}
