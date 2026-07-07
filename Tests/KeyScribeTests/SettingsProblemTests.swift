import Testing
@testable import KeyScribe

struct SettingsProblemTests {
    @Test func noProblemsWhenAllGranted() {
        let problems = SettingsProblem.detect(
            hasConfigError: false, microphoneGranted: true,
            accessibilityGranted: true)
        #expect(problems.isEmpty)
    }

    @Test func missingPermissionFlagsThePermissionsPane() {
        let problems = SettingsProblem.detect(
            hasConfigError: false, microphoneGranted: false,
            accessibilityGranted: true)
        #expect(problems == [.microphonePermission])
        #expect(problems.first?.pane == .permissions)
    }

    @Test func accessibilityGrantedButTapInactiveNeedsRelaunch() {
        let problems = SettingsProblem.detect(
            hasConfigError: false, microphoneGranted: true,
            accessibilityGranted: true, accessibilityTapActive: false)
        #expect(problems == [.accessibilityNeedsRelaunch])
        #expect(problems.first?.pane == .permissions)
    }

    @Test func ungrantedAccessibilityOutranksRelaunch() {
        let problems = SettingsProblem.detect(
            hasConfigError: false, microphoneGranted: true,
            accessibilityGranted: false, accessibilityTapActive: false)
        #expect(problems == [.accessibilityPermission])
    }

    @Test func malformedConfigFlagsTheAdvancedPane() {
        let problems = SettingsProblem.detect(
            hasConfigError: true, microphoneGranted: true,
            accessibilityGranted: true)
        #expect(problems == [.malformedConfig])
        #expect(problems.first?.pane == .advanced)
    }

    @Test func multipleProblemsFlagBothPanes() {
        let problems = SettingsProblem.detect(
            hasConfigError: true, microphoneGranted: false,
            accessibilityGranted: false)
        #expect(Set(problems.map(\.pane)) == [.advanced, .permissions])
    }

    @Test func unusableActiveEngineFlagsSpeechModels() {
        let problems = SettingsProblem.detect(
            hasConfigError: false, microphoneGranted: true,
            accessibilityGranted: true, activeEngineUsable: false)
        #expect(problems == [.activeEngineUnavailable])
        #expect(problems.first?.pane == .speechModels)
    }

    @Test func failedModelSelfTestFlagsSpeechModels() {
        let problems = SettingsProblem.detect(
            hasConfigError: false, microphoneGranted: true,
            accessibilityGranted: true, modelSelfTestFailed: true)
        #expect(problems == [.modelSelfTestFailed])
        #expect(problems.first?.pane == .speechModels)
    }

    @Test func failedConnectionTestFlagsAIServices() {
        let problems = SettingsProblem.detect(
            hasConfigError: false, microphoneGranted: true,
            accessibilityGranted: true, aiConnectionTestFailed: true)
        #expect(problems == [.aiConnectionTestFailed])
        #expect(problems.first?.pane == .aiServices)
    }

    @Test func misconfiguredConnectionFlagsAIServices() {
        let problems = SettingsProblem.detect(
            hasConfigError: false, microphoneGranted: true,
            accessibilityGranted: true, aiConnectionMisconfigured: true)
        #expect(problems == [.aiConnectionMisconfigured])
        #expect(problems.first?.pane == .aiServices)
    }

    @Test func modeUsingFailedConnectionFlagsModesPane() {
        let problems = SettingsProblem.detect(
            hasConfigError: false, microphoneGranted: true,
            accessibilityGranted: true, modeUsesFailedConnection: true)
        #expect(problems == [.modeUsesFailedConnection])
        #expect(problems.first?.pane == .modes)
    }

    @Test func enabledModeMissingAIServiceFlagsModesPane() {
        let problems = SettingsProblem.detect(
            hasConfigError: false, microphoneGranted: true,
            accessibilityGranted: true, modeNeedsAIService: true)
        #expect(problems == [.modeNeedsAIService])
        #expect(problems.first?.pane == .modes)
    }

    @Test func keylessConnectionIsNotAProblem() {
        let problems = SettingsProblem.detect(
            hasConfigError: false, microphoneGranted: true,
            accessibilityGranted: true,
            activeEngineUsable: true, aiConnectionTestFailed: false)
        #expect(problems.isEmpty)
    }
}
