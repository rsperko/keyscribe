import Foundation
import KeyScribeKit
import os

@MainActor
final class SpokenResultOutput {
    struct Queued: Equatable {
        let conversation: String
        let name: String
        let body: String
        var unavailable = false
        var notice = false
        var replayed = false
        var text: String { SpokenResult.prefaced(body, name: name) }
    }

    struct Speaking: Equatable {
        let name: String
        let text: String
    }

    enum Replay: Equatable {
        case repeating(String)
        case nothingHeard
        case off
    }

    private let client: any LLMClient
    private let permits: @Sendable (Connection) -> Bool
    private let speech: any SpeechSynthesizing
    private let silencer: SpeechSilencer
    private let settings: () -> SpokenResultSettings
    private let connection: (String) -> Connection?
    private let deadlineSeconds: Double
    private let describeDeadlineSeconds: Double
    private let warm: () -> Void
    private let inFront: @MainActor (String) async -> Bool
    private var wasOn = false
    private(set) var queued: [Queued] = []
    private var generating: [String: Task<Void, Never>] = [:]
    private var checkingNotice: [String: Task<Void, Never>] = [:]
    private var playing: Queued?
    private var heard: Queued?
    private var replay: Queued?
    private var announced = false
    var onSpeaking: ((Speaking?) -> Void)?
    var pendingSummaries: Int { generating.count }

    init(
        client: any LLMClient, permits: @escaping @Sendable (Connection) -> Bool, speech: any SpeechSynthesizing,
        silencer: SpeechSilencer = .shared, settings: @escaping () -> SpokenResultSettings, connection: @escaping (String) -> Connection?,
        deadlineSeconds: Double = 30, describeDeadlineSeconds: Double = 5, warm: @escaping () -> Void = {},
        inFront: @escaping @MainActor (String) async -> Bool = { _ in false }
    ) {
        self.client = client
        self.permits = permits
        self.speech = speech
        self.silencer = silencer
        self.settings = settings
        self.connection = connection
        self.deadlineSeconds = deadlineSeconds
        self.describeDeadlineSeconds = describeDeadlineSeconds
        self.warm = warm
        self.inFront = inFront
        speech.onStarted = { [weak self] in self?.started() }
        speech.onFinished = { [weak self] in self?.ended() }
        silencer.register(speech)
        silencer.onAvailable = { [weak self] in self?.playNext() }
        wasOn = settings().enabled
        if wasOn { warm() }
    }

    func settingsChanged() {
        let isOn = settings().enabled
        defer { wasOn = isOn }
        guard isOn else { return stop() }
        if !wasOn { warm() }
    }

    func stop() {
        for task in generating.values { task.cancel() }
        generating = [:]
        for task in checkingNotice.values { task.cancel() }
        checkingNotice = [:]
        queued = []
        replay = nil
        playing = nil
        speech.stop()
        if announced {
            announced = false
            onSpeaking?(nil)
        }
    }

    func finished(conversation: String, handle: String, answer: String) {
        let settings = settings()
        guard settings.enabled else { return }
        let usable = connection(settings.connection).flatMap { permits($0) ? $0 : nil }
        let plan = SpokenResult.plan(answer: answer, configured: !settings.connection.isEmpty)
        if plan == .nothing { return }
        generating.removeValue(forKey: conversation)?.cancel()
        queued.removeAll { $0.conversation == conversation }
        let inFront = inFront
        generating[conversation] = Task { [weak self] in
            let shown = await inFront(conversation)
            guard !Task.isCancelled, let self else { return }
            guard !shown else {
                self.generating.removeValue(forKey: conversation)
                return
            }
            var text = ""
            switch plan {
            case .nothing: return
            case .speak(let spoken): text = spoken
            case .summarize(let input):
                guard let usable else { break }
                let request = SpokenResult.request(answer: input, prompt: settings.effectivePrompt, tokenizer: Tokenizer())
                text = await self.summary(of: request, connection: usable, handle: handle, deadline: self.deadlineSeconds)
            }
            guard !Task.isCancelled, self.settings().enabled else { return }
            self.generating.removeValue(forKey: conversation)
            self.enqueue(text.isEmpty
                ? Queued(conversation: conversation, name: handle, body: SpokenResult.unavailableBody, unavailable: true)
                : Queued(conversation: conversation, name: handle, body: text))
        }
    }

    private func summary(of request: (system: String, user: String), connection: Connection, handle: String, deadline: Double) async -> String {
        let client = client
        do {
            return try await runWithDeadline(seconds: deadline) {
                let first = SpokenResult.spoken(
                    summary: try await client.complete(system: request.system, user: request.user, connection: connection))
                if SpokenResult.fits(first) { return first }
                try Task.checkCancellation()
                let second = SpokenResult.spoken(
                    summary: try await client.complete(
                        system: SpokenResult.shorter(system: request.system), user: request.user, connection: connection))
                return SpokenResult.fits(second) ? second : ""
            }
        } catch {
            Log.agents.info("spoken result not generated for \(handle, privacy: .public): \(((error as? RewriteFailureReporting)?.rewriteFailureReason ?? "unavailable"), privacy: .public)")
            return ""
        }
    }

    func attention(conversation: String, handle: String, _ attention: AgentAttention?) {
        checkingNotice.removeValue(forKey: conversation)?.cancel()
        queued.removeAll { $0.conversation == conversation && $0.notice }
        if let playing, playing.conversation == conversation, playing.notice, !playing.replayed, !announced {
            self.playing = nil
            speech.stop()
            playNext()
        }
        guard let attention, settings().enabled else { return }
        generating.removeValue(forKey: conversation)?.cancel()
        let inFront = inFront
        checkingNotice[conversation] = Task { [weak self] in
            let shown = await inFront(conversation)
            guard !Task.isCancelled, let self else { return }
            guard !shown, self.settings().enabled else {
                self.checkingNotice.removeValue(forKey: conversation)
                return
            }
            var body = SpokenResult.notice(attention)
            if case .waiting(let prompt) = attention { body = await self.description(of: prompt, handle: handle) ?? body }
            guard !Task.isCancelled else { return }
            self.checkingNotice.removeValue(forKey: conversation)
            guard self.settings().enabled else { return }
            self.enqueue(Queued(conversation: conversation, name: handle, body: body, notice: true))
        }
    }

    private func description(of prompt: AgentPrompt, handle: String) async -> String? {
        let settings = settings()
        guard settings.isOn, let connection = connection(settings.connection), permits(connection),
              let request = SpokenResult.waitingRequest(prompt, tokenizer: Tokenizer())
        else { return nil }
        let text = await summary(of: request, connection: connection, handle: handle, deadline: describeDeadlineSeconds)
        return text.isEmpty ? nil : text
    }

    func repeatLast() -> Replay {
        guard settings().enabled else { return .off }
        guard let heard else { return .nothingHeard }
        replay = heard
        playNext()
        return .repeating(heard.name)
    }

    private func enqueue(_ item: Queued) {
        queued.removeAll { $0.conversation == item.conversation }
        queued.append(item)
        playNext()
    }

    private func started() {
        guard let playing, !announced else { return }
        announced = true
        heard = playing
        onSpeaking?(Speaking(name: playing.name, text: playing.body))
    }

    private func ended() {
        playing = nil
        if announced {
            announced = false
            onSpeaking?(nil)
        }
        playNext()
    }

    private func playNext() {
        guard settings().enabled else {
            queued = []
            replay = nil
            return
        }
        guard playing == nil, silencer.isAvailable(for: speech), !speech.isSpeaking else { return }
        if let replay {
            self.replay = nil
            var replayed = replay
            replayed.replayed = true
            return play(replayed)
        }
        guard !queued.isEmpty else { return }
        var next = queued.removeFirst()
        if next.unavailable {
            let notice = SpokenResult.unavailable(names: [next.name] + queued.filter(\.unavailable).map(\.name))
            queued.removeAll(where: \.unavailable)
            next = Queued(conversation: next.conversation, name: notice.name, body: notice.body, unavailable: true)
        }
        play(next)
    }

    private func play(_ item: Queued) {
        playing = item
        silencer.speak(item.text, voice: settings().voice, with: speech)
        if !speech.isSpeaking { playing = nil }
    }
}
