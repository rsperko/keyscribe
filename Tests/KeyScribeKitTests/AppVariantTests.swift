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
}
