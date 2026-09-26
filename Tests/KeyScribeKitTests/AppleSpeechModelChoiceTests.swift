import Foundation
import Testing
@testable import KeyScribeKit

struct AppleSpeechModelChoiceTests {
    @Test func aMappedLocaleTheModelListsIsCovered() {
        let covered = AppleSpeechModelChoice.coveredLocale(
            Locale(identifier: "en_US"), supported: [Locale(identifier: "de_DE"), Locale(identifier: "en_US")])
        #expect(covered == Locale(identifier: "en_US"))
    }

    @Test func aMappedLocaleTheModelDoesNotListIsNotCovered() {
        let covered = AppleSpeechModelChoice.coveredLocale(
            Locale(identifier: "nl_NL"), supported: [Locale(identifier: "en_US"), Locale(identifier: "de_DE")])
        #expect(covered == nil)
    }

    @Test func noMappedLocaleIsNotCovered() {
        #expect(AppleSpeechModelChoice.coveredLocale(nil, supported: [Locale(identifier: "en_US")]) == nil)
    }

    @Test func coverageComparesLanguageTagsNotLocaleObjects() {
        let covered = AppleSpeechModelChoice.coveredLocale(
            Locale(identifier: "zh_TW"), supported: [Locale(identifier: "zh-TW")])
        #expect(covered == Locale(identifier: "zh_TW"))
    }

    @Test func prefersAppleSpeechWhenTheMacAndLanguageSupportIt() {
        let choice = AppleSpeechModelChoice.resolve(
            speechAvailable: true, speechSupportsLocale: true, dictationSupportsLocale: true, forced: nil)
        #expect(choice == AppleSpeechModelChoice(model: .speech, reason: .preferred))
    }

    @Test func fallsBackToDictationOnAMacWithoutAppleSpeech() {
        let choice = AppleSpeechModelChoice.resolve(
            speechAvailable: false, speechSupportsLocale: true, dictationSupportsLocale: true, forced: nil)
        #expect(choice == AppleSpeechModelChoice(model: .dictation, reason: .macUnsupported))
    }

    @Test func fallsBackToDictationForALanguageAppleSpeechDoesNotCover() {
        let choice = AppleSpeechModelChoice.resolve(
            speechAvailable: true, speechSupportsLocale: false, dictationSupportsLocale: true, forced: nil)
        #expect(choice == AppleSpeechModelChoice(model: .dictation, reason: .languageUnsupported))
    }

    @Test func anUnsupportedMacOutranksAnUnsupportedLanguage() {
        let choice = AppleSpeechModelChoice.resolve(
            speechAvailable: false, speechSupportsLocale: false, dictationSupportsLocale: true, forced: nil)
        #expect(choice.reason == .macUnsupported)
    }

    @Test func forcingDictationOverridesAnAvailableAppleSpeech() {
        let choice = AppleSpeechModelChoice.resolve(
            speechAvailable: true, speechSupportsLocale: true, dictationSupportsLocale: true, forced: .dictation)
        #expect(choice == AppleSpeechModelChoice(model: .dictation, reason: .forced))
    }

    @Test func forcingAppleSpeechCannotRunItWhereItIsUnavailable() {
        let noMac = AppleSpeechModelChoice.resolve(
            speechAvailable: false, speechSupportsLocale: true, dictationSupportsLocale: true, forced: .speech)
        #expect(noMac == AppleSpeechModelChoice(model: .dictation, reason: .macUnsupported))
        let noLanguage = AppleSpeechModelChoice.resolve(
            speechAvailable: true, speechSupportsLocale: false, dictationSupportsLocale: true, forced: .speech)
        #expect(noLanguage == AppleSpeechModelChoice(model: .dictation, reason: .languageUnsupported))
    }

    @Test func forcingDictationReportsTheRealReasonWhenTheFallbackWasUnavoidable() {
        let noMac = AppleSpeechModelChoice.resolve(
            speechAvailable: false, speechSupportsLocale: true, dictationSupportsLocale: true, forced: .dictation)
        #expect(noMac == AppleSpeechModelChoice(model: .dictation, reason: .macUnsupported))
        let noLanguage = AppleSpeechModelChoice.resolve(
            speechAvailable: true, speechSupportsLocale: false, dictationSupportsLocale: true, forced: .dictation)
        #expect(noLanguage == AppleSpeechModelChoice(model: .dictation, reason: .languageUnsupported))
    }

    @Test func noModelWhenNeitherAppleModelCoversTheLanguage() {
        let choice = AppleSpeechModelChoice.resolve(
            speechAvailable: true, speechSupportsLocale: false, dictationSupportsLocale: false, forced: nil)
        #expect(choice == AppleSpeechModelChoice(model: nil, reason: .languageUnsupported))
    }

    @Test func noModelOnAnUnsupportedMacWhenDictationLacksTheLanguage() {
        let choice = AppleSpeechModelChoice.resolve(
            speechAvailable: false, speechSupportsLocale: true, dictationSupportsLocale: false, forced: nil)
        #expect(choice == AppleSpeechModelChoice(model: nil, reason: .languageUnsupported))
    }

    @Test func forcingDictationCannotRunALanguageItLacks() {
        let choice = AppleSpeechModelChoice.resolve(
            speechAvailable: true, speechSupportsLocale: true, dictationSupportsLocale: false, forced: .dictation)
        #expect(choice == AppleSpeechModelChoice(model: .speech, reason: .preferred))
    }

    @Test func appleSpeechFailingToLoadFallsBackToDictation() {
        let choice = AppleSpeechModelChoice(model: .speech, reason: .preferred)
        #expect(choice.afterSpeechFailedToLoad(dictationSupportsLocale: true)
            == AppleSpeechModelChoice(model: .dictation, reason: .speechDownloadFailed))
    }

    @Test func appleSpeechFailingToLoadHasNoFallbackWhenDictationLacksTheLanguage() {
        let choice = AppleSpeechModelChoice(model: .speech, reason: .preferred)
        #expect(choice.afterSpeechFailedToLoad(dictationSupportsLocale: false) == nil)
    }

    @Test func dictationFailingToLoadHasNothingToFallBackTo() {
        let choice = AppleSpeechModelChoice(model: .dictation, reason: .macUnsupported)
        #expect(choice.afterSpeechFailedToLoad(dictationSupportsLocale: true) == nil)
    }

    @Test func overrideIsReadFromTheEnvironment() {
        #expect(AppleSpeechModel.override(in: ["KEYSCRIBE_APPLE_MODEL": "dictation"]) == .dictation)
        #expect(AppleSpeechModel.override(in: ["KEYSCRIBE_APPLE_MODEL": "speech"]) == .speech)
        #expect(AppleSpeechModel.override(in: [:]) == nil)
    }

    @Test func anUnrecognizedOverrideIsIgnored() {
        #expect(AppleSpeechModel.override(in: ["KEYSCRIBE_APPLE_MODEL": "siri"]) == nil)
        #expect(AppleSpeechModel.override(in: ["KEYSCRIBE_APPLE_MODEL": ""]) == nil)
    }

    @Test func aCommandLineArgumentParsesCaseInsensitively() {
        #expect(AppleSpeechModel(argument: "Dictation") == .dictation)
        #expect(AppleSpeechModel(argument: "speech") == .speech)
        #expect(AppleSpeechModel(argument: "siri") == nil)
    }

    @Test func overrideIsCaseInsensitive() {
        #expect(AppleSpeechModel.override(in: ["KEYSCRIBE_APPLE_MODEL": "Dictation"]) == .dictation)
    }
}
