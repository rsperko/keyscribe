import AppKit
import KeyScribeKit
import SwiftUI

// Shared while any shortcut well is capturing. The selection Lists in Settings disable themselves on
// it so SwiftUI's keyboard type-select can't grab the chord's keystroke before the well sees it.
final class HotkeyRecordingState: ObservableObject {
    // Lets the app suspend the global hotkey monitor while a well captures (set by AppDelegate).
    var onChange: ((Bool) -> Void)?
    @Published var isRecording = false { didSet { onChange?(isRecording) } }
}

// Stable identities for the two global shortcuts in the app-wide hotkey namespace (alongside Mode ids).
enum GlobalHotkey {
    static let vocabularyId = "global:add_vocabulary"
    static let pasteLastId = "global:paste_last"
}

private let noneMenuTag = ""
private let unlistedMenuTag = "\u{1}unlisted"

struct ShortcutWell: View {
    @Binding var key: String
    var profile: ShortcutProfile = .modeTrigger
    var accessibilityID: String
    @EnvironmentObject private var recordingState: HotkeyRecordingState
    @State private var hint: String?
    @State private var recording = false
    @State private var recordToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                RecorderButton(
                    key: $key, hint: $hint, recording: $recording,
                    profile: profile, recordToken: recordToken, recordingState: recordingState)
                    .frame(width: 240, height: 24)
                    .accessibilityIdentifier(accessibilityID)
                Menu {
                    Picker(selection: namedSelection, label: EmptyView()) {
                        Text("None").tag(noneMenuTag)
                        ForEach(profile.namedKeyOptions, id: \.self) { named in
                            Text(namedMenuLabel(named)).tag(KeyDescriptor.named(named).canonical)
                        }
                        if isUnlisted { Text("Custom").tag(unlistedMenuTag) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button(profile.allowsNamedKeys ? "Record Custom Shortcut…" : "Record Shortcut…") {
                        recordToken += 1
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(recording)
            }

            if let caption {
                Text(caption)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: 288, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { recordingState.isRecording = false }
    }

    private var caption: String? {
        if let hint { return hint }
        if isUnparseable { return "Not a recognized shortcut" }
        return nil
    }

    private var descriptor: KeyDescriptor? { try? KeyDescriptor(parsing: key) }

    private var isUnparseable: Bool { !key.isEmpty && descriptor == nil }

    private var isUnlisted: Bool {
        guard !key.isEmpty else { return false }
        if case .named = descriptor { return false }
        return true
    }

    private var namedSelection: Binding<String> {
        Binding(
            get: {
                if case .named(let n) = descriptor { return KeyDescriptor.named(n).canonical }
                return key.isEmpty ? noneMenuTag : unlistedMenuTag
            },
            set: { tag in
                hint = nil
                if tag == noneMenuTag {
                    key = ""
                } else if let parsed = try? KeyDescriptor(parsing: tag), case .named = parsed {
                    key = parsed.canonical
                }
            })
    }
}

private func namedMenuLabel(_ named: NamedKey) -> String {
    switch named {
    case .fn: return "Fn (Globe)"
    case .rightOption: return "Right Option"
    case .rightCommand: return "Right Command"
    case .hyper: return "Hyper (⌃⌥⇧⌘)"
    }
}

private struct RecorderButton: NSViewRepresentable {
    @Binding var key: String
    @Binding var hint: String?
    @Binding var recording: Bool
    let profile: ShortcutProfile
    let recordToken: Int
    let recordingState: HotkeyRecordingState

    func makeNSView(context: Context) -> RecorderButtonView {
        let view = RecorderButtonView()
        view.profile = profile
        view.onCommit = { key = $0 }
        view.onHint = { hint = $0 }
        view.onRecordingChange = { recording = $0 }
        view.recordingState = recordingState
        view.syncKey(key)
        context.coordinator.lastRecordToken = recordToken
        return view
    }

    func updateNSView(_ view: RecorderButtonView, context: Context) {
        view.profile = profile
        view.recordingState = recordingState
        view.syncKey(key)
        if recordToken != context.coordinator.lastRecordToken {
            context.coordinator.lastRecordToken = recordToken
            DispatchQueue.main.async { view.beginRecording() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var lastRecordToken = 0 }
}

// A focusable button that captures the chord in performKeyEquivalent(with:), which AppKit dispatches
// before a focused List's keyDown type-select — so recording a shortcut never navigates the sidebar.
final class RecorderButtonView: NSButton {
    var onCommit: ((String) -> Void)?
    var onHint: ((String?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    var profile: ShortcutProfile = .modeTrigger
    var recordingState: HotkeyRecordingState?

    private var model = ShortcutCaptureModel(profile: .modeTrigger, stored: "")
    private var recording = false
    private var didCommit = false
    private var storedKey = ""
    private var monitor: Any?
    private var peakModifierCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(handleClick)
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }

    func syncKey(_ key: String) {
        guard !recording, key != storedKey else { return }
        storedKey = key
        model = ShortcutCaptureModel(profile: profile, stored: key)
        refreshTitle()
    }

    func beginRecording() {
        guard !recording else { return }
        start()
    }

    @objc private func handleClick() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        didCommit = false
        peakModifierCount = 0
        model = ShortcutCaptureModel(profile: profile, stored: storedKey)
        model.beginRecording()
        recordingState?.isRecording = true
        onRecordingChange?(true)
        onHint?(nil)
        window?.makeFirstResponder(self)
        // A local monitor sees the keystroke before SwiftUI's List type-select (which runs ahead of
        // performKeyEquivalent and ignores first responder). Returning nil swallows the event, so
        // recording a shortcut never navigates the mode/sidebar list. flagsChanged is observed, not
        // swallowed: a chord another app reserved globally is consumed before its keyDown reaches this
        // monitor, so a held-then-released modifier combo with no key is the only signal that fires.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .otherMouseDown, .flagsChanged]
        ) { [weak self] event in
            guard let self, self.recording else { return event }
            if event.type == .flagsChanged { self.handleFlags(event); return event }
            guard event.window === self.window else { return event }
            if event.type == .keyDown { self.handleKey(event) }
            else if event.type == .otherMouseDown { self.handleMouse(event) }
            return nil
        }
        refreshTitle()
    }

    private func handleFlags(_ event: NSEvent) {
        guard recording else { return }
        let count = RecorderButtonView.modifierSet(event.modifierFlags).count
        if count == 0 {
            if peakModifierCount >= 2, !didCommit {
                model.noKeyOnModifierRelease()
                onHint?(model.hint)
                refreshTitle()
            }
            peakModifierCount = 0
        } else {
            peakModifierCount = max(peakModifierCount, count)
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        recordingState?.isRecording = false
        onRecordingChange?(false)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if !didCommit { model.cancel() }
        onHint?(nil)
        refreshTitle()
    }

    override func resignFirstResponder() -> Bool {
        stop()
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        handleKey(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        handleKey(event)
    }

    private func handleKey(_ event: NSEvent) {
        guard recording else { return }
        if event.keyCode == 53 {
            window?.makeFirstResponder(nil)
            return
        }
        let modifiers = RecorderButtonView.modifierSet(event.modifierFlags)
        if let descriptor = model.keyEvent(keyCode: Int(event.keyCode), modifiers: modifiers) {
            commit(descriptor)
        } else {
            onHint?(model.hint)
            refreshTitle()
        }
    }

    private func handleMouse(_ event: NSEvent) {
        guard recording else { return }
        if let descriptor = model.mouseEvent(buttonNumber: event.buttonNumber) {
            commit(descriptor)
        } else {
            onHint?(model.hint)
            refreshTitle()
        }
    }

    private func commit(_ descriptor: KeyDescriptor) {
        didCommit = true
        storedKey = descriptor.canonical
        onCommit?(descriptor.canonical)
        window?.makeFirstResponder(nil)
    }

    private func refreshTitle() {
        title = label
    }

    private var label: String {
        if recording {
            return profile.allowsMouseButtons
                ? "Press a shortcut…  Esc cancels"
                : "Press a key combo…  Esc cancels"
        }
        if let value = model.value { return value.displayString }
        if let raw = model.rawFallback { return raw }
        return "Click to record"
    }

    static func modifierSet(_ flags: NSEvent.ModifierFlags) -> Set<Modifier> {
        var set: Set<Modifier> = []
        if flags.contains(.control) { set.insert(.control) }
        if flags.contains(.option) { set.insert(.option) }
        if flags.contains(.shift) { set.insert(.shift) }
        if flags.contains(.command) { set.insert(.command) }
        return set
    }
}
