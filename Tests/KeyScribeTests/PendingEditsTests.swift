import AppKit
import Combine
import KeyScribeKit
import SwiftUI
import Testing
@testable import KeyScribeApp

@MainActor
struct PendingEditsTests {
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private final class Surroundings: ObservableObject {
        @Published var hasKey = false
        var renders = 0
    }

    private final class Saved: ObservableObject {
        @Published var text: String
        var renders = 0
        var focused = false
        init(_ text: String) { self.text = text }
    }

    private struct FieldOverSaved: View {
        @ObservedObject var saved: Saved
        let edits: PendingEdits
        @FocusState private var focused: Bool

        var body: some View {
            let _ = saved.renders += 1
            Form {
                CommittedTextField("Base URL", text: saved.text, edits: edits) { saved.text = $0 }
                    .focused($focused)
            }.formStyle(.grouped)
            .onChange(of: focused) { _, now in saved.focused = now }
        }
    }

    private struct ModelOverSaved: View {
        @ObservedObject var saved: Saved
        let edits: PendingEdits

        var body: some View {
            let _ = saved.renders += 1
            ModelComboBox(text: $saved.text, items: [], edits: edits, onCommit: {})
        }
    }

    private struct FieldBesideState: View {
        @ObservedObject var surroundings: Surroundings
        let edits: PendingEdits
        let seen: Box<Bool?>

        var body: some View {
            let hasKey = surroundings.hasKey
            let _ = surroundings.renders += 1
            Form {
                CommittedTextField("Base URL", text: "http://old/v1", edits: edits) { _ in seen.value = hasKey }
            }.formStyle(.grouped)
        }
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }

    private func host<V: View, Field: NSTextField>(_ content: V, finding type: Field.Type) throws -> (NSWindow, Field) {
        let host = NSHostingView(rootView: content.frame(width: 500, height: 200))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        var found: Field?
        _ = waitUntil {
            host.layoutSubtreeIfNeeded()
            found = field(type, in: host)
            return found != nil
        }
        return (window, try #require(found))
    }

    private func close(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private func field<T: NSTextField>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T, match.isEditable { return match }
        return view.subviews.lazy.compactMap { self.field(type, in: $0) }.first
    }

    private func type(_ text: String, into field: NSTextField, in window: NSWindow) {
        window.makeFirstResponder(field)
        let editor = field.currentEditor() as? NSTextView
        editor?.selectAll(nil)
        editor?.insertText(text, replacementRange: editor?.selectedRange() ?? NSRange(location: 0, length: 0))
    }

    private func change(_ saved: Saved, to text: String, in window: NSWindow) {
        let before = saved.renders
        saved.text = text
        rendered(saved, after: before, in: window)
    }

    private func rendered(_ saved: Saved, after before: Int, in window: NSWindow) {
        #expect(waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            return saved.renders > before
        })
    }

    private func shown(in field: NSTextField) -> String {
        field.currentEditor()?.string ?? field.stringValue
    }

    private func entry(_ commit: @escaping () -> Bool) -> PendingEdits.Entry {
        let entry = PendingEdits.Entry()
        entry.update(commit)
        return entry
    }

    @Test func everyRegisteredEditIsSavedEvenAfterOneIsRefused() {
        let edits = PendingEdits()
        var saved: [String] = []
        edits.register(entry { saved.append("a"); return false })
        edits.register(entry { saved.append("b"); return true })
        #expect(!edits.commitAll())
        #expect(saved.sorted() == ["a", "b"])
    }

    @Test func aRemovedFieldIsNotSaved() {
        let edits = PendingEdits()
        var saved = false
        let field = entry { saved = true; return true }
        edits.register(field)
        edits.remove(field)
        #expect(edits.commitAll())
        #expect(!saved)
    }

    @Test func aModelTypedButNotYetSavedIsSavedBeforeTheTest() throws {
        let edits = PendingEdits()
        let model = Box("old-model")
        var commits = 0
        var typed: [String] = []
        let (window, combo) = try host(ModelComboBox(
            text: Binding(get: { model.value }, set: { model.value = $0 }), items: ["old-model", "listed"],
            edits: edits, onTyping: { typed.append($0) }, onCommit: { commits += 1 }), finding: NSComboBox.self)
        defer { close(window) }
        type("new-model", into: combo, in: window)
        #expect(model.value == "old-model")
        #expect(typed.last == "new-model")
        #expect(edits.commitAll())
        #expect(model.value == "new-model")
        #expect(commits == 1)
    }

    @Test func aModelThatFailsValidationIsNotSavedAndStopsTheTest() throws {
        let edits = PendingEdits()
        let model = Box("old-model")
        let (window, combo) = try host(ModelComboBox(
            text: Binding(get: { model.value }, set: { model.value = $0 }), items: [],
            validation: { $0.contains(" ") ? UserInputValidation.identifierIssue("", required: true) : nil },
            edits: edits, onCommit: {}), finding: NSComboBox.self)
        defer { close(window) }
        type("has space", into: combo, in: window)
        #expect(!edits.commitAll())
        #expect(model.value == "old-model")
    }

    @Test func aModelClearedAndLeftReportsTheSavedModelAgain() throws {
        let model = Box("old-model")
        var typed: [String] = []
        let (window, combo) = try host(ModelComboBox(
            text: Binding(get: { model.value }, set: { model.value = $0 }), items: [],
            validation: { UserInputValidation.identifierIssue($0, required: true) },
            onTyping: { typed.append($0) }, onCommit: {}), finding: NSComboBox.self)
        defer { close(window) }
        type("", into: combo, in: window)
        #expect(typed.last == "")
        window.makeFirstResponder(nil)
        #expect(model.value == "old-model")
        #expect(typed.last == "old-model")
    }

    @Test func aModelSavedAndThenTakenBackShowsTheSavedOneWhileStillBeingEdited() throws {
        let edits = PendingEdits()
        let saved = Saved("old-model")
        let (window, combo) = try host(ModelOverSaved(saved: saved, edits: edits), finding: NSComboBox.self)
        defer { close(window) }
        type("new-model", into: combo, in: window)
        let before = saved.renders
        #expect(edits.commitAll())
        #expect(saved.text == "new-model")
        rendered(saved, after: before, in: window)
        saved.text = "old-model"
        #expect(waitUntil { shown(in: combo) == "old-model" })
        #expect(combo.currentEditor() != nil)
    }

    @Test func aModelBeingTypedIsKeptWhenTheSavedOneChangesUnderIt() throws {
        let edits = PendingEdits()
        let saved = Saved("old-model")
        let (window, combo) = try host(ModelOverSaved(saved: saved, edits: edits), finding: NSComboBox.self)
        defer { close(window) }
        type("typed-model", into: combo, in: window)
        change(saved, to: "elsewhere-model", in: window)
        #expect(shown(in: combo) == "typed-model")
        #expect(edits.commitAll())
        #expect(saved.text == "typed-model")
    }

    @Test func aTextFieldTypedButNotYetSavedIsSavedBeforeTheTest() throws {
        let edits = PendingEdits()
        let saved = Box<String?>(nil)
        let (window, text) = try host(Form {
            CommittedTextField("Base URL", text: "http://old/v1", edits: edits) { saved.value = $0 }
        }.formStyle(.grouped), finding: NSTextField.self)
        defer { close(window) }
        type("http://new/v1", into: text, in: window)
        #expect(saved.value == nil)
        #expect(edits.commitAll())
        #expect(saved.value == "http://new/v1")
    }

    @Test func aTextFieldSavedAndThenTakenBackShowsTheSavedValueWhileStillBeingEdited() throws {
        let edits = PendingEdits()
        let saved = Saved("http://old/v1")
        let (window, text) = try host(FieldOverSaved(saved: saved, edits: edits), finding: NSTextField.self)
        defer { close(window) }
        type("http://new/v1", into: text, in: window)
        #expect(waitUntil { saved.focused })
        let before = saved.renders
        #expect(edits.commitAll())
        #expect(saved.text == "http://new/v1")
        rendered(saved, after: before, in: window)
        saved.text = "http://old/v1"
        #expect(waitUntil { shown(in: text) == "http://old/v1" })
        #expect(text.currentEditor() != nil)
        #expect(edits.commitAll())
        #expect(saved.text == "http://old/v1")
    }

    @Test func aTextFieldBeingTypedIsKeptWhenTheSavedValueChangesUnderIt() throws {
        let edits = PendingEdits()
        let saved = Saved("http://old/v1")
        let (window, text) = try host(FieldOverSaved(saved: saved, edits: edits), finding: NSTextField.self)
        defer { close(window) }
        type("http://typed/v1", into: text, in: window)
        #expect(waitUntil { saved.focused })
        change(saved, to: "http://elsewhere/v1", in: window)
        #expect(shown(in: text) == "http://typed/v1")
        #expect(edits.commitAll())
        #expect(saved.text == "http://typed/v1")
    }

    @Test func aSaveUsesTheStateAroundTheFieldAsItIsNowNotAsItWasWhenTheFieldAppeared() throws {
        let edits = PendingEdits()
        let surroundings = Surroundings()
        let seen = Box<Bool?>(nil)
        let (window, text) = try host(
            FieldBesideState(surroundings: surroundings, edits: edits, seen: seen), finding: NSTextField.self)
        defer { close(window) }
        let before = surroundings.renders
        surroundings.hasKey = true
        #expect(waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            return surroundings.renders > before
        })
        type("http://new/v1", into: text, in: window)
        #expect(edits.commitAll())
        #expect(seen.value == true)
    }
}
