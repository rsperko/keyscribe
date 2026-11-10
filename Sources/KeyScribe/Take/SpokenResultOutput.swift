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
        var standalone = false
        var requested = false
        var order: Int?
        var connection: String?
        var origin: String?
        var refusal = false
        var mergedOrigins: [String?] = []
        var text: String { standalone ? body : SpokenResult.prefaced(body, name: name) }
    }

    struct Heard: Equatable {
        let conversation: String
        let name: String
        let text: String
        let connection: String?
        let origin: String?
    }

    enum Unread: Equatable {
        case inFront(name: String)

        var line: String {
            switch self {
            case .inFront(let name): "Not read aloud: \(name) was in front when it finished"
            }
        }
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
    private var nextOrder = 0
    private(set) var queued: [Queued] = []
    private var generating: [String: Task<Void, Never>] = [:]
    private var checkingNotice: [String: Task<Void, Never>] = [:]
    private var playing: Queued?
    private var heard: Queued?
    private var replay: Queued?
    private var answering: (item: Queued, stillTrue: () -> Bool)?
    private var playingCheck: (() -> Bool)?
    private var announced = false
    private var playingRequested: Set<String> = []
    private var noticed: [String: AgentAttention] = [:]
    private(set) var pendingRequested: Set<String> = [] {
        didSet { if pendingRequested != oldValue { onPendingChange?() } }
    }
    var onSpeaking: ((Speaking?) -> Void)?
    var onHeard: ((Heard) -> Void)?
    var onUnread: ((Unread, _ origin: String) -> Void)?
    var onPendingChange: (() -> Void)?
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
        pendingRequested = []
        playingRequested = []
        noticed = [:]
        replay = nil
        answering = nil
        playing = nil
        speech.stop()
        if announced {
            announced = false
            onSpeaking?(nil)
        }
    }

    func forget(conversation: String) {
        generating.removeValue(forKey: conversation)?.cancel()
        generating.removeValue(forKey: Self.requestedKey(conversation))?.cancel()
        pendingRequested.remove(conversation)
        noticed[conversation] = nil
        checkingNotice.removeValue(forKey: conversation)?.cancel()
        queued.removeAll { $0.conversation == conversation }
        if replay?.conversation == conversation { replay = nil }
        if answering?.item.conversation == conversation { answering = nil }
        if heard?.conversation == conversation { heard = nil }
        guard let playing, playing.conversation == conversation else { return }
        self.playing = nil
        speech.stop()
        if announced {
            announced = false
            onSpeaking?(nil)
        }
        playNext()
    }

    func withdraw(conversation: String) {
        generating.removeValue(forKey: conversation)?.cancel()
        generating.removeValue(forKey: Self.requestedKey(conversation))?.cancel()
        checkingNotice.removeValue(forKey: conversation)?.cancel()
        queued.removeAll { $0.conversation == conversation }
        noticed[conversation] = nil
        pendingRequested.remove(conversation)
        guard let playing, playing.conversation == conversation, !playing.replayed, !announced else { return }
        self.playing = nil
        speech.stop()
        playNext()
    }

    private static func requestedKey(_ conversation: String) -> String { conversation + "\u{1F}requested" }

    private func supersede(_ conversation: String, requested: Bool) {
        generating.removeValue(forKey: conversation)?.cancel()
        if requested { generating.removeValue(forKey: Self.requestedKey(conversation))?.cancel() }
        queued.removeAll { $0.conversation == conversation && !$0.refusal && (requested || !$0.requested) }
        guard let playing, playing.conversation == conversation, !playing.replayed, !playing.refusal, !announced,
              requested || !playing.requested else { return }
        self.playing = nil
        playingRequested = []
        speech.stop()
        playNext()
    }

    func finished(conversation: String, handle: String, answer: String, requested: Bool = false, origin: String? = nil) {
        let settings = settings()
        guard settings.enabled else { return }
        let plan = SpokenResult.plan(answer: answer, configured: !settings.connection.isEmpty)
        announce(
            conversation: conversation, handle: handle, plan == .nothing && requested ? .speak(SpokenResult.noTextBody) : plan,
            requested: requested, origin: origin)
    }

    func ended(conversation: String, handle: String, body: String, requested: Bool, origin: String? = nil) {
        guard settings().enabled else { return }
        announce(conversation: conversation, handle: handle, .speak(body), requested: requested, origin: origin)
    }

    private func announce(conversation: String, handle: String, _ plan: SpokenResult.Plan, requested: Bool, origin: String?) {
        let settings = settings()
        let usable = connection(settings.connection).flatMap { permits($0) ? $0 : nil }
        if plan == .nothing { return }
        supersede(conversation, requested: requested)
        if requested { pendingRequested.insert(conversation) }
        let key = requested ? Self.requestedKey(conversation) : conversation
        let inFront = inFront
        let order = nextOrder
        nextOrder += 1
        generating[key] = Task { [weak self] in
            let shown = requested ? false : await inFront(conversation)
            guard !Task.isCancelled, let self else { return }
            guard !shown else {
                self.generating.removeValue(forKey: key)
                if let origin { self.onUnread?(.inFront(name: handle), origin) }
                return
            }
            var text = ""
            var summarizedBy: String?
            switch plan {
            case .nothing: return
            case .speak(let spoken): text = spoken
            case .summarize(let input):
                guard let usable else { break }
                let request = SpokenResult.request(answer: input, prompt: settings.effectivePrompt, tokenizer: Tokenizer())
                text = await self.summary(of: request, connection: usable, handle: handle, deadline: self.deadlineSeconds)
                summarizedBy = usable.name
            }
            guard !Task.isCancelled, self.settings().enabled else { return }
            self.generating.removeValue(forKey: key)
            self.enqueue(text.isEmpty
                ? Queued(
                    conversation: conversation, name: handle, body: SpokenResult.unavailableBody, unavailable: true, requested: requested,
                    order: order, origin: origin)
                : Queued(
                    conversation: conversation, name: handle, body: text, requested: requested, order: order, connection: summarizedBy,
                    origin: origin))
        }
    }

    private func summary(of request: SpokenResult.Request, connection: Connection, handle: String, deadline: Double) async -> String {
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

    func attention(conversation: String, handle: String, _ attention: AgentAttention?, requested: Bool = false) {
        if let attention, noticed[conversation] == attention { return }
        noticed[conversation] = nil
        checkingNotice.removeValue(forKey: conversation)?.cancel()
        queued.removeAll { $0.conversation == conversation && $0.notice && !$0.refusal }
        if let playing, playing.conversation == conversation, playing.notice, !playing.refusal, !playing.replayed, !announced {
            self.playing = nil
            speech.stop()
            playNext()
        }
        guard let attention, settings().enabled else { return }
        generating.removeValue(forKey: conversation)?.cancel()
        let inFront = inFront
        checkingNotice[conversation] = Task { [weak self] in
            let shown = requested ? false : await inFront(conversation)
            guard !Task.isCancelled, let self else { return }
            guard !shown, self.settings().enabled else {
                self.checkingNotice.removeValue(forKey: conversation)
                return
            }
            var body = SpokenResult.notice(attention)
            var describedBy: String?
            if case .waiting(let prompt) = attention, let described = await self.description(of: prompt, handle: handle) {
                body = described.text
                describedBy = described.connection
            }
            guard !Task.isCancelled else { return }
            self.checkingNotice.removeValue(forKey: conversation)
            guard self.settings().enabled else { return }
            self.noticed[conversation] = attention
            self.enqueue(Queued(conversation: conversation, name: handle, body: body, notice: true, connection: describedBy))
        }
    }

    func describe(_ prompt: AgentPrompt, handle: String) async -> String? {
        let described = await description(of: prompt, handle: handle)?.text
        return described == SpokenResult.notice(.waiting(prompt)) ? nil : described
    }

    func refused(conversation: String, _ line: String) {
        guard settings().enabled else { return }
        enqueue(Queued(conversation: conversation, name: "", body: line, notice: true, standalone: true, refusal: true))
    }

    func answer(conversation: String, handle: String, _ text: String, whileTrue stillTrue: @escaping () -> Bool) -> Bool {
        guard settings().enabled else { return false }
        if !conversation.isEmpty {
            checkingNotice.removeValue(forKey: conversation)?.cancel()
            queued.removeAll { $0.conversation == conversation && $0.notice && !$0.refusal }
        }
        answering = (Queued(conversation: conversation, name: handle, body: text, notice: true, standalone: true), stillTrue)
        playNext()
        return true
    }

    private func description(of prompt: AgentPrompt, handle: String) async -> (text: String, connection: String)? {
        let settings = settings()
        guard settings.isOn, let connection = connection(settings.connection), permits(connection),
              let request = SpokenResult.waitingRequest(prompt, tokenizer: Tokenizer())
        else { return nil }
        let text = await summary(of: request, connection: connection, handle: handle, deadline: describeDeadlineSeconds)
        return text.isEmpty ? nil : (text, connection.name)
    }

    func repeatLast() -> Replay {
        guard settings().enabled else { return .off }
        guard let heard else { return .nothingHeard }
        replay = heard
        playNext()
        return .repeating(heard.name)
    }

    private func enqueue(_ item: Queued) {
        var item = item
        if item.order == nil {
            item.order = nextOrder
            nextOrder += 1
        }
        let order = item.order ?? 0
        queued.removeAll { $0.conversation == item.conversation && $0.refusal == item.refusal && (item.requested || !$0.requested) }
        queued.insert(item, at: queued.firstIndex { ($0.order ?? 0) > order } ?? queued.endIndex)
        playNext()
    }

    private func started() {
        guard let playing, !announced else { return }
        if let check = playingCheck {
            playingCheck = nil
            guard check() else { return speech.stop() }
        }
        announced = true
        pendingRequested.subtract(playingRequested)
        playingRequested = []
        heard = playing
        onSpeaking?(Speaking(name: playing.name, text: playing.body))
        if !playing.replayed, !playing.standalone, !playing.notice {
            let origins = playing.mergedOrigins.isEmpty ? [playing.origin] : playing.mergedOrigins.compactMap { $0 }
            for origin in origins {
                onHeard?(Heard(
                    conversation: playing.conversation, name: playing.name, text: playing.text,
                    connection: playing.connection, origin: origin))
            }
        }
    }

    private func ended() {
        playing = nil
        playingCheck = nil
        pendingRequested.subtract(playingRequested)
        playingRequested = []
        if announced {
            announced = false
            onSpeaking?(nil)
        }
        playNext()
    }

    private func playNext() {
        guard settings().enabled else {
            queued = []
            pendingRequested = []
            replay = nil
            answering = nil
            return
        }
        guard playing == nil, silencer.isAvailable(for: speech), !speech.isSpeaking else { return }
        if let answering {
            self.answering = nil
            guard answering.stillTrue() else { return playNext() }
            return play(answering.item, while: answering.stillTrue)
        }
        if let replay {
            self.replay = nil
            var replayed = replay
            replayed.replayed = true
            return play(replayed)
        }
        guard !queued.isEmpty else { return }
        var next = queued.removeFirst()
        if next.unavailable && !next.requested {
            let merged = queued.filter { $0.unavailable && !$0.requested }
            let notice = SpokenResult.unavailable(names: [next.name] + merged.map(\.name))
            queued.removeAll { $0.unavailable && !$0.requested }
            next = Queued(
                conversation: next.conversation, name: notice.name, body: notice.body, unavailable: true, origin: next.origin,
                mergedOrigins: merged.isEmpty ? [] : [next.origin] + merged.map(\.origin))
        }
        play(next, requested: next.requested ? [next.conversation] : [])
    }

    private func play(_ item: Queued, while stillTrue: (() -> Bool)? = nil, requested: Set<String> = []) {
        playing = item
        playingCheck = stillTrue
        playingRequested = requested
        silencer.speak(item.text, voice: settings().voice, with: speech)
        if !speech.isSpeaking {
            playing = nil
            pendingRequested.subtract(playingRequested)
            playingRequested = []
        }
    }
}
