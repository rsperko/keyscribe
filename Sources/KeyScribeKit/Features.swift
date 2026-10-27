import Foundation

// Single source of truth for in-development feature flags. Each value is one opt-in toggle under
// Settings → Maintenance → Experimental features, read at its gate via `settings.features.isEnabled(.someFlag)`.
//
// Add:      a `static let` with a unique snake_case id, listed in `allCases`; gate on isEnabled. The toggle
//           renders automatically.
// Roll out: delete the `static let` + its `allCases` entry and make the gate unconditional. A stale id in a
//           user's settings.toml is ignored and dropped on next write.
//
// Strictly opt-in (unset = off, no per-flag default-on), so a half-built feature can never silently ship
// enabled. A struct with an empty catalog rather than an empty enum, so empty state doesn't read as
// unreachable code (and the UI section hides itself). `id` is the stable TOML key — snake_case, unique
// (FeaturesTests guards it), never renamed once shipped.
public struct Feature: CaseIterable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    private let requiresId: String?

    init(id: String, title: String, summary: String, requires: Feature? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.requiresId = requires?.id
    }

    public var requires: Feature? { Self.allCases.first { $0.id == requiresId } }
    public var dependents: [Feature] { Self.allCases.filter { $0.requiresId == id } }
    public static var topLevel: [Feature] { allCases.filter { $0.requiresId == nil } }

    // Streaming transcription (P3-1): on supported engines, transcribe incrementally during capture so the
    // transcript is ready sooner after release. Off by default; non-streaming engines keep the batch path.
    public static let streamingTranscription = Feature(
        id: "streaming_transcription",
        title: "Streaming transcription",
        summary: "On supported speech models, begin transcribing while you talk, so longer dictations can be ready sooner after you finish. Short dictations are unaffected."
    )

    // Consumption-driven clipboard restore: instead of holding the dictation on the clipboard for a fixed
    // delay, publish it as a lazy pasteboard flavor and restore as soon as the target has actually read it.
    // Flagged until verified live: target-side paste latency (the read is fulfilled through this app's main
    // run loop, so the target's ⌘V waits on it), a clipboard manager that ignores the concealed marker (its
    // read is indistinguishable from the target's), and the 100 ms grace against a real Chromium paste.
    public static let consumptionDrivenRestore = Feature(
        id: "consumption_driven_restore",
        title: "Restore clipboard on paste",
        summary: "Put your clipboard back as soon as the app has taken the dictation, instead of after a fixed delay. Shortens the window where pressing ⌘V pastes the dictation again."
    )

    public static let voiceCommands = Feature(
        id: "voice_commands",
        title: "Voice Commands",
        summary: "Adds a built-in Voice Commands mode: give it a shortcut, then say the name of a command you saved, or \(VoiceCommandPhrase.guidance). Speech on that shortcut is never typed."
    )

    // Finding items in apps: an app name followed by more words opens a browser tab or an entry in the app's
    // sidebar, read through Accessibility. Flagged because sidebars depend on each app's outline shape; measured
    // only in a few apps, and not yet exercised through unread changes, rearranged rows, multiple windows, or
    // account switches.
    public static let findInApps = Feature(
        id: "voice_command_sidebars",
        title: "Find items in apps by voice",
        summary: "Say \u{201C}open\u{201D}, then the app and what you want to find, such as \u{201C}open Slack general\u{201D} or \u{201C}open Chrome weather\u{201D}. A browser is searched by its open tabs; another app by the items shown in its sidebar, read only when you ask. Some apps, such as Slack, turn on their accessibility support to be read, which stays on until the app quits and can make it use more memory.",
        requires: voiceCommands
    )

    public static let allCases: [Feature] = [streamingTranscription, consumptionDrivenRestore, voiceCommands, findInApps]
}
