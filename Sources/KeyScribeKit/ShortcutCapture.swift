public struct ShortcutProfile: Equatable, Sendable {
    public let allowsNamedKeys: Bool
    public let allowsMouseButtons: Bool

    public init(allowsNamedKeys: Bool, allowsMouseButtons: Bool) {
        self.allowsNamedKeys = allowsNamedKeys
        self.allowsMouseButtons = allowsMouseButtons
    }

    public static let modeTrigger = ShortcutProfile(allowsNamedKeys: true, allowsMouseButtons: true)
    public static let actionChord = ShortcutProfile(allowsNamedKeys: false, allowsMouseButtons: false)

    public var namedKeyOptions: [NamedKey] {
        allowsNamedKeys ? [.fn, .rightOption, .rightCommand, .hyper] : []
    }
}

public struct ShortcutCaptureModel: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, recording }

    public let profile: ShortcutProfile
    public private(set) var value: KeyDescriptor?
    public private(set) var rawFallback: String?
    public private(set) var phase: Phase = .idle
    public private(set) var hint: String?
    private var priorValue: KeyDescriptor?

    public init(profile: ShortcutProfile, stored: String) {
        self.profile = profile
        if stored.trimmingCharacters(in: .whitespaces).isEmpty {
            value = nil
        } else if let descriptor = try? KeyDescriptor(parsing: stored) {
            value = descriptor
        } else {
            rawFallback = stored
        }
    }

    public mutating func beginRecording() {
        priorValue = value
        phase = .recording
        hint = nil
    }

    public mutating func keyEvent(keyCode: Int, modifiers: Set<Modifier>) -> KeyDescriptor? {
        guard phase == .recording else { return nil }
        if let descriptor = KeyDescriptor(eventKeyCode: keyCode, modifiers: modifiers) {
            commit(descriptor)
            return descriptor
        }
        hint = modifiers.isEmpty ? "Hold a modifier (⌃⌥⇧⌘) with the key" : "That key can't be recorded"
        return nil
    }

    public mutating func mouseEvent(buttonNumber: Int) -> KeyDescriptor? {
        guard phase == .recording else { return nil }
        guard profile.allowsMouseButtons else {
            hint = "Mouse buttons can't be used for this shortcut"
            return nil
        }
        guard let descriptor = KeyDescriptor(eventButtonNumber: buttonNumber) else { return nil }
        commit(descriptor)
        return descriptor
    }

    public mutating func cancel() {
        guard phase == .recording else { return }
        value = priorValue
        phase = .idle
        hint = nil
    }

    public mutating func noKeyOnModifierRelease() {
        guard phase == .recording else { return }
        hint = "No key received — another app may already use this shortcut."
    }

    public mutating func select(_ newValue: KeyDescriptor?) {
        phase = .idle
        value = newValue
        rawFallback = nil
        hint = nil
    }

    private mutating func commit(_ descriptor: KeyDescriptor) {
        value = descriptor
        rawFallback = nil
        phase = .idle
        hint = nil
    }
}
