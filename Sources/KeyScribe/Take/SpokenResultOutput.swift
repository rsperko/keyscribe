import Foundation
import KeyScribeKit
import os

@MainActor
final class SpokenResultOutput {
    struct Queued: Equatable {
        let conversation: String
        let name: String
        var body: String
        var unavailable = false
        var notice = false
        var replayed = false
        var standalone = false
        var requested = false
        var order: Int?
        var connection: String?
        var origin: String?
        var agent: String?
        var refusal = false
        var merged: [Source] = []
        var shownOnly = false
        var heardAlready = false
        var returned: String?
        var failure: String?
        var cause: SpokenResult.Cause?
        var reply: String?
        var mergedReplies: [Queued] = []
        var progress = false
        var text: String { standalone ? body : SpokenResult.prefaced(body, name: name, cause: cause) }
        var unheard: [Source] {
            guard !replayed, !notice, !standalone, !heardAlready else { return [] }
            return merged.isEmpty ? [Source(origin: origin, failure: failure, agent: agent)] : merged
        }
    }

    private struct Preparing {
        let task: Task<Void, Never>
        let name: String
        let origin: String?
        let agent: String?
    }

    struct Source: Equatable {
        let origin: String?
        let failure: String?
        var agent: String? = nil
    }

    struct Heard: Equatable {
        let conversation: String
        let name: String
        let text: String
        let connection: String?
        let origin: String?
        var attempt: String? = nil
        var reader: SpokenAttempt.Reader? = nil
        var reason: String? = nil
        var returned: String? = nil
        var failure: String? = nil
        var cause: SpokenResult.Cause? = nil
    }

    enum Unread: Equatable {
        case inFront(name: String)
        case replaced(name: String)
        case dictationStarted
        case cancelled(name: String)
        case disconnected(name: String)
        case stopped
        case notStarted
        case noText

        var line: String {
            switch self {
            case .inFront(let name): "Not read aloud: \(name) was in front when it finished"
            case .replaced(let name): "Not read aloud: something newer from \(name) replaced it"
            case .dictationStarted: "Not read aloud: a dictation started before it played"
            case .cancelled(let name): "Not read aloud: reading \(name)\u{2019}s reply was cancelled"
            case .disconnected(let name): "Not read aloud: \(name) was disconnected"
            case .stopped: "Not read aloud: reading replies was stopped"
            case .notStarted: "Not read aloud: it did not start playing"
            case .noText: "Not read aloud: it had no text"
            }
        }

        var reason: String {
            switch self {
            case .inFront: "its conversation was in front when it finished"
            case .replaced: "something newer from its conversation replaced it"
            case .dictationStarted: "a dictation started before it played"
            case .cancelled: "reading it was cancelled"
            case .disconnected: "its conversation was disconnected"
            case .stopped: "reading replies was stopped"
            case .notStarted: "it did not start playing"
            case .noText: "it had no text"
            }
        }
    }

    struct Speaking: Equatable {
        let name: String
        let text: String
        var textOnly = false
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
    private let release: () -> Void
    private let residency: () -> (eviction: Eviction, idleSeconds: Double?)
    private var resident = false
    private var releasing: (task: Task<Void, Never>, eviction: Eviction, idleSeconds: Double?)?
    private let wait: @MainActor (Duration) async -> Void
    private let inFront: @MainActor (String) async -> Bool
    private let duck: (Bool) -> Void
    private let duckGrace: Duration
    private let mayShow: () -> Bool
    private var ducked = false
    private var duckGraceTask: Task<Void, Never>?
    private var nextOrder = 0
    private(set) var queued: [Queued] = [] { didSet { noteBusy() } }
    private var generating: [String: Preparing] = [:] { didSet { noteBusy() } }
    private var checkingNotice: [String: Task<Void, Never>] = [:] { didSet { noteBusy() } }
    private var playing: Queued? { didSet { noteBusy() } }
    private var heard: Queued?
    private var replay: Queued? { didSet { noteBusy() } }
    private var answering: (item: Queued, stillTrue: () -> Bool)? { didSet { noteBusy() } }
    private var playingCheck: (() -> Bool)?
    private var announced = false { didSet { noteBusy() } }
    private var wasBusy = false
    var onBusyChange: ((Bool) -> Void)?

    private var hasWorkAhead: Bool {
        !queued.isEmpty || !generating.isEmpty || !checkingNotice.isEmpty || replay != nil || answering != nil
            || !progressChecks.isEmpty
    }

    private var busy: Bool { hasWorkAhead || (playing != nil && !announced) }

    private var busyCheckPending = false

    private func noteBusy() {
        guard onBusyChange != nil, !busyCheckPending else { return }
        busyCheckPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            busyCheckPending = false
            let now = busy
            guard now != wasBusy else { return }
            wasBusy = now
            onBusyChange?(now)
        }
    }
    private var playingRequested: Set<String> = []
    private var noticed: [String: AgentAttention] = [:]
    private var lastReply: Queued?
    private var progressChecks: [String: Task<Void, Never>] = [:] { didSet { noteBusy() } }
    private(set) var pendingRequested: Set<String> = [] {
        didSet { if pendingRequested != oldValue { onPendingChange?() } }
    }
    var onSpeaking: ((Speaking?) -> Void)?
    var onHeard: ((Heard) -> Void)?
    var onUnread: ((Unread, _ origin: String) -> Void)?

    private static func described(_ origin: String?, _ agent: String?) -> String {
        "reply \(origin.map { "to request \($0)" } ?? "with no request") from \(agent ?? "an agent")"
    }

    private func unheard(_ why: Unread, _ source: Source) {
        note("\(Self.described(source.origin, source.agent)) not read aloud: \(why.reason)")
        if let origin = source.origin { onUnread?(why, origin) }
    }
    private let note: (String) -> Void
    var onPendingChange: (() -> Void)?
    var pendingSummaries: Int { generating.count }

    init(
        client: any LLMClient, permits: @escaping @Sendable (Connection) -> Bool, speech: any SpeechSynthesizing,
        silencer: SpeechSilencer = .shared, settings: @escaping () -> SpokenResultSettings, connection: @escaping (String) -> Connection?,
        deadlineSeconds: Double = 30, describeDeadlineSeconds: Double = 5, warm: @escaping () -> Void = {},
        release: @escaping () -> Void = {},
        residency: @escaping () -> (eviction: Eviction, idleSeconds: Double?) = { (.fastest, nil) },
        wait: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        inFront: @escaping @MainActor (String) async -> Bool = { _ in false },
        duck: @escaping (Bool) -> Void = { _ in },
        duckGrace: Duration = .seconds(1),
        mayShow: @escaping () -> Bool = { true },
        note: @escaping (String) -> Void = { Log.agents.notice("\($0, privacy: .public)") }
    ) {
        self.note = note
        self.client = client
        self.permits = permits
        self.speech = speech
        self.silencer = silencer
        self.settings = settings
        self.connection = connection
        self.deadlineSeconds = deadlineSeconds
        self.describeDeadlineSeconds = describeDeadlineSeconds
        self.warm = warm
        self.release = release
        self.residency = residency
        self.wait = wait
        self.inFront = inFront
        self.duck = duck
        self.duckGrace = duckGrace
        self.mayShow = mayShow
        speech.onStarted = { [weak self] in self?.started() }
        speech.onFinished = { [weak self] in self?.ended() }
        silencer.register(speech)
        silencer.onAvailable = { [weak self] in self?.playNext() }
        silencer.onBusy = { [weak self] in self?.dismissed() }
        if settings().enabled, residency().eviction == .fastest { load() }
    }

    func settingsChanged() {
        guard settings().enabled else {
            stop()
            return releaseVoice()
        }
        if settings().textOnly {
            releaseVoice()
            showSpokenAsText()
            return playNext()
        }
        let residency = residency()
        if residency.eviction == .fastest { return load() }
        if let releasing, releasing.eviction != residency.eviction || releasing.idleSeconds != residency.idleSeconds {
            cancelRelease()
        }
        settle()
    }

    func voiceUsedElsewhere() {
        resident = true
        settle()
    }

    func releaseVoice() {
        cancelRelease()
        resident = false
        release()
    }

    private func load() {
        guard !settings().textOnly else { return }
        cancelRelease()
        guard !resident else { return }
        resident = true
        warm()
    }

    private func unload() {
        cancelRelease()
        guard resident else { return }
        resident = false
        release()
    }

    private func cancelRelease() {
        releasing?.task.cancel()
        releasing = nil
    }

    var isIdle: Bool {
        !hasWorkAhead && playing == nil && !speech.isSpeaking
    }

    private func settle() {
        guard resident, isIdle, releasing == nil else { return }
        let residency = residency()
        switch EvictionPolicy.afterDictation(mode: residency.eviction, idleSeconds: residency.idleSeconds) {
        case .keepLoaded: break
        case .evictNow: unload()
        case .scheduleIdleCheck(let after):
            let wait = wait
            let task = Task { [weak self] in
                await wait(.milliseconds(Int((after * 1000).rounded(.up))))
                guard !Task.isCancelled, let self else { return }
                self.releasing = nil
                guard self.isIdle else { return }
                self.unload()
            }
            releasing = (task, residency.eviction, residency.idleSeconds)
        }
    }

    func stop() {
        defer {
            settle()
            setDucked(false)
        }
        if let playing, !announced { report([playing]) { _ in .stopped } }
        report(queued) { _ in .stopped }
        for key in Array(generating.keys) { drop(preparing: key) { _ in .stopped } }
        for task in checkingNotice.values { task.cancel() }
        checkingNotice = [:]
        for task in progressChecks.values { task.cancel() }
        progressChecks = [:]
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
        defer { settle() }
        let why = { Unread.disconnected(name: $0) }
        drop(preparing: conversation, why)
        drop(preparing: Self.requestedKey(conversation), why)
        pendingRequested.remove(conversation)
        noticed[conversation] = nil
        checkingNotice.removeValue(forKey: conversation)?.cancel()
        drop(queuedWhere: { $0.conversation == conversation }, why)
        if replay?.conversation == conversation { replay = nil }
        if answering?.item.conversation == conversation { answering = nil }
        if heard?.conversation == conversation { heard = nil }
        if lastReply?.conversation == conversation { lastReply = nil }
        stopStillWorking(conversation: conversation)
        guard let playing, playing.conversation == conversation else { return }
        if !announced { report([playing], why) }
        self.playing = nil
        speech.stop()
        if announced {
            announced = false
            onSpeaking?(nil)
        }
        playNext()
    }

    func withdraw(conversation: String) {
        stopStillWorking(conversation: conversation)
        defer { settle() }
        let why = { Unread.cancelled(name: $0) }
        drop(preparing: conversation, why)
        drop(preparing: Self.requestedKey(conversation), why)
        checkingNotice.removeValue(forKey: conversation)?.cancel()
        drop(queuedWhere: { $0.conversation == conversation }, why)
        noticed[conversation] = nil
        pendingRequested.remove(conversation)
        guard let playing, playing.conversation == conversation, !playing.replayed, !announced else { return }
        report([playing], why)
        self.playing = nil
        speech.stop()
        playNext()
    }

    private static func requestedKey(_ conversation: String) -> String { conversation + "\u{1F}requested" }

    private func report(_ items: [Queued], sparing answered: String? = nil, _ why: (String) -> Unread) {
        for item in items {
            for source in item.unheard where source.origin == nil || source.origin != answered { unheard(why(item.name), source) }
        }
    }

    private func drop(preparing key: String, sparing answered: String? = nil, _ why: (String) -> Unread) {
        guard let preparing = generating.removeValue(forKey: key) else { return }
        preparing.task.cancel()
        if preparing.origin == nil || preparing.origin != answered {
            unheard(why(preparing.name), Source(origin: preparing.origin, failure: nil, agent: preparing.agent))
        }
    }

    private func drop(queuedWhere matches: (Queued) -> Bool, sparing answered: String? = nil, _ why: (String) -> Unread) {
        report(queued.filter(matches), sparing: answered, why)
        queued.removeAll(where: matches)
    }

    private func supersede(_ conversation: String, requested: Bool, by origin: String?) {
        let why = { Unread.replaced(name: $0) }
        stopStillWorking(conversation: conversation)
        drop(preparing: conversation, sparing: origin, why)
        if requested { drop(preparing: Self.requestedKey(conversation), sparing: origin, why) }
        drop(queuedWhere: { $0.conversation == conversation && !$0.refusal && (requested || !$0.requested) }, sparing: origin, why)
        guard let playing, playing.conversation == conversation, !playing.replayed, !playing.refusal, !announced,
              requested || !playing.requested else { return }
        report([playing], sparing: origin, why)
        self.playing = nil
        playingRequested = []
        speech.stop()
        playNext()
    }

    func finished(
        conversation: String, handle: String, answer: String, requested: Bool = false, origin: String? = nil, cause: SpokenResult.Cause? = nil,
        agent: String? = nil
    ) {
        let settings = settings()
        guard settings.enabled else { return }
        let plan = SpokenResult.plan(answer: answer, configured: !settings.connection.isEmpty)
        announce(
            conversation: conversation, handle: handle, plan == .nothing && requested ? .speak(SpokenResult.noTextBody) : plan,
            requested: requested, origin: origin, cause: cause, agent: agent, reply: plan == .nothing ? nil : answer)
    }

    func ended(conversation: String, handle: String, body: String, requested: Bool, origin: String? = nil, agent: String? = nil) {
        guard settings().enabled else { return }
        announce(conversation: conversation, handle: handle, .speak(body), requested: requested, origin: origin, agent: agent)
    }

    private func announce(
        conversation: String, handle: String, _ plan: SpokenResult.Plan, requested: Bool, origin: String?, cause: SpokenResult.Cause? = nil,
        agent: String? = nil, reply: String? = nil
    ) {
        let source = Source(origin: origin, failure: nil, agent: agent)
        let settings = settings()
        let usable = connection(settings.connection).flatMap { permits($0) ? $0 : nil }
        if plan == .nothing {
            unheard(.noText, source)
            return
        }
        load()
        supersede(conversation, requested: requested, by: origin)
        if requested { pendingRequested.insert(conversation) }
        let key = requested ? Self.requestedKey(conversation) : conversation
        let inFront = inFront
        let order = nextOrder
        nextOrder += 1
        generating[key] = Preparing(task: Task { [weak self] in
            let shown = requested ? false : await inFront(conversation)
            guard !Task.isCancelled, let self else { return }
            guard !shown else {
                self.generating.removeValue(forKey: key)
                self.unheard(.inFront(name: handle), source)
                return self.settle()
            }
            var summary = Summary()
            var summarizedBy: String?
            switch plan {
            case .nothing: return
            case .speak(let spoken): summary.text = spoken
            case .summarize(let input):
                guard let usable else {
                    summary.failure = Summary.unusable
                    break
                }
                let othersWait = self.playing != nil || !self.queued.isEmpty || self.generating.keys.contains { $0 != key }
                let request = SpokenResult.request(
                    answer: input, asked: cause?.asked(naming: othersWait), prompt: settings.effectivePrompt, tokenizer: Tokenizer())
                summary = await self.summary(of: request, connection: usable, handle: handle, deadline: self.deadlineSeconds)
                summarizedBy = usable.name
            }
            guard !Task.isCancelled else { return }
            self.generating.removeValue(forKey: key)
            guard self.settings().enabled else {
                self.unheard(.stopped, source)
                return self.settle()
            }
            self.enqueue(summary.text.isEmpty
                ? Queued(
                    conversation: conversation, name: handle, body: SpokenResult.unavailableBody, unavailable: true, requested: requested,
                    order: order, origin: origin, agent: agent, failure: summary.failure, cause: cause, reply: reply)
                : Queued(
                    conversation: conversation, name: handle, body: summary.text, requested: requested, order: order, connection: summarizedBy,
                    origin: origin, agent: agent, returned: summary.returned, cause: cause, reply: reply))
        }, name: handle, origin: origin, agent: agent)
    }

    struct Summary {
        static let unusable = "The AI service for summaries can\u{2019}t be used."
        var text = ""
        var returned: String?
        var failure: String?
    }

    private func summary(of request: SpokenResult.Request, connection: Connection, handle: String, deadline: Double) async -> Summary {
        let client = client
        do {
            let returned = SpokenResult.spoken(summary: try await runWithDeadline(seconds: deadline) {
                try await client.complete(system: request.system, user: request.user, connection: connection)
            })
            guard !returned.isEmpty else { return Summary(failure: "The AI service returned no text.") }
            let held = SpokenResult.held(returned)
            return Summary(text: held.text, returned: held.shortened ? returned : nil)
        } catch {
            let reason = error is DeadlineExceeded ? "The summary took too long." : RewriteService.sanitizedReason(for: error)
            Log.agents.info("spoken result not generated: \(reason, privacy: .public)")
            return Summary(failure: reason)
        }
    }

    func attention(conversation: String, handle: String, _ attention: AgentAttention?, requested: Bool = false) {
        stopStillWorking(conversation: conversation)
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
        load()
        drop(preparing: conversation) { .replaced(name: $0) }
        let inFront = inFront
        checkingNotice[conversation] = Task { [weak self] in
            let shown = requested ? false : await inFront(conversation)
            guard !Task.isCancelled, let self else { return }
            guard !shown, self.settings().enabled else {
                self.checkingNotice.removeValue(forKey: conversation)
                return self.settle()
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

    var wantsStillWorking: Bool { settings().enabled && settings().stillWorking }

    func stillWorking(conversation: String, handle: String, while working: @escaping @MainActor () -> Bool) {
        guard wantsStillWorking, progressChecks[conversation] == nil, quiet(conversation), silent, free else { return }
        load()
        let inFront = inFront
        progressChecks[conversation] = Task { [weak self] in
            let shown = await inFront(conversation)
            guard !Task.isCancelled, let self else { return }
            self.progressChecks.removeValue(forKey: conversation)
            guard !shown, working(), self.wantsStillWorking, self.quiet(conversation), self.silent, self.free else { return self.settle() }
            self.load()
            self.play(
                Queued(conversation: conversation, name: handle, body: SpokenResult.stillWorkingBody, notice: true, progress: true),
                while: { [weak self] in working() && self?.wantsStillWorking == true })
        }
    }

    func stopStillWorking(conversation: String) {
        progressChecks.removeValue(forKey: conversation)?.cancel()
        if playing?.progress == true, playing?.conversation == conversation, !announced { playing = nil; speech.stop() }
    }

    private func quiet(_ conversation: String) -> Bool {
        playing?.conversation != conversation && !queued.contains { $0.conversation == conversation }
            && generating[conversation] == nil && generating[Self.requestedKey(conversation)] == nil
            && checkingNotice[conversation] == nil && noticed[conversation] == nil
    }

    private var free: Bool {
        settings().textOnly ? !silencer.isBusy && mayShow() : silencer.isAvailable(for: speech) && !speech.isSpeaking
    }

    private var silent: Bool {
        playing == nil && queued.isEmpty && generating.isEmpty && checkingNotice.isEmpty && replay == nil && answering == nil
    }

    func describe(_ prompt: AgentPrompt, handle: String) async -> String? {
        let described = await description(of: prompt, handle: handle)?.text
        return described == SpokenResult.notice(.waiting(prompt)) ? nil : described
    }

    func refused(conversation: String, _ line: String) {
        guard settings().enabled else { return }
        load()
        enqueue(Queued(conversation: conversation, name: "", body: line, notice: true, standalone: true, refusal: true))
    }

    func answer(conversation: String, handle: String, _ text: String, whileTrue stillTrue: @escaping () -> Bool) -> Bool {
        guard settings().enabled else { return false }
        stopStillWorking(conversation: conversation)
        if !conversation.isEmpty {
            checkingNotice.removeValue(forKey: conversation)?.cancel()
            queued.removeAll { $0.conversation == conversation && $0.notice && !$0.refusal }
        }
        load()
        answering = (Queued(conversation: conversation, name: handle, body: text, notice: true, standalone: true), stillTrue)
        playNext()
        return true
    }

    private func description(of prompt: AgentPrompt, handle: String) async -> (text: String, connection: String)? {
        let settings = settings()
        guard settings.isOn, let connection = connection(settings.connection), permits(connection),
              let request = SpokenResult.waitingRequest(prompt, tokenizer: Tokenizer())
        else { return nil }
        let text = await summary(of: request, connection: connection, handle: handle, deadline: describeDeadlineSeconds).text
        return text.isEmpty ? nil : (text, connection.name)
    }

    var readsReplies: Bool { settings().enabled }

    var displayed: Speaking? {
        guard let playing, playing.shownOnly, announced else { return nil }
        return Speaking(name: playing.name, text: playing.body, textOnly: true)
    }

    func panelFreed() { playNext() }

    func yieldPanel() {
        guard var current = playing, current.shownOnly else { return }
        current.heardAlready = true
        playing = nil
        playingCheck = nil
        playingRequested = []
        announced = false
        queued.insert(current, at: 0)
    }

    private func showSpokenAsText() {
        guard var current = playing, !current.shownOnly else { return }
        current.heardAlready = announced
        playing = nil
        playingCheck = nil
        playingRequested = []
        if announced {
            announced = false
            onSpeaking?(nil)
        }
        queued.insert(current, at: 0)
        speech.stop()
    }

    func dismissed() {
        guard playing?.shownOnly == true else { return }
        ended()
    }
    var hasReplyToRepeat: Bool { heard != nil }

    func repeatLast() -> Replay {
        guard settings().enabled else { return .off }
        guard let heard else { return .nothingHeard }
        load()
        replay = heard
        playNext()
        return .repeating(heard.name)
    }

    var hasReplyToRead: Bool { lastReply?.reply != nil }

    func readWholeLast() -> Replay {
        guard settings().enabled else { return .off }
        guard var whole = lastReply, let reply = whole.reply else { return .nothingHeard }
        load()
        whole.body = SpokenResult.whole(reply)
        replay = whole
        playNext()
        return .repeating(whole.name)
    }

    private func enqueue(_ item: Queued) {
        var item = item
        if item.order == nil {
            item.order = nextOrder
            nextOrder += 1
        }
        let order = item.order ?? 0
        drop(queuedWhere: {
            $0.conversation == item.conversation && $0.refusal == item.refusal && (item.requested || !$0.requested) && (!item.notice || $0.notice)
        }, sparing: item.origin) {
            .replaced(name: $0)
        }
        queued.insert(item, at: queued.firstIndex { ($0.order ?? 0) > order } ?? queued.endIndex)
        if !item.notice { note("\(Self.described(item.origin, item.agent)) queued to be read") }
        playNext()
    }

    private func started() {
        guard let playing, !announced else { return }
        if let check = playingCheck {
            playingCheck = nil
            guard check() else { return playing.shownOnly ? ended() : speech.stop() }
        }
        announced = true
        pendingRequested.subtract(playingRequested)
        playingRequested = []
        if !playing.replayed { heard = playing }
        if !playing.replayed, !playing.notice {
            if let latest = playing.mergedReplies.last { lastReply = latest } else if playing.reply != nil { lastReply = playing }
        }
        syncDuck()
        onSpeaking?(Speaking(name: playing.name, text: playing.body, textOnly: playing.shownOnly))
        if !playing.replayed, !playing.standalone, !playing.notice, !playing.heardAlready {
            let sources = playing.merged.isEmpty ? [Source(origin: playing.origin, failure: playing.failure, agent: playing.agent)] : playing.merged
            for source in sources {
                note("\(Self.described(source.origin, source.agent)) \(playing.shownOnly ? "shown as text" : "read aloud")")
                guard playing.merged.isEmpty || source.origin != nil else { continue }
                onHeard?(Heard(
                    conversation: playing.conversation, name: playing.name, text: playing.text,
                    connection: playing.connection, origin: source.origin,
                    attempt: playing.shownOnly ? nil : speech.attempt, reader: playing.shownOnly ? nil : speech.reader,
                    reason: !playing.shownOnly && speech.reader == .macOS ? speech.macOSReason : nil,
                    returned: playing.returned, failure: source.failure, cause: playing.merged.isEmpty ? playing.cause : nil))
            }
        }
    }

    private func ended() {
        if playing?.shownOnly != true, silencer.resumesInterrupted, var interrupted = playing, interrupted.notice, !interrupted.progress {
            interrupted.replayed = true
            queued.insert(interrupted, at: 0)
        }
        if let playing, !announced {
            let busy = silencer.isBusy
            report([playing]) { _ in busy ? .dictationStarted : .notStarted }
        }
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
        advance()
        syncDuck()
    }

    // Held while a reply is audible and for a short grace after it, so a next reply that speaks within the
    // grace does not pump the other audio; one still being prepared past it gets the audio back until it speaks.
    private func syncDuck() {
        if announced { return setDucked(playing?.shownOnly != true) }
        guard ducked, duckGraceTask == nil else { return }
        let grace = duckGrace
        duckGraceTask = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, let self else { return }
            self.duckGraceTask = nil
            if !self.announced { self.setDucked(false) }
        }
    }

    private func setDucked(_ wanted: Bool) {
        duckGraceTask?.cancel()
        duckGraceTask = nil
        guard wanted != ducked else { return }
        ducked = wanted
        duck(wanted)
    }

    private func advance() {
        guard settings().enabled else {
            report(queued) { _ in .stopped }
            queued = []
            pendingRequested = []
            replay = nil
            answering = nil
            return
        }
        guard playing == nil, free else { return }
        if let answering {
            self.answering = nil
            guard answering.stillTrue() else { return advance() }
            return play(answering.item, while: answering.stillTrue)
        }
        if let replay {
            self.replay = nil
            var replayed = replay
            replayed.replayed = true
            return play(replayed)
        }
        guard !queued.isEmpty else { return settle() }
        var next = queued.removeFirst()
        if next.unavailable && !next.requested {
            let merged = queued.filter { $0.unavailable && !$0.requested }
            let notice = SpokenResult.unavailable(names: [next.name] + merged.map(\.name))
            queued.removeAll { $0.unavailable && !$0.requested }
            next = Queued(
                conversation: next.conversation, name: notice.name, body: notice.body, unavailable: true, origin: next.origin, agent: next.agent,
                merged: merged.isEmpty ? [] : ([next] + merged).map { Source(origin: $0.origin, failure: $0.failure, agent: $0.agent) },
                failure: next.failure, cause: merged.isEmpty ? next.cause : nil, reply: merged.isEmpty ? next.reply : nil,
                mergedReplies: merged.isEmpty ? [] : ([next] + merged).filter { $0.reply != nil })
        }
        play(next, requested: next.requested ? [next.conversation] : [])
    }

    private func play(_ item: Queued, while stillTrue: (() -> Bool)? = nil, requested: Set<String> = []) {
        var item = item
        item.shownOnly = settings().textOnly
        playingCheck = stillTrue
        playingRequested = requested
        guard !item.shownOnly else {
            playing = item
            return started()
        }
        resident = true
        playing = item
        silencer.speak(item.text, voice: settings().voice, with: speech)
        if !speech.isSpeaking, playing == item {
            report([item]) { _ in .notStarted }
            playing = nil
            pendingRequested.subtract(playingRequested)
            playingRequested = []
            settle()
        }
    }
}
