import Foundation
import Testing
@testable import KeyScribeApp

@MainActor
struct AppDelegateLaunchAttentionTests {
    @Test func accessibilityLostSinceLastLaunchOpensPermissions() {
        #expect(AppDelegate.launchAttention(
            firstRunCompleted: true, accessibilityGranted: false, accessibilityGrantedAtLastLaunch: true) == .permissions)
    }

    @Test func noRecordedVerdictCountsAsLostSoAnUpgradedInstallIsRescuedOnce() {
        #expect(AppDelegate.launchAttention(
            firstRunCompleted: true, accessibilityGranted: false, accessibilityGrantedAtLastLaunch: nil) == .permissions)
    }

    @Test func aLaunchAlreadyWithoutAccessibilityOpensNothingDeclinedOrNot() {
        #expect(AppDelegate.launchAttention(
            firstRunCompleted: true, accessibilityGranted: false, accessibilityGrantedAtLastLaunch: false) == .none)
    }

    @Test func grantedAccessibilityOpensNothingWhateverTheTapState() {
        for previous in [true, false, nil] {
            #expect(AppDelegate.launchAttention(
                firstRunCompleted: true, accessibilityGranted: true, accessibilityGrantedAtLastLaunch: previous) == .none)
        }
    }

    @Test func onboardingOwnsAnIncompleteFirstRun() {
        for previous in [true, false, nil] {
            #expect(AppDelegate.launchAttention(
                firstRunCompleted: false, accessibilityGranted: false, accessibilityGrantedAtLastLaunch: previous) == .none)
        }
    }

    @Test func routingPersistsTheVerdictAcrossLaunchesAndPresentsOnlyOnLoss() {
        let defaults = UserDefaults(suiteName: "launch-attention-\(UUID().uuidString)")!
        var presented: [SettingsDestination] = []
        func launch(accessibilityGranted: Bool) {
            AppDelegate.routeLaunchAttention(
                firstRunCompleted: true, accessibilityGranted: accessibilityGranted, defaults: defaults
            ) { presented.append($0) }
        }

        launch(accessibilityGranted: false)
        #expect(presented == [.permissions])
        launch(accessibilityGranted: false)
        #expect(presented == [.permissions])
        launch(accessibilityGranted: true)
        #expect(presented == [.permissions])
        #expect(defaults.bool(forKey: ResetTool.accessibilityAtLastLaunchKey) == true)
        launch(accessibilityGranted: false)
        #expect(presented == [.permissions, .permissions])
    }

    @Test func routingRecordsTheVerdictEvenWhenOnboardingOwnsTheLaunch() {
        let defaults = UserDefaults(suiteName: "launch-attention-\(UUID().uuidString)")!
        var presented: [SettingsDestination] = []
        AppDelegate.routeLaunchAttention(
            firstRunCompleted: false, accessibilityGranted: true, defaults: defaults
        ) { presented.append($0) }

        #expect(presented.isEmpty)
        #expect(defaults.bool(forKey: ResetTool.accessibilityAtLastLaunchKey) == true)
    }
}
