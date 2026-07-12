import Foundation
import Testing
@testable import KeyScribeKit

struct ModeTemplateTests {
    private func connection(_ id: String) -> Connection {
        Connection(id: id, name: id, provider: .gemini, model: "m", keyRef: "keyscribe.llm.\(id)")
    }

    @Test func templatesArePresentationOrderedOverTheSameCatalog() {
        #expect(ModeStore.templates().map(\.id) == [
            "polish", "message", "email", "markdown", "code", "shell", "ai-prompt", "edit-selection",
        ])
        #expect(Set(ModeStore.templates().map(\.id)) == Set(ModeStore.starterModes().map(\.id)))
    }

    @Test func templateSummariesNamePhrasesForPhraseCarryingModes() {
        #expect(ModeStore.templateSummary(for: "email").contains("as an email"))
        #expect(ModeStore.templateSummary(for: "ai-prompt").contains("as prompt"))
        #expect(!ModeStore.templateSummary(for: "polish").isEmpty)
    }

    @Test func materializeAtAFreeCatalogIdIsADisabledSeed() {
        let template = ModeStore.templates().first { $0.id == "polish" }!
        let result = ModeTemplateInstantiation.materialize(template: template, existing: [], connections: [])
        guard case .seed(let mode) = result else { Issue.record("expected .seed"); return }
        #expect(mode.id == "polish")
        #expect(mode.seedId == "polish")
        #expect(mode.seedVersion == template.seedVersion)
        #expect(!mode.enabled)   // added Disabled; the user enables it after reviewing the seeded editor
    }

    @Test func materializeAtATakenCatalogIdIsASuffixedSeedlessCopy() {
        let template = ModeStore.templates().first { $0.id == "polish" }!
        let existing = [Mode(id: "polish", name: "Polish")]
        let result = ModeTemplateInstantiation.materialize(template: template, existing: existing, connections: [])
        guard case .copy(let mode) = result else { Issue.record("expected .copy"); return }
        #expect(mode.id == "polish-2")
        #expect(mode.seedId == nil)
        #expect(mode.seedVersion == nil)
        #expect(!mode.enabled)
    }

    @Test func aTriggerHeldByAnEnabledModeIsDroppedOnMaterialize() {
        let template = ModeStore.templates().first { $0.id == "polish" }!   // holds right_option
        var holder = Mode(id: "holder", name: "Holder")
        holder.enabled = true
        holder.triggerKeys = [.init(key: "right_option")]
        let result = ModeTemplateInstantiation.materialize(template: template, existing: [holder], connections: [])
        #expect(result.mode.triggerKeys.isEmpty)
    }

    @Test func aTriggerHeldOnlyByADisabledModeIsKept() {
        let template = ModeStore.templates().first { $0.id == "polish" }!
        var holder = Mode(id: "holder", name: "Holder")
        holder.enabled = false
        holder.triggerKeys = [.init(key: "right_option")]
        let result = ModeTemplateInstantiation.materialize(template: template, existing: [holder], connections: [])
        #expect(result.mode.triggerKeys == [.init(key: "right_option")])
    }

    @Test func aSingleConnectionIsPrefilledButZeroOrTwoLeaveItBlank() {
        let template = ModeStore.templates().first { $0.id == "polish" }!
        let one = ModeTemplateInstantiation.materialize(template: template, existing: [], connections: [connection("a")])
        #expect(one.mode.aiRewrite?.connection == "a")

        let none = ModeTemplateInstantiation.materialize(template: template, existing: [], connections: [])
        #expect(none.mode.aiRewrite?.connection == "")

        let two = ModeTemplateInstantiation.materialize(
            template: template, existing: [], connections: [connection("a"), connection("b")])
        #expect(two.mode.aiRewrite?.connection == "")
    }
}
