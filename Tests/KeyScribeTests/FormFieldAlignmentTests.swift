import AppKit
import SwiftUI
import Testing
@testable import KeyScribeApp

@MainActor
struct FormFieldAlignmentTests {
    private func editableFields(_ view: NSView) -> [NSTextField] {
        ((view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []) + view.subviews.flatMap(editableFields)
    }

    private func render<V: View>(_ content: V) -> [NSTextField] {
        let host = NSHostingView(rootView: content.frame(width: 500, height: 300))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        return editableFields(host)
    }

    @Test func aLabeledFieldInAGroupedFormIsRightAlignedEvenWhenAskedForLeading() {
        let fields = render(Form {
            TextField("Name", text: .constant("foo ")).multilineTextAlignment(.leading)
        }.formStyle(.grouped))
        #expect(fields.map(\.alignment) == [.right])
    }

    @Test func aFormFieldLabelKeepsTheTextLeadingWhereATrailingSpaceStaysVisible() {
        let fields = render(Form {
            TextField("Name", text: .constant("foo "), prompt: Text("deploy")).formFieldLabel("Name")
            SecureField("API key", text: .constant("foo ")).formFieldLabel("API key")
            VStack(alignment: .leading) {
                TextField("Also say", text: .constant("foo ")).formFieldLabel("Also say")
                Text("caption")
            }
        }.formStyle(.grouped))
        #expect(fields.count == 3)
        #expect(fields.allSatisfy { $0.alignment == .natural })
    }

    @Test func theVoiceCommandsPaneKeepsEveryFieldLeading() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-align-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = VoiceCommandsSettingsModel(repository: ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir)))
        let fields = render(VoiceCommandsEditorView(mode: .voiceCommands, allModes: [.voiceCommands], onUpdate: { _ in }, model: model)
            .environmentObject(HotkeyRecordingState()))
        #expect(!fields.isEmpty)
        #expect(fields.allSatisfy { $0.alignment == .natural })
    }

    @Test func aCommittedTextFieldKeepsItsTextLeading() {
        let fields = render(Form {
            CommittedTextField("Name", text: "foo ", validation: nil) { _ in }
        }.formStyle(.grouped))
        #expect(fields.map(\.alignment) == [.natural])
    }
}
