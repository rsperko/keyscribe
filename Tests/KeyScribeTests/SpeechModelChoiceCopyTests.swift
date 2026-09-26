import XCTest
@testable import KeyScribeApp
import KeyScribeKit

final class SpeechModelChoiceCopyTests: XCTestCase {
    func testAppleSpeechInUseSaysSo() {
        let choice = AppleSpeechModelChoice(model: .speech, reason: .preferred)
        XCTAssertEqual(SpeechModelChoiceCopy.appleModelStatus(choice, languageName: "English"), "Using Apple Speech")
    }

    func testFallbackOnAnUnsupportedMacNamesTheMac() {
        let choice = AppleSpeechModelChoice(model: .dictation, reason: .macUnsupported)
        XCTAssertEqual(
            SpeechModelChoiceCopy.appleModelStatus(choice, languageName: "English"),
            "Using Apple Dictation (compatibility mode) — Apple Speech isn’t available on this Mac")
    }

    func testFallbackForAnUnsupportedLanguageNamesTheLanguage() {
        let choice = AppleSpeechModelChoice(model: .dictation, reason: .languageUnsupported)
        XCTAssertEqual(
            SpeechModelChoiceCopy.appleModelStatus(choice, languageName: "Icelandic"),
            "Using Apple Dictation (compatibility mode) — Apple Speech isn’t available for Icelandic")
    }

    func testNoAppleModelForTheLanguageClaimsNoModelInUse() {
        let choice = AppleSpeechModelChoice(model: nil, reason: .languageUnsupported)
        XCTAssertEqual(
            SpeechModelChoiceCopy.appleModelStatus(choice, languageName: "Icelandic"),
            "Apple Speech isn’t available for Icelandic")
    }

    func testFallbackAfterAFailedDownloadSaysSo() {
        let choice = AppleSpeechModelChoice(model: .dictation, reason: .speechDownloadFailed)
        XCTAssertEqual(
            SpeechModelChoiceCopy.appleModelStatus(choice, languageName: "English"),
            "Using Apple Dictation (compatibility mode) — Apple Speech couldn’t be downloaded yet")
    }

    func testForcedFallbackSaysItWasChosenForTesting() {
        let choice = AppleSpeechModelChoice(model: .dictation, reason: .forced)
        XCTAssertEqual(
            SpeechModelChoiceCopy.appleModelStatus(choice, languageName: "English"),
            "Using Apple Dictation (compatibility mode) — selected for testing")
    }

    func testSystemManagedLanguageCoverageIsNotACount() throws {
        let apple = try XCTUnwrap(SpeechModelCatalog.entry(for: "apple"))
        XCTAssertEqual(SpeechModelChoiceCopy.languageScope(apple), "Depends on this Mac")
    }

    func testDownloadedModelLanguageCoverageIsItsCount() throws {
        let whisper = try XCTUnwrap(SpeechModelCatalog.entry(for: "whisper"))
        let count = try XCTUnwrap(whisper.languageCount)
        XCTAssertEqual(SpeechModelChoiceCopy.languageScope(whisper), "\(count) languages")
        let english = try XCTUnwrap(SpeechModelCatalog.all.first { $0.languageCount == 1 })
        XCTAssertEqual(SpeechModelChoiceCopy.languageScope(english), "English")
    }
}
