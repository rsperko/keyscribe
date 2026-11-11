import Foundation
import KeyScribeKit

struct AgentSnapshot {
    let names: [String: String]
    let conversations: [AgentConversation]
    let current: String?
    var namesAvailable = true
    var disconnected: [String: String] = [:]
    var shared: [String: AgentRecipient.SharedName] = [:]
    var late: [String: String] = [:]
    var lateShared: [String: AgentRecipient.SharedName] = [:]
    var rows: [String] { conversations.map(\.id) }
    private var merged: (names: [String: String], shared: [String: AgentRecipient.SharedName]) {
        AgentRecipient.addingLate(late, sharing: lateShared, to: names.merging(disconnected) { kept, _ in kept }, sharing: shared)
    }
    var addressable: [String: String] { merged.names }
    var sharedNames: [String: AgentRecipient.SharedName] { merged.shared }
    var spokenNames: [String] { AgentRecipient.spokenNames(addressable, shared: sharedNames) }
    var afterVerbNames: [String] { AgentRecipient.afterVerbNames(sharedNames) }
}

@MainActor
protocol AgentTakeHost: AnyObject {
    var agents: AgentHub? { get }
    var spokenUpdates: SpokenResultOutput? { get }
    var codingAgentsEnabled: Bool { get }
    var isBusy: Bool { get }
    var takeIdentity: AnyObject? { get }
    var takeMode: Mode? { get }
    var eligibleModes: [Mode]? { get }
    var takePlan: ResolvedConfig { get }
    var captureOrigin: VoiceCommandOrigin? { get }
    var captureWasLost: Bool { get }
    var stoppedAtLimit: Bool { get }
    var limitPhrase: String { get }
    var voiceCommandStopsAtPress: Int? { get }
    var spokenEdits: String? { get set }
    var agentSnapshot: AgentSnapshot? { get set }
    var agentRecipient: AgentRecipient.Frozen? { get set }
    var agentFrontTask: Task<Void, Never>? { get set }
    var agentFrontCutoff: ContinuousClock.Instant? { get }
    func noteAgentDestination(_ id: String, facts: [HistoryEntry.Fact])
    func redrawRecordingHUD()
    func lease(for feature: Feature?, stopsAtPress: Int?) -> TakeLease
    func rememberResult(_ text: String)
    func dictationPipeline(for mode: Mode?, willRewrite: Bool) -> Pipeline
    func rewriteAndDeliver(_ routed: PhaseBResult, mode: Mode, to id: String, facts: [HistoryEntry.Fact], heard: String) async
    func clearRewriteEscapeHatch()
    func finishError(_ message: String, action: HUDErrorAction?)
    func finishNoSpeech()
    func finishDiscarded(message: String)
    func finishCommandCaptureLost()
    func finishTruncatedCapture(transcript: String)
    func cancelQuietly()
    func finishAgent(
        state: HUDState, outcome: DictationOutcome, heard: String, body: String, transformed: String?,
        rewrite: RewriteDetails?, transitioned: Bool, hideAfter: Double?, summary: String?,
        recorded: String?, facts: [HistoryEntry.Fact], onRecorded: ((HistoryEntry) -> Void)?
    ) -> Bool
}

@MainActor
final class AgentTake {
    private let hud: HUDChannel
    private let output: AgentOutput
    private let voiceCommands: VoiceCommandRunning
    private let submitKey: (Mode.Submit) async -> Void
    private let snapshotAsync: @MainActor () async -> TargetSnapshot
    private let agentClipboard: AgentClipboard
    weak var host: AgentTakeHost?

    var frontReadingGrace: Duration = .seconds(1)
    var placeNamesGrace: Duration = .seconds(1)
    var promptBoxConfirmation: Duration = .seconds(2)

    init(
        hud: HUDChannel, output: AgentOutput, voiceCommands: VoiceCommandRunning,
        submitKey: @escaping (Mode.Submit) async -> Void, snapshotAsync: @escaping @MainActor () async -> TargetSnapshot,
        agentClipboard: AgentClipboard
    ) {
        self.hud = hud
        self.output = output
        self.voiceCommands = voiceCommands
        self.submitKey = submitKey
        self.snapshotAsync = snapshotAsync
        self.agentClipboard = agentClipboard
    }

    func freezeRecipient() {
        guard let host, let agents = host.agents, host.codingAgentsEnabled,
              host.eligibleModes?.contains(where: { $0.output == .agent }) == true
        else { return }
        agents.refresh()
        agents.readPlaces()
        let snapshot = AgentSnapshot(
            names: agents.names, conversations: agents.recordingOrder, current: agents.current,
            namesAvailable: agents.namesProblem == nil, disconnected: agents.disconnectedNames, shared: agents.sharedNames)
        host.agentSnapshot = snapshot
        guard let mode = host.takeMode, mode.output == .agent else { return }
        host.agentRecipient = AgentRecipient.initial(
            target: mode.agent.target, current: snapshot.current, names: snapshot.names)
        followAgentInFront(target: mode.agent.target, snapshot: snapshot, through: agents)
    }

    private func settlePlaceNames(_ agents: AgentHub) async -> Bool {
        if let reading = agents.placeTracker?.reading {
            _ = try? await runWithDeadline(seconds: DictationController.seconds(placeNamesGrace)) { await reading.value }
        }
        let ids = (host?.agentSnapshot?.conversations ?? agents.directory.conversations).map(\.id)
        return agents.placeTracker?.reading == nil && !agents.placesUnread(ids)
    }

    private func followAgentInFront(target: Mode.Agent.Target, snapshot: AgentSnapshot, through agents: AgentHub) {
        guard target == .current, let host, let identity = host.takeIdentity else { return }
        host.agentFrontTask?.cancel()
        host.agentFrontTask = Task { @MainActor [weak host, weak agents] in
            guard let shown = await agents?.sessionInFrontWithoutAsking(), let host, !Task.isCancelled,
                  host.takeIdentity === identity,
                  host.agentFrontCutoff.map({ ContinuousClock.now <= $0 }) ?? true,
                  snapshot.rows.contains(shown.id) || snapshot.disconnected.values.contains(shown.id),
                  host.captureOrigin?.leaving(shown).session == shown.id
            else { return }
            host.agentRecipient = AgentRecipient.Frozen(id: shown.id, source: .front)
            host.redrawRecordingHUD()
        }
    }

    private func settleAgentInFront() async {
        guard let task = host?.agentFrontTask else { return }
        let left = host?.agentFrontCutoff.map { ContinuousClock.now.duration(to: $0) } ?? frontReadingGrace
        if left > .zero { _ = try? await runWithDeadline(seconds: DictationController.seconds(left)) { await task.value } }
        task.cancel()
    }

    var roster: AgentRoster? {
        guard let host, host.takeMode?.output == .agent, let agents = host.agents, let snapshot = host.agentSnapshot else { return nil }
        return AgentRoster(
            frozen: snapshot.conversations, live: agents.directory.conversations, recipient: host.agentRecipient,
            namesAvailable: snapshot.namesAvailable, disconnected: snapshot.namesAvailable ? agents.disconnected : [])
    }

    func finish(routed: PhaseBResult, heard: String, mode: Mode) async {
        guard let host else { return }
        guard let agents = host.agents, host.codingAgentsEnabled else {
            host.finishError("Talking to coding agents is turned off", action: nil)
            return
        }
        guard !routed.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            host.finishNoSpeech()
            return
        }
        let pressed = host.agentSnapshot ?? AgentSnapshot(
            names: agents.names, conversations: agents.recordingOrder, current: agents.current,
            namesAvailable: agents.namesProblem == nil, disconnected: agents.disconnectedNames, shared: agents.sharedNames)
        func recipient(in snapshot: AgentSnapshot) -> AgentRecipient.Frozen? {
            host.agentRecipient ?? AgentRecipient.initial(target: mode.agent.target, current: snapshot.current, names: snapshot.names)
        }
        switch VoiceCommandGrammar.parse(routed.transcript) {
        case .goBack:
            host.agentFrontTask?.cancel()
            await builtInFromAgent(
                VoiceCommandGrammar.goBack, heard: heard, facts: AgentHistoryFacts.goBack(frozen: recipient(in: pressed), conversations: pressed.conversations))
            return
        case .cancel:
            host.agentFrontTask?.cancel()
            host.finishDiscarded(message: AgentOutput.cancelledLine)
            return
        case .repeatSummary:
            host.agentFrontTask?.cancel()
            await builtInFromAgent(
                VoiceCommandGrammar.repeatSummary[0], heard: heard,
                facts: AgentHistoryFacts.repeatSummary(frozen: recipient(in: pressed), conversations: pressed.conversations))
            return
        default:
            break
        }
        let namesSettled = await settlePlaceNames(agents)
        if Task.isCancelled { return }
        let snapshot = {
            var frozen = pressed
            if frozen.namesAvailable, agents.namesProblem == nil {
                frozen.late = agents.names.merging(agents.disconnectedNames) { kept, _ in kept }
                frozen.lateShared = agents.sharedNames
            }
            return frozen
        }()
        func frozenRecipient() -> AgentRecipient.Frozen? { recipient(in: snapshot) }
        if let request = AgentRename.request(in: routed.transcript) {
            await renameFromAgent(request, in: routed.transcript, recipient: frozenRecipient, through: agents, heard: heard, mode: mode, snapshot: snapshot)
            return
        }
        let read = host.takePlan.agentAddressReader(for: routed.transcript, mode: mode)
        if let query = AgentStatusQuery.parse(
            routed.transcript, names: snapshot.spokenNames, namesKnown: snapshot.namesAvailable,
            read: read, afterVerb: snapshot.afterVerbNames) {
            await answerStatus(query, recipient: frozenRecipient, through: agents, heard: heard, mode: mode, snapshot: snapshot)
            return
        }
        let address = AgentAddress.parse(
            routed.transcript, names: snapshot.spokenNames, namesKnown: snapshot.namesAvailable,
            read: read, afterVerb: snapshot.afterVerbNames)
        if AgentRecipient.usesDefault(address) {
            await settleAgentInFront()
            if Task.isCancelled { return }
        } else {
            host.agentFrontTask?.cancel()
        }
        let frozen = frozenRecipient()
        let resolution = AgentRecipient.resolve(address, frozen: frozen, rows: snapshot.rows, names: snapshot.addressable, shared: snapshot.sharedNames)
        let facts = AgentHistoryFacts.facts(
            address: address, resolution: resolution, frozen: frozen, conversations: snapshot.conversations)
        if host.captureWasLost {
            if case .deliver(_, let body, _) = resolution { host.finishTruncatedCapture(transcript: body) } else { host.finishCommandCaptureLost() }
            return
        }
        if !namesSettled, AgentRecipient.usesDefault(address), case .deliver(_, let body, _) = resolution {
            finishAgent(state: .error(message: "Not sent: couldn\u{2019}t check conversation names yet. Say it again, or start with \u{201C}tell\u{201D} and a name or conversation number.", action: nil, heard: HeardExcerpt(heard: body)),
                        outcome: .failed, heard: heard, body: body, transformed: nil, rewrite: nil, facts: facts)
            return
        }
        if let (id, front, body) = Self.target(of: resolution), snapshot.disconnected.values.contains(id) || agents.isExcluded(id) {
            let name = snapshot.disconnected.first { $0.value == id }?.key ?? "That conversation"
            let line = front ? "The conversation in front is disconnected" : "\(name) is disconnected"
            finishAgent(state: .error(message: line, action: .openCodingAgents(mode.id), heard: HeardExcerpt(heard: body)),
                        outcome: .failed, heard: heard, body: body, transformed: nil, rewrite: nil, facts: facts)
            return
        }
        if let id = resolution.makesCurrent { agents.makeCurrent(id) }

        switch resolution {
        case .select(let id):
            finishAgent(state: .commandDone(summary: "Recipient: \(agents.handle(of: id) ?? "it")", detail: mode.name),
                        outcome: .inserted, heard: heard, body: "", transformed: nil, rewrite: nil, facts: facts)
        case .open(let id):
            let handle = agents.handle(of: id) ?? "it"
            hud.present(.transcribing(mode: mode.name, status: "Opening \(handle)\u{2026}"))
            let lease = host.lease(for: .codingAgents, stopsAtPress: nil)
            let place = host.captureOrigin
            let shown = place == nil ? nil : await agents.sessionInFront { [weak self] app in
                guard !Task.isCancelled else { return }
                self?.hud.present(.transcribing(mode: mode.name, status: "Allow access to \(app) to remember where you were"))
            }
            let origin = place?.leaving(shown)
            if Task.isCancelled { return }
            let result = await agents.open(id, stillWanted: { lease.stillWanted() }) { [weak self] app in
                guard !Task.isCancelled else { return }
                self?.hud.present(.transcribing(mode: mode.name, status: "Allow access to \(app) to open the tab for \(handle)"))
            }
            let after = DictationController.origin(of: await snapshotAsync())
            let movedSession = result == .exact && origin?.session != nil && origin?.session != id
            if result != .none, movedSession || after != place, lease.stillWanted(), let origin, origin.session != id {
                voiceCommands.recordReturn(to: origin)
            }
            if Task.isCancelled { return }
            let state = result.hudState(handle: handle, detail: mode.name, agent: agents.kind(of: id))
            let outcome: DictationOutcome = if case .notAllowed = result { .failed } else { .inserted }
            finishAgent(state: state, outcome: outcome, heard: heard, body: "", transformed: nil, rewrite: nil,
                        hideAfter: state.errorAction != nil ? 8 : state.indicator == .advisory ? 5 : 2,
                        summary: result.historySummary(handle: handle, agent: agents.kind(of: id)), facts: facts)
        case .ask(let body, let reason):
            let retry = AgentOutput.Retry.matching(routed.transcript, address)
            let line = retry == .open ? AgentOutput.openAskLine : AgentOutput.askLine
            let unconnected = Self.spokenName(reason) == nil ? [] : agents.unconnected
            let meant = Self.spokenName(reason).map { spoken in unconnected.filter { Self.names(spoken, $0) } } ?? []
            if !meant.isEmpty {
                let shown = Self.unconnectedLine(meant)
                let action = HUDErrorAction.openCodingAgents(mode.id, reveal: meant.map(\.row))
                finishAgent(state: .error(message: shown, action: action, heard: HeardExcerpt(heard: body)),
                            outcome: .failed, heard: heard, body: body, transformed: nil, rewrite: nil, recorded: shown, facts: facts)
                return
            }
            let hint = AgentOutput.unconnectedHint(unconnected.map(\.name))
            let shown = hint.isEmpty ? line(reason, retry, reachable(snapshot, agents, for: retry), frozen?.id) : line(reason, nil, [:], nil) + hint
            let action = hint.isEmpty ? Self.askAction(reason, mode: mode) : .openCodingAgents(mode.id)
            finishAgent(state: .error(message: shown, action: action, heard: HeardExcerpt(heard: body)),
                        outcome: .failed, heard: heard, body: body, transformed: nil, rewrite: nil,
                        recorded: line(reason, nil, [:], nil) + hint, facts: facts)
        case .deliver(let id, let body, _):
            host.noteAgentDestination(id, facts: facts)
            await host.rewriteAndDeliver(
                PhaseBResult(routedModeId: routed.routedModeId, transcript: body), mode: mode, to: id, facts: facts, heard: heard)
        }
    }

    private static func target(of resolution: AgentRecipient.Resolution) -> (id: String, front: Bool, body: String)? {
        switch resolution {
        case .deliver(let id, let body, let source): (id, source == .front, body)
        case .select(let id), .open(let id): (id, false, "")
        case .ask: nil
        }
    }

    private func renameFromAgent(
        _ request: Result<Substring, AgentRename.Problem>, in transcript: String, recipient: @escaping () -> AgentRecipient.Frozen?, through agents: AgentHub, heard: String,
        mode: Mode, snapshot: AgentSnapshot
    ) async {
        guard let host else { return }
        if host.captureWasLost {
            host.finishCommandCaptureLost()
            return
        }
        func edited(_ text: String) -> TakeText {
            TakeText(text, pipeline: host.dictationPipeline(for: mode, willRewrite: false), trimsTrailingPunctuation: false)
        }
        let rename: AgentRename
        switch request {
        case .failure(let problem):
            guard !edited(transcript).discarded else {
                host.agentFrontTask?.cancel()
                host.finishDiscarded(message: DictationController.discardedMessage)
                return
            }
            rename = .invalid(problem)
        case .success(let spoken):
            let edited = edited(String(spoken))
            host.spokenEdits = SpokenEdit.summary(edited.payload.spokenEdits)
            if edited.discarded {
                host.agentFrontTask?.cancel()
                host.finishDiscarded(message: DictationController.discardedMessage)
                return
            }
            let name = edited.isBlank ? "" : edited.localText
            rename = AgentRename.parse(name) ?? AgentRename.name(from: name)
        }
        guard case .rename(let spoken) = rename else {
            host.agentFrontTask?.cancel()
            if case .invalid(let problem) = rename {
                finishAgent(state: .error(message: Self.renameProblem(problem), action: nil, heard: HeardExcerpt(heard: heard)),
                            outcome: .failed, heard: heard, body: "", transformed: nil, rewrite: nil,
                            facts: AgentHistoryFacts.rename(frozen: nil, to: nil, conversations: snapshot.conversations))
            }
            return
        }
        await settleAgentInFront()
        if Task.isCancelled { return }
        let name = AgentHandles.normalize(spoken)
        let frozen = recipient()
        let facts = AgentHistoryFacts.rename(frozen: frozen, to: name, conversations: snapshot.conversations)
        func fail(_ message: String, action: HUDErrorAction? = nil) {
            finishAgent(state: .error(message: message, action: action, heard: HeardExcerpt(heard: heard)),
                        outcome: .failed, heard: heard, body: "", transformed: nil, rewrite: nil, transitioned: true, facts: facts)
        }
        let lease = host.lease(for: .codingAgents, stopsAtPress: nil)
        guard lease.keepActing() else {
            host.cancelQuietly()
            return
        }
        guard let id = frozen?.id else {
            return fail("Switch to a conversation, then say the rename command again", action: .openCodingAgents(mode.id))
        }
        guard let old = agents.handle(of: id) else { return fail("That conversation has ended") }
        do {
            try agents.rename(id, to: name)
        } catch let error as AgentHandles.RenameError {
            return fail(Self.renameProblem(error, name: name))
        } catch {
            return fail("Couldn\u{2019}t save the new name. \(old) is unchanged", action: .openCodingAgents(mode.id))
        }
        agents.makeCurrent(id)
        finishAgent(state: .commandDone(summary: "Renamed \(old) to \(name)", detail: mode.name), outcome: .inserted, heard: heard,
                    body: "", transformed: nil, rewrite: nil, transitioned: true, hideAfter: 4, facts: facts)
    }

    private func answerStatus(
        _ query: AgentStatusQuery, recipient: () -> AgentRecipient.Frozen?, through agents: AgentHub, heard: String, mode: Mode,
        snapshot: AgentSnapshot
    ) async {
        guard let host else { return }
        if host.captureWasLost {
            host.agentFrontTask?.cancel()
            host.finishCommandCaptureLost()
            return
        }
        func stopQuietly() {
            host.cancelQuietly()
        }
        let address: AgentAddress?
        switch query {
        case .whoNeedsMe:
            host.agentFrontTask?.cancel()
            guard host.lease(for: .codingAgents, stopsAtPress: nil).keepActing() else { return stopQuietly() }
            func report() -> (names: [String], complete: Bool) {
                let stale = agents.lastSeen
                let listed = agents.recordingOrder.filter { !agents.isExcluded($0.id) }
                let names = listed.filter { !stale.contains($0.id) && AgentRoster.isWaitingForInput($0) }.map(\.handle)
                let complete = agents.discoveryProblems.isEmpty
                    && listed.allSatisfy { !stale.contains($0.id) && ($0.connectorLive || AgentRoster.isWaitingForInput($0)) }
                return (names, complete)
            }
            let reported = report()
            let line = AgentStatusAnswer.whoNeedsMe(reported.names, complete: reported.complete)
            return answered(line, shown: line, conversation: "", handle: "Who needs me", summary: "Who needs me", heard: heard,
                            facts: AgentHistoryFacts.whoNeedsMe(), whileTrue: { report() == reported })
        case .moreThanAQuestion(let named):
            address = named
        case .waiting(let named):
            address = named
        }
        let frozen: AgentRecipient.Frozen?
        let resolution: AgentRecipient.Resolution
        if let address {
            host.agentFrontTask?.cancel()
            frozen = recipient()
            resolution = AgentRecipient.conversation(
                address, frozen: frozen, rows: snapshot.rows, names: snapshot.addressable, shared: snapshot.sharedNames)
        } else {
            await settleAgentInFront()
            if Task.isCancelled { return }
            frozen = recipient()
            resolution = frozen.map { .deliver(id: $0.id, body: "", source: $0.source) } ?? .ask(body: "", reason: .noRecipient)
        }
        let facts = AgentHistoryFacts.status(address: address, resolution: resolution, frozen: frozen, conversations: snapshot.conversations)
        func fail(_ message: String, action: HUDErrorAction? = nil) {
            finishAgent(state: .error(message: message, action: action, heard: HeardExcerpt(heard: heard)),
                        outcome: .failed, heard: heard, body: "", transformed: nil, rewrite: nil, transitioned: true, facts: facts)
        }
        let lease = host.lease(for: .codingAgents, stopsAtPress: nil)
        guard lease.keepActing() else { return stopQuietly() }
        guard let id = resolution.recipient else {
            if case .ask(_, let reason) = resolution, reason != .noRecipient { return fail(AgentOutput.openAskLine(reason)) }
            return fail("Say the name of the conversation to check on", action: .openCodingAgents(mode.id))
        }
        let name = agents.handle(of: id) ?? snapshot.disconnected.first { $0.value == id }?.key ?? "That conversation"
        if case .moreThanAQuestion = query {
            return fail(
                "Nothing was sent. Say \u{201C}what is \(name) waiting for?\u{201D} to check on it, or start with \u{201C}tell \(name)\u{201D} to send a message")
        }
        if snapshot.disconnected.values.contains(id) || agents.isExcluded(id) {
            return fail("\(name) is disconnected", action: .openCodingAgents(mode.id))
        }
        func observed() -> (conversation: AgentConversation, prompt: AgentPrompt?)? {
            guard let conversation = agents.directory.conversations.first(where: { $0.id == id }) else { return nil }
            return (conversation, AgentRoster.isWaitingForInput(conversation) ? agents.waitingPrompt(of: id) : nil)
        }
        guard let before = observed() else { return fail("That conversation has ended") }
        var description: String?
        if let prompt = before.prompt, AgentStatusAnswer.question(in: prompt) == nil, let spoken = host.spokenUpdates {
            hud.present(.transcribing(mode: mode.name, status: "Checking \(before.conversation.handle)\u{2026}"))
            description = await spoken.describe(prompt, handle: before.conversation.handle)
            if Task.isCancelled { return }
            guard lease.keepActing() else { return stopQuietly() }
        }
        guard let now = observed() else { return fail("That conversation has ended") }
        if now.prompt != before.prompt || now.conversation.state != before.conversation.state { description = nil }
        let handle = now.conversation.handle
        let connected = now.conversation.connectorLive
        let current = !agents.lastSeen.contains(id)
        let line = AgentStatusAnswer.waiting(
            handle: handle, state: now.conversation.state, connected: connected, current: current, prompt: now.prompt,
            description: description)
        let shown = [line, AgentStatusAnswer.hint(handle: handle, state: now.conversation.state, connected: connected, current: current)]
            .compactMap { $0 }.joined(separator: " ")
        answered(line, shown: shown, conversation: id, handle: handle, summary: "Checked \(handle)", heard: heard, facts: facts,
                 whileTrue: {
                     observed().map {
                         $0.prompt == now.prompt && $0.conversation.state == now.conversation.state && $0.conversation.connectorLive == connected
                             && agents.lastSeen.contains(id) != current
                     } ?? false
                 })
    }

    private func answered(
        _ line: String, shown: String, conversation: String, handle: String, summary: String, heard: String, facts: [HistoryEntry.Fact],
        whileTrue stillTrue: @escaping () -> Bool
    ) {
        let enabled = { [weak host] in host?.codingAgentsEnabled == true }
        _ = host?.spokenUpdates?.answer(conversation: conversation, handle: handle, line, whileTrue: { enabled() && stillTrue() })
        finishAgent(state: .advisory(message: shown), outcome: .inserted, heard: heard, body: "", transformed: nil, rewrite: nil,
                    transitioned: true, hideAfter: 8, summary: summary, facts: facts)
    }

    private static func renameProblem(_ problem: AgentRename.Problem) -> String {
        switch problem {
        case .noName: "Say \u{201C}rename this conversation to\u{201D} and the new name. Nothing was sent"
        case .tooLong: "A name can be up to \(AgentRename.nameWords) words. Nothing was sent"
        case .moreAfterName: "Say only the new name after \u{201C}rename this conversation to\u{201D}. Nothing was sent"
        }
    }

    private static func renameProblem(_ error: AgentHandles.RenameError, name: String) -> String {
        switch error {
        case .empty: renameProblem(.noName)
        case .taken: "Another conversation is already called \u{201C}\(name)\u{201D}"
        case .reserved: "\u{201C}Conversation\u{201D} or \u{201C}session\u{201D} followed by a number is how you say a row, so it cannot be a name"
        }
    }

    private func builtInFromAgent(_ transcript: String, heard: String, facts: [HistoryEntry.Fact]) async {
        guard let host else { return }
        let lease = host.lease(for: .codingAgents, stopsAtPress: host.voiceCommandStopsAtPress)
        guard lease.keepActing() else { return }
        let outcome = await voiceCommands.run(
            transcript: transcript, places: [], scripts: [], origin: host.captureOrigin,
            stillWanted: { lease.keepActing() }, onLateResult: { _ in })
        if Task.isCancelled { return }
        guard let shown = VoiceCommandOutput.presentation(of: outcome, resultPrefix: "") else {
            if host.captureWasLost {
                host.finishCommandCaptureLost()
            } else {
                host.cancelQuietly()
            }
            return
        }
        finishAgent(state: shown.state, outcome: shown.failure == nil ? .inserted : .failed, heard: heard, body: "",
                    transformed: nil, rewrite: nil, transitioned: true, hideAfter: shown.hideAfter, summary: shown.result,
                    facts: facts)
    }

    func deliver(
        _ id: String, text: String, heard: String, transformed: String?, rewrite: RewriteDetails?, facts: [HistoryEntry.Fact]
    ) async {
        guard let host else { return }
        host.clearRewriteEscapeHatch()
        if host.captureWasLost {
            host.finishTruncatedCapture(transcript: text)
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            host.finishNoSpeech()
            return
        }
        guard let agents = host.agents, let mode = host.takeMode, host.codingAgentsEnabled else {
            finishAgent(state: .error(message: "Not sent: talking to coding agents was turned off", action: nil, heard: HeardExcerpt(heard: text)),
                        outcome: .failed, heard: heard, body: text, transformed: transformed, rewrite: rewrite, facts: facts)
            return
        }
        if host.stoppedAtLimit {
            finishAgent(
                state: .error(
                    message: "Stopped at the \(host.limitPhrase) limit, so it was not sent. Use \u{201C}Paste last dictation\u{201D} to see what was captured.",
                    action: nil, heard: HeardExcerpt(heard: text)),
                outcome: .failed, heard: heard, body: text, transformed: transformed, rewrite: rewrite, facts: facts)
            return
        }
        let lease = host.lease(for: .codingAgents, stopsAtPress: nil)
        guard lease.keepActing() else { return }
        host.rememberResult(text)
        hud.present(.transcribing(mode: mode.name, status: "Sending to \(agents.handle(of: id) ?? "it")"))
        let clipboard = agentClipboard.note(for: text, attached: agents.takesImages(id))
        var (request, receipt) = await output.deliver(text, to: id, via: agents, images: agentClipboard.images(in: text))
        if case .kept(let handle, .inPromptBox) = receipt,
           let sent = await sendFromPromptBox(id, handle: handle, through: agents, lease: lease, request: request) {
            receipt = sent
        }
        finishAgent(state: AgentOutput.receiptState(receipt, mode: mode.name, heard: text, settingsMode: mode.id, clipboard: clipboard),
                    outcome: AgentOutput.dictationOutcome(receipt),
                    heard: heard, body: text, transformed: transformed, rewrite: rewrite, transitioned: true,
                    facts: facts, awaitingReceipt: (request, receipt))
        speakRefusal(receipt, conversation: id)
    }

    // After a Stop, Claude Code takes only a prompt the user enters, so the connector left the message in the
    // empty box. Return goes only to that conversation, and only when it is the one in front.
    private func sendFromPromptBox(
        _ id: String, handle: String, through agents: AgentHub, lease: TakeLease, request: String
    ) async -> AgentReceipt? {
        guard lease.keepActing(), await agents.sessionInFrontWithoutAsking()?.id == id, lease.keepActing() else { return nil }
        let typedBefore = agents.typedCount(id)
        agents.awaitTypedTurn(of: id, request: request)
        await submitKey(.return)
        let deadline = ContinuousClock.now + promptBoxConfirmation
        while agents.typedCount(id) == typedBefore, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard agents.typedCount(id) > typedBefore else {
            agents.forgetTypedTurn(of: id, request: request)
            return .uncertain(handle)
        }
        return .sent(handle)
    }

    private func reachable(_ snapshot: AgentSnapshot, _ agents: AgentHub, for retry: AgentOutput.Retry) -> [String: String] {
        let frozen = Set(snapshot.addressable.values)
        let listed = agents.recordingOrder.filter { retry == .open || AgentRoster.isAvailable($0) }.map(\.id)
        return agents.names.filter {
            frozen.contains($0.value) && listed.contains($0.value) && !snapshot.disconnected.values.contains($0.value) && !agents.isExcluded($0.value)
        }
    }

    private static func spokenName(_ reason: AgentRecipient.AskReason) -> String? {
        switch reason {
        case .unknownName(let spoken), .soundsLike(let spoken, _): spoken
        default: nil
        }
    }

    static func unconnectedLine(_ meant: [AgentHub.Unconnected]) -> String {
        guard meant.count > 1 else { return "Not sent: \(meant[0].name) isn\u{2019}t connected yet" }
        let names = meant.map(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let groups = names.map { name in
            let same = meant.filter { $0.name == name }
            return same.count == 1 ? name : "\(same.count) \(same[0].agent) conversations in \(same[0].folder)"
        }
        return "Not sent: \(AgentOutput.either(groups, joining: "and")) aren\u{2019}t connected yet"
    }

    private static func names(_ spoken: String, _ unconnected: AgentHub.Unconnected) -> Bool {
        let key = AgentHandles.matchKey(spoken)
        return !key.isEmpty && (key == AgentHandles.matchKey(unconnected.folder) || key == AgentHandles.matchKey(unconnected.name))
    }

    private static func askAction(_ reason: AgentRecipient.AskReason, mode: Mode) -> HUDErrorAction? {
        if case .unknownName = reason { .openCodingAgents(mode.id) } else { nil }
    }

    private func finishAgent(
        state: HUDState, outcome: DictationOutcome, heard: String, body: String, transformed: String?,
        rewrite: RewriteDetails?, transitioned: Bool = false, hideAfter: Double? = nil, summary: String? = nil,
        recorded: String? = nil, facts: [HistoryEntry.Fact], awaitingReceipt awaited: (request: String, receipt: AgentReceipt)? = nil
    ) {
        guard let host, host.finishAgent(
            state: state, outcome: outcome, heard: heard, body: body, transformed: transformed, rewrite: rewrite,
            transitioned: transitioned, hideAfter: hideAfter, summary: summary, recorded: recorded, facts: facts,
            onRecorded: awaited.map { awaited in { [weak output] entry in
                output?.noteRecorded(entry, request: awaited.request)
            } })
        else { return }
        if let awaited { output.replayEarlyReceipts(request: awaited.request, receipt: awaited.receipt) }
    }

    func speakRefusal(_ receipt: AgentReceipt, conversation: String) {
        guard let line = AgentOutput.spokenRefusal(receipt) else { return }
        host?.spokenUpdates?.refused(conversation: conversation, line)
    }
}
