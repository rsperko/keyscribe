import Foundation
import KeyScribeKit

struct AgentSnapshot {
    let names: [String: String]
    let conversations: [AgentConversation]
    var namesAvailable = true
    var disconnected: [String: String] = [:]
    var former: [String: String] = [:]
    var shared: [String: AgentRecipient.SharedName] = [:]
    var late: [String: String] = [:]
    var lateShared: [String: AgentRecipient.SharedName] = [:]
    var natives = AgentNativeRoster()
    var rows: [String] { conversations.map(\.id) }
    private var merged: (names: [String: String], shared: [String: AgentRecipient.SharedName]) {
        AgentRecipient.addingLate(late, sharing: lateShared, to: names.merging(disconnected) { kept, _ in kept }.merging(former) { kept, _ in kept }, sharing: shared)
    }
    var addressable: [String: String] { merged.names }
    var sharedNames: [String: AgentRecipient.SharedName] { merged.shared }
    var spokenNames: [String] { AgentRecipient.spokenNames(addressable, shared: sharedNames) }
    var afterVerbNames: [String] { AgentRecipient.afterVerbNames(sharedNames) }
}

struct CapturedFocus: Equatable {
    let id: String
    let readAt: UInt64
    var app: FrontApp?
}

@MainActor
protocol AgentTakeHost: AnyObject {
    var agents: AgentHub? { get }
    var spokenUpdates: SpokenResultOutput? { get }
    var lastHeardReply: (entry: String?, conversation: String)? { get }
    var agentsEnabled: Bool { get }
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
    var agentFocus: CapturedFocus? { get set }
    var agentNewConversation: CapturedFocus? { get set }
    var agentFocusUnconfirmed: Bool { get set }
    var agentHostCopyNotReady: AgentHub.HostCopyNotReady? { get set }
    var agentPaneProblem: String? { get set }
    var takePressedAt: DispatchTime? { get }
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
    func finishCancelled(message: String, heard: String, facts: [HistoryEntry.Fact])
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

    private(set) var receiptCount = 0
    private(set) var lastReceipt: AgentReceipt?
    private(set) var lastRecipient: ScriptedTakeRecipient?

    private func note(_ receipt: AgentReceipt, for conversation: String, agent: String?, request: String) {
        receiptCount += 1
        lastReceipt = receipt
        lastRecipient = ScriptedTakeRecipient(conversation: conversation, agent: agent, request: request)
    }
    var frontReadingGrace: Duration = .seconds(1)
    var placeNamesGrace: Duration = .seconds(1)
    var promptBoxConfirmation: Duration = .seconds(2)
    var frontApp: @MainActor () -> FrontApp? = { AgentFront.frontmost() }
    var inputAfter: @MainActor (UInt64) -> Bool? = { UserInput.any(after: $0) }

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

    func freezeConversations() {
        guard let host, let agents = host.agents, host.agentsEnabled,
              host.eligibleModes?.contains(where: { $0.output == .agent }) == true
        else { return }
        agents.refresh()
        agents.readPlaces()
        let refresh = agents.startHostRefreshForPress()
        let snapshot = Self.snapshot(of: agents)
        host.agentSnapshot = snapshot
        guard host.takeMode?.output == .agent else { return }
        captureFocus(snapshot: snapshot, through: agents, refresh: refresh)
    }

    private static func snapshot(of agents: AgentHub) -> AgentSnapshot {
        AgentSnapshot(
            names: agents.names, conversations: agents.recordingOrder,
            namesAvailable: agents.namesProblem == nil, disconnected: agents.disconnectedNames, former: agents.formerNames, shared: agents.sharedNames,
            natives: agents.nativeRoster)
    }

    private func settlePlaceNames(_ agents: AgentHub) async -> Bool {
        if let reading = agents.placeTracker?.reading {
            _ = try? await runWithDeadline(seconds: DictationController.seconds(placeNamesGrace)) { await reading.value }
        }
        let ids = (host?.agentSnapshot?.conversations ?? agents.directory.conversations).map(\.id)
        return agents.placeTracker?.reading == nil && !agents.placesUnread(ids)
    }

    private func captureFocus(snapshot: AgentSnapshot, through agents: AgentHub, refresh: AgentHub.HostRefresh?) {
        guard let host, let identity = host.takeIdentity else { return }
        let pressDeadline = ContinuousClock.now + frontReadingGrace
        host.agentFrontTask?.cancel()
        host.agentFrontTask = Task { @MainActor [weak self, weak host, weak agents] in
            guard var mark = agents?.hostReportMark() else { return }
            var shown = await agents?.terminalSessionInFrontWithoutAsking()
            var starts = false
            var notReady: AgentHub.HostCopyNotReady?
            var copySlot: String?
            if shown == nil, !Task.isCancelled, let check = await agents?.checkHostFront() {
                shown = check.shown
                starts = check.starts
                notReady = check.notReady
                copySlot = check.copySlot
            }
            while shown == nil, !Task.isCancelled, let host, host.takeIdentity === identity, let agents,
                  ContinuousClock.now < host.agentFrontCutoff ?? pressDeadline {
                let refreshing = !agents.hostsRefreshed(refresh)
                guard notReady != nil || refreshing else { break }
                if let notReady { host.agentHostCopyNotReady = notReady }
                guard await agents.nextHostReport(since: mark, watching: copySlot, awaitingRefresh: refreshing, before: host.agentFrontCutoff ?? pressDeadline)
                else { break }
                mark = agents.hostReportMark()
                let check = await agents.checkHostFront()
                shown = check.shown
                starts = check.starts
                notReady = check.notReady
                copySlot = check.copySlot
                if shown != nil { host.agentHostCopyNotReady = nil }
            }
            if shown == nil, !Task.isCancelled, let host, host.takeIdentity === identity {
                if let notReady {
                    host.agentHostCopyNotReady = notReady
                } else if let pane = await agents?.paneProblemWithoutAsking(), !Task.isCancelled, host.takeIdentity === identity {
                    host.agentPaneProblem = pane
                }
                return
            }
            guard let shown, let self, let host, !Task.isCancelled,
                  host.takeIdentity === identity,
                  host.agentFrontCutoff.map({ ContinuousClock.now <= $0 }) ?? true,
                  starts || snapshot.rows.contains(shown.id) || snapshot.disconnected.values.contains(shown.id)
                    || agents?.directory.conversations.contains(where: { $0.id == shown.id && $0.host != nil }) == true,
                  host.captureOrigin?.leaving(shown).session == shown.id,
                  let pressed = host.takePressedAt?.uptimeNanoseconds
            else { return }
            switch inputAfter(pressed) {
            case false?:
                let captured = CapturedFocus(id: shown.id, readAt: DispatchTime.now().uptimeNanoseconds, app: shown.app)
                if starts { host.agentNewConversation = captured } else { host.agentFocus = captured }
                host.redrawRecordingHUD()
            case nil:
                host.agentFocusUnconfirmed = true
            case true?:
                break
            }
        }
    }

    func noteUserInput(at time: UInt64) {
        guard let host, let pressed = host.takePressedAt?.uptimeNanoseconds, time > pressed else { return }
        var cleared = false
        if let focus = host.agentFocus, time <= focus.readAt {
            host.agentFocus = nil
            cleared = true
        }
        if let fresh = host.agentNewConversation, time <= fresh.readAt {
            host.agentNewConversation = nil
            cleared = true
        }
        if cleared { host.redrawRecordingHUD() }
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
            frozen: snapshot.conversations, live: agents.directory.conversations, focused: host.agentFocus?.id,
            namesAvailable: snapshot.namesAvailable, disconnected: snapshot.namesAvailable ? agents.disconnected : [],
            prompts: agents.openPrompts, starting: host.agentNewConversation.flatMap { agents.newConversationName($0.id) },
            agentNames: agents.agentNames)
    }

    func finish(routed: PhaseBResult, heard: String, mode: Mode) async {
        guard let host else { return }
        guard let agents = host.agents, host.agentsEnabled else {
            host.finishError("Talking to agents is turned off", action: nil)
            return
        }
        guard !routed.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            host.finishNoSpeech()
            return
        }
        let pressed = host.agentSnapshot ?? Self.snapshot(of: agents)
        let focused = { host.agentFocus?.id }
        switch VoiceCommandGrammar.parse(routed.transcript) {
        case .goBack:
            host.agentFrontTask?.cancel()
            await builtInFromAgent(
                VoiceCommandGrammar.goBack, heard: heard, facts: AgentHistoryFacts.goBack(focused: focused(), conversations: pressed.conversations))
            return
        case .cancel:
            host.agentFrontTask?.cancel()
            host.finishCancelled(
                message: AgentOutput.cancelledLine, heard: heard,
                facts: AgentHistoryFacts.cancel(focused: focused(), conversations: pressed.conversations))
            return
        case .repeatSummary:
            host.agentFrontTask?.cancel()
            await builtInFromAgent(
                VoiceCommandGrammar.repeatSummary[0], heard: heard,
                facts: AgentHistoryFacts.repeatSummary(focused: focused(), conversations: pressed.conversations))
            return
        case .keepReply where host.spokenUpdates?.readsReplies == true && host.lastHeardReply != nil:
            host.agentFrontTask?.cancel()
            await builtInFromAgent(
                VoiceCommandGrammar.keepReply[0], heard: heard,
                facts: AgentHistoryFacts.keepReply(focused: focused(), conversations: pressed.conversations))
            return
        default:
            break
        }
        let namesSettled = await settlePlaceNames(agents)
        if Task.isCancelled { return }
        let snapshot = {
            var frozen = pressed
            if frozen.namesAvailable, agents.namesProblem == nil {
                frozen.late = agents.names.merging(agents.disconnectedNames) { kept, _ in kept }.merging(agents.formerNames) { kept, _ in kept }
                frozen.lateShared = agents.sharedNames
                frozen.natives = frozen.natives.addingLate(agents.nativeRoster)
            }
            return frozen
        }()
        if let request = AgentRename.request(in: routed.transcript) {
            await renameFromAgent(request, in: routed.transcript, focused: focused, through: agents, heard: heard, mode: mode, snapshot: snapshot)
            return
        }
        let read = host.takePlan.agentAddressReader(for: routed.transcript, mode: mode)
        if let query = AgentStatusQuery.parse(
            routed.transcript, names: snapshot.spokenNames, namesKnown: snapshot.namesAvailable,
            read: read, afterVerb: snapshot.afterVerbNames, natives: snapshot.natives) {
            await answerStatus(query, focused: focused, through: agents, heard: heard, mode: mode, snapshot: snapshot)
            return
        }
        let address = AgentAddress.parse(
            routed.transcript, names: snapshot.spokenNames, namesKnown: snapshot.namesAvailable,
            read: read, afterVerb: snapshot.afterVerbNames, natives: snapshot.natives)
        if AgentRecipient.usesFocus(address) {
            await settleAgentInFront()
            if Task.isCancelled { return }
        } else {
            host.agentFrontTask?.cancel()
        }
        let inFront = focused()
        var resolution = AgentRecipient.resolve(address, focused: inFront, rows: snapshot.rows, names: snapshot.addressable, shared: snapshot.sharedNames)
        if case .ask(let body, .nothingFocused) = resolution, let fresh = host.agentNewConversation {
            resolution = .deliver(id: fresh.id, body: body, source: .front)
        }
        let facts = AgentHistoryFacts.facts(
            address: address, resolution: resolution, focused: inFront, conversations: snapshot.conversations)
        if host.captureWasLost {
            if case .deliver(_, let body, _) = resolution { host.finishTruncatedCapture(transcript: body) } else { host.finishCommandCaptureLost() }
            return
        }
        if !namesSettled, AgentRecipient.usesFocus(address), case .deliver(_, let body, _) = resolution {
            let line = "Couldn\u{2019}t check conversation names yet. Nothing sent. Say it again, or start with \u{201C}tell\u{201D} and a name or conversation number."
            finishAgent(state: .error(message: AgentOutput.kept(line, body: body), action: nil, heard: HeardExcerpt(heard: body)),
                        outcome: .failed, heard: heard, body: body, transformed: nil, rewrite: nil, recorded: line, facts: facts)
            return
        }
        if case .ask(let body, .nothingFocused) = resolution, host.agentFocusUnconfirmed {
            let line = Self.unconfirmedLine
            finishAgent(state: .error(message: AgentOutput.kept(line, body: body), action: .openAccessibilitySettings, heard: HeardExcerpt(heard: body)),
                        outcome: .failed, heard: heard, body: body, transformed: nil, rewrite: nil, recorded: line, facts: facts)
            return
        }
        if case .ask(let body, .nothingFocused) = resolution, let notReady = host.agentHostCopyNotReady {
            let line = AgentOutput.notReadyLine(notReady)
            let action = Self.action(for: notReady, mode: mode.id)
            finishAgent(state: .error(message: AgentOutput.kept(line, body: body), action: action, heard: HeardExcerpt(heard: body)),
                        outcome: .failed, heard: heard, body: body, transformed: nil, rewrite: nil, recorded: line,
                        facts: facts + [.init(label: "Conversation in front", value: line)])
            return
        }
        if case .ask(let body, .nothingFocused) = resolution, let pane = host.agentPaneProblem {
            let line = "\(AgentRecipient.nothingFocused). \(pane) \(AgentOutput.nothingSent) \(AgentRecipient.nothingFocusedAdvice)"
            finishAgent(state: .error(message: AgentOutput.kept(line, body: body), action: nil, heard: HeardExcerpt(heard: body)),
                        outcome: .failed, heard: heard, body: body, transformed: nil, rewrite: nil, recorded: line,
                        facts: facts + [.init(label: "Conversation in front", value: pane)])
            return
        }
        if let (id, front, body) = Self.target(of: resolution), snapshot.disconnected.values.contains(id) || agents.isExcluded(id) {
            let name = snapshot.disconnected.first { $0.value == id }?.key ?? "That conversation"
            let line = (front ? "The conversation in front is disconnected" : "\(name) is disconnected") + ". " + AgentOutput.nothingSent
            finishAgent(state: .error(message: AgentOutput.kept(line, body: body), action: .openAgents(mode.id), heard: HeardExcerpt(heard: body)),
                        outcome: .failed, heard: heard, body: body, transformed: nil, rewrite: nil, recorded: line, facts: facts)
            return
        }
        switch resolution {
        case .open(let id):
            agents.noteUsed(id)
            let handle = agents.handle(of: id) ?? "it"
            hud.present(.transcribing(mode: mode.name, status: "Opening \(handle)\u{2026}"))
            let lease = host.lease(for: .agents, stopsAtPress: nil)
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
                let action = HUDErrorAction.openAgents(mode.id, reveal: meant.map(\.row))
                finishAgent(state: .error(message: AgentOutput.kept(shown, body: body), action: action, heard: HeardExcerpt(heard: body)),
                            outcome: .failed, heard: heard, body: body, transformed: nil, rewrite: nil, recorded: shown, facts: facts)
                return
            }
            let shown = line(reason, retry, reachable(snapshot, agents, for: retry))
            finishAgent(state: .error(message: AgentOutput.kept(shown, body: body), action: Self.askAction(reason, mode: mode), heard: HeardExcerpt(heard: body)),
                        outcome: .failed, heard: heard, body: body, transformed: nil, rewrite: nil,
                        recorded: line(reason, nil, [:]), facts: facts)
        case .deliver(let id, let body, _):
            host.noteAgentDestination(id, facts: facts)
            await host.rewriteAndDeliver(
                PhaseBResult(routedModeId: routed.routedModeId, transcript: body), mode: mode, to: id, facts: facts, heard: heard)
        }
    }

    static var unconfirmed: String {
        "Couldn\u{2019}t confirm the conversation in front, because \(Branding.appName) can\u{2019}t see key presses and clicks."
    }

    static func action(for notReady: AgentHub.HostCopyNotReady, mode: String) -> HUDErrorAction? {
        switch notReady {
        case .missing, .notConnected, .cannotStart: .openAgents(mode)
        case .needsAccessibility: .openAccessibilitySettings
        case .notSetUp, .windowUnknown, .nothingShown, .notListed, .unavailable: nil
        }
    }

    static var unconfirmedLine: String {
        "\(unconfirmed) \(AgentOutput.nothingSent) Name a conversation in your instruction, or check that Accessibility is on for \(Branding.appName)."
    }

    static func unchecked(_ address: AgentAddress?) -> Bool {
        switch address {
        case .unresolved?: true
        case .native(_, let handles, _)?: handles.isEmpty
        default: false
        }
    }

    static var unconfirmedCheckLine: String {
        "\(unconfirmed) \(AgentOutput.nothingSent) Say \u{201C}check on\u{201D} and a conversation\u{2019}s name, or check that Accessibility is on for \(Branding.appName)."
    }

    static var unconfirmedRenameLine: String {
        "\(unconfirmed) Check that Accessibility is on for \(Branding.appName), then say the rename command again."
    }

    private static func target(of resolution: AgentRecipient.Resolution) -> (id: String, front: Bool, body: String)? {
        switch resolution {
        case .deliver(let id, let body, let source): (id, source == .front, body)
        case .open(let id): (id, false, "")
        case .ask: nil
        }
    }

    private func renameFromAgent(
        _ request: Result<Substring, AgentRename.Problem>, in transcript: String, focused: @escaping () -> String?, through agents: AgentHub, heard: String,
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
            rename = .invalid(problem)
        case .success(let spoken):
            let edited = edited(String(spoken))
            host.spokenEdits = SpokenEdit.summary(edited.payload.spokenEdits)
            let name = edited.isBlank ? "" : edited.localText
            rename = AgentRename.parse(name) ?? AgentRename.name(from: name)
        }
        guard case .rename(let spoken) = rename else {
            host.agentFrontTask?.cancel()
            if case .invalid(let problem) = rename {
                finishAgent(state: .error(message: Self.renameProblem(problem), action: nil, heard: HeardExcerpt(heard: heard)),
                            outcome: .failed, heard: heard, body: "", transformed: nil, rewrite: nil,
                            facts: AgentHistoryFacts.rename(focused: nil, to: nil, conversations: snapshot.conversations))
            }
            return
        }
        await settleAgentInFront()
        if Task.isCancelled { return }
        let name = AgentHandles.normalize(spoken)
        let target = focused()
        let facts = AgentHistoryFacts.rename(focused: target, to: name, conversations: snapshot.conversations)
        func fail(_ message: String, action: HUDErrorAction? = nil) {
            finishAgent(state: .error(message: message, action: action, heard: HeardExcerpt(heard: heard)),
                        outcome: .failed, heard: heard, body: "", transformed: nil, rewrite: nil, transitioned: true, facts: facts)
        }
        let lease = host.lease(for: .agents, stopsAtPress: nil)
        guard lease.keepActing() else {
            host.cancelQuietly()
            return
        }
        guard let id = target else {
            if host.agentFocusUnconfirmed { return fail(Self.unconfirmedRenameLine, action: .openAccessibilitySettings) }
            return fail("Switch to a conversation, then say the rename command again", action: .openAgents(mode.id))
        }
        guard let old = agents.handle(of: id) else { return fail("That conversation has ended") }
        do {
            try agents.rename(id, to: name)
        } catch let error as AgentHandles.RenameError {
            return fail(Self.renameProblem(error, name: name))
        } catch {
            return fail("Couldn\u{2019}t save the new name. \(old) is unchanged", action: .openAgents(mode.id))
        }
        agents.noteUsed(id)
        finishAgent(state: .commandDone(summary: "Renamed \(old) to \(name)", detail: mode.name), outcome: .inserted, heard: heard,
                    body: "", transformed: nil, rewrite: nil, transitioned: true, hideAfter: 4, facts: facts)
    }

    private func answerStatus(
        _ query: AgentStatusQuery, focused: () -> String?, through agents: AgentHub, heard: String, mode: Mode,
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
        case .all:
            host.agentFrontTask?.cancel()
            guard host.lease(for: .agents, stopsAtPress: nil).keepActing() else { return stopQuietly() }
            func report() -> (names: [String], complete: Bool) {
                let stale = agents.lastSeen
                let listed = agents.recordingOrder.filter { !agents.isExcluded($0.id) }
                let names = listed.filter { !stale.contains($0.id) && AgentRoster.isWaitingForInput($0) }.map(\.handle)
                let complete = agents.discoveryProblems.isEmpty
                    && listed.allSatisfy { !stale.contains($0.id) && ($0.reachable || AgentRoster.isWaitingForInput($0)) }
                return (names, complete)
            }
            let reported = report()
            let line = AgentStatusAnswer.all(reported.names, complete: reported.complete)
            return answered(line, shown: line, conversation: "", handle: "All conversations", summary: "Checked all conversations", heard: heard,
                            facts: AgentHistoryFacts.allConversations(), whileTrue: { report() == reported })
        case .check(let named):
            address = named
        }
        let inFront: String?
        let resolution: AgentRecipient.Resolution
        if let address {
            host.agentFrontTask?.cancel()
            inFront = focused()
            resolution = AgentRecipient.conversation(
                address, focused: inFront, rows: snapshot.rows, names: snapshot.addressable, shared: snapshot.sharedNames)
        } else {
            await settleAgentInFront()
            if Task.isCancelled { return }
            inFront = focused()
            resolution = inFront.map { .deliver(id: $0, body: "", source: .front) } ?? .ask(body: "", reason: .nothingFocused)
        }
        let facts = AgentHistoryFacts.status(address: address, resolution: resolution, focused: inFront, conversations: snapshot.conversations)
        func fail(_ message: String, action: HUDErrorAction? = nil, keepingWords: Bool = false) {
            let body = keepingWords ? heard : ""
            if keepingWords { host.rememberResult(heard) }
            finishAgent(state: .error(message: AgentOutput.kept(message, body: body), action: action, heard: HeardExcerpt(heard: heard)),
                        outcome: .failed, heard: heard, body: body, transformed: nil, rewrite: nil, transitioned: true, facts: facts)
        }
        let lease = host.lease(for: .agents, stopsAtPress: nil)
        guard lease.keepActing() else { return stopQuietly() }
        guard let id = resolution.recipient else {
            if case .ask(_, let reason) = resolution, reason != .nothingFocused {
                if !snapshot.namesAvailable, Self.unchecked(address) {
                    return fail("Couldn\u{2019}t check conversation names yet. \(AgentOutput.nothingSent) Say it again, or say \u{201C}check on conversation\u{201D} and its number.",
                                keepingWords: true)
                }
                return fail(AgentOutput.askLine(reason), action: .openAgents(mode.id), keepingWords: true)
            }
            if host.agentFocusUnconfirmed { return fail(Self.unconfirmedCheckLine, action: .openAccessibilitySettings) }
            if let notReady = host.agentHostCopyNotReady { return fail(AgentOutput.notReadyLine(notReady), action: Self.action(for: notReady, mode: mode.id)) }
            let pane = host.agentPaneProblem.map { " \($0)" } ?? ""
            return fail("\(AgentRecipient.nothingFocused).\(pane) \(AgentOutput.nothingSent) Say \u{201C}check on\u{201D} and a conversation\u{2019}s name.")
        }
        let name = agents.handle(of: id) ?? snapshot.disconnected.first { $0.value == id }?.key ?? "That conversation"
        if snapshot.disconnected.values.contains(id) || agents.isExcluded(id) {
            return fail("\(name) is disconnected. \(AgentOutput.nothingSent)", action: .openAgents(mode.id))
        }
        func observed() -> (conversation: AgentConversation, prompt: AgentPrompt?)? {
            guard let conversation = agents.directory.conversations.first(where: { $0.id == id }) else { return nil }
            return (conversation, AgentRoster.isWaitingForInput(conversation) ? agents.openPrompts[id] : nil)
        }
        guard let before = observed() else { return fail("That conversation has ended. \(AgentOutput.nothingSent)") }
        var description: String?
        if let prompt = before.prompt, AgentStatusAnswer.question(in: prompt) == nil, let spoken = host.spokenUpdates {
            hud.present(.transcribing(mode: mode.name, status: "Checking \(before.conversation.handle)\u{2026}"))
            description = await spoken.describe(prompt, handle: before.conversation.handle)
            if Task.isCancelled { return }
            guard lease.keepActing() else { return stopQuietly() }
        }
        guard let now = observed() else { return fail("That conversation has ended. \(AgentOutput.nothingSent)") }
        if now.prompt != before.prompt || now.conversation.state != before.conversation.state { description = nil }
        let handle = now.conversation.handle
        let connected = now.conversation.reachable
        let current = !agents.lastSeen.contains(id)
        let line = AgentStatusAnswer.status(
            handle: handle, state: now.conversation.state, connected: connected, current: current, prompt: now.prompt,
            description: description)
        let shown = [line, AgentStatusAnswer.hint(handle: handle, state: now.conversation.state, connected: connected, current: current)]
            .compactMap { $0 }.joined(separator: " ")
        answered(line, shown: shown, conversation: id, handle: handle, summary: "Checked \(handle)", heard: heard, facts: facts,
                 whileTrue: {
                     observed().map {
                         $0.prompt == now.prompt && $0.conversation.state == now.conversation.state && $0.conversation.reachable == connected
                             && agents.lastSeen.contains(id) != current
                     } ?? false
                 })
    }

    private func answered(
        _ line: String, shown: String, conversation: String, handle: String, summary: String, heard: String, facts: [HistoryEntry.Fact],
        whileTrue stillTrue: @escaping () -> Bool
    ) {
        let enabled = { [weak host] in host?.agentsEnabled == true }
        _ = host?.spokenUpdates?.answer(conversation: conversation, handle: handle, line, whileTrue: { enabled() && stillTrue() })
        finishAgent(state: .advisory(message: shown), outcome: .inserted, heard: heard, body: "", transformed: nil, rewrite: nil,
                    transitioned: true, hideAfter: 8, summary: summary, facts: facts)
    }

    private static func renameProblem(_ problem: AgentRename.Problem) -> String {
        switch problem {
        case .noName: "No new name was heard. Nothing sent. Say \u{201C}rename this conversation to\u{201D} and the new name."
        case .tooLong: "A name can be up to \(AgentRename.nameWords) words. Nothing sent."
        case .moreAfterName: "More words followed the name. Nothing sent. Say only the new name after \u{201C}rename this conversation to\u{201D}."
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
        let lease = host.lease(for: .agents, stopsAtPress: host.voiceCommandStopsAtPress)
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
        guard let agents = host.agents, let mode = host.takeMode, host.agentsEnabled else {
            finishAgent(state: .error(message: "Talking to agents was turned off. Nothing sent.", action: nil, heard: HeardExcerpt(heard: text)),
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
        let lease = host.lease(for: .agents, stopsAtPress: nil)
        guard lease.keepActing() else { return }
        host.rememberResult(text)
        hud.present(.transcribing(mode: mode.name, status: "Sending to \(agents.handle(of: id) ?? agents.newConversationName(id) ?? "it")"))
        let clipboard = agentClipboard.note(for: text, attached: agents.takesImages(id))
        let images = agentClipboard.images(in: text)
        if agents.newConversationName(id) != nil {
            let captured = host.agentNewConversation?.app
            let shown = await agents.newConversationInFront()
            guard lease.keepActing() else { return }
            let inFront = captured != nil && shown?.id == id && shown?.app == captured
            let (request, receipt) = await output.deliver(text, to: id, via: agents, inFront: inFront)
            note(receipt, for: id, agent: agents.directory.conversations.first { $0.id == id }?.agent, request: request)
            finishAgent(state: AgentOutput.receiptState(receipt, mode: mode.name, heard: text, settingsMode: mode.id, clipboard: clipboard),
                        outcome: AgentOutput.dictationOutcome(receipt),
                        heard: heard, body: text, transformed: transformed, rewrite: rewrite, transitioned: true,
                        facts: facts, awaitingReceipt: (request, receipt))
            speakRefusal(receipt, conversation: id)
            return
        }
        let checksFront = agents.takesPromptBox(id, images: images) || agents.showsDraft(id)
        let inFront = checksFront ? await agents.sessionInFrontWithoutAsking()?.id == id : false
        guard lease.keepActing() else { return }
        var (request, receipt) = await output.deliver(text, to: id, via: agents, images: images, inFront: inFront)
        if !checksFront, case .kept(_, .composing) = receipt, agents.joinsDrafts(id), lease.keepActing(),
           await agents.sessionInFrontWithoutAsking()?.id == id, lease.keepActing() {
            output.forgetReceipt(request: request)
            (request, receipt) = await output.deliver(text, to: id, via: agents, images: images, inFront: true)
        }
        if case .kept(let handle, .inPromptBox(let cause)) = receipt, cause != .besideText,
           let sent = await sendFromPromptBox(
               id, handle: handle, steering: cause == .awaitingReturn || cause == .joinedDraftMidTurn ? text : nil, through: agents, keepActing: { lease.keepActing() },
               request: request) {
            receipt = sent == .sent(handle) && (cause == .joinedDraft || cause == .joinedDraftMidTurn) ? .sentWithDraft(handle) : sent
        }
        note(receipt, for: id, agent: agents.directory.conversations.first { $0.id == id }?.agent, request: request)
        finishAgent(state: AgentOutput.receiptState(receipt, mode: mode.name, heard: text, settingsMode: mode.id, clipboard: clipboard),
                    outcome: AgentOutput.dictationOutcome(receipt),
                    heard: heard, body: text, transformed: transformed, rewrite: rewrite, transitioned: true,
                    facts: facts + [agents.deliveryFact(of: request)].compactMap { $0 }, awaitingReceipt: (request, receipt))
        speakRefusal(receipt, conversation: id)
    }

    // Claude Code takes a prompt mid-turn, or after a Stop, only when the user enters it, so the connector left
    // the message in the empty box. Return goes only to that conversation, only when it is the one in front, and,
    // where the connector can say, only while the box holds just the message and no approval is open.
    private func sendFromPromptBox(
        _ id: String, handle: String, steering: String?, through agents: AgentHub, keepActing: () -> Bool, request: String
    ) async -> AgentReceipt? {
        guard keepActing(), let shown = await agents.sessionInFrontWithoutAsking(), shown.id == id, keepActing()
        else { return nil }
        if agents.checksPromptBox(id) {
            guard await agents.promptBoxReady(request, in: id), keepActing(),
                  let still = await agents.sessionInFrontWithoutAsking(), still.id == id, still.app == shown.app, keepActing(),
                  let focused = frontApp(), focused.pid == shown.app.pid, shown.app.window == nil || focused.window == shown.app.window
            else { return nil }
        }
        let typedBefore = agents.typedCount(id)
        if steering == nil { agents.awaitTypedTurn(of: id, request: request) }
        await submitKey(.return)
        let deadline = ContinuousClock.now + promptBoxConfirmation
        while agents.typedCount(id) == typedBefore, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard agents.typedCount(id) > typedBefore else {
            agents.forgetTypedTurn(of: id, request: request)
            return .uncertain(handle)
        }
        if let steering { agents.followSteer(of: id, for: request, text: steering) }
        return .sent(handle)
    }

    func sendLeftInPromptBox(_ request: String, in id: String, handle: String) async {
        guard let host, let agents = host.agents else { return }
        let idle = { [weak host] in host?.isBusy == false }
        let sent = idle() ? await sendFromPromptBox(id, handle: handle, steering: nil, through: agents, keepActing: idle, request: request) : nil
        agents.settleLeftInPromptBox(request, in: id, as: sent == .sent(handle) ? nil : sent ?? .kept(handle, reason: .inPromptBox(.afterStop)))
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
        guard meant.count > 1 else { return "\(meant[0].name) isn\u{2019}t connected yet. Nothing sent." }
        let names = meant.map(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let groups = names.map { name in
            let same = meant.filter { $0.name == name }
            return same.count == 1 ? name : "\(same.count) \(same[0].agent) conversations in \(same[0].folder)"
        }
        return "\(AgentOutput.either(groups, joining: "and")) aren\u{2019}t connected yet. Nothing sent."
    }

    private static func names(_ spoken: String, _ unconnected: AgentHub.Unconnected) -> Bool {
        let key = AgentHandles.matchKey(spoken)
        return !key.isEmpty && (key == AgentHandles.matchKey(unconnected.folder) || key == AgentHandles.matchKey(unconnected.name))
    }

    private static func askAction(_ reason: AgentRecipient.AskReason, mode: Mode) -> HUDErrorAction? {
        if case .unknownName = reason { .openAgents(mode.id) } else { nil }
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
        if let awaited {
            output.replayEarlyReceipts(
                request: awaited.request, receipt: awaited.receipt,
                mayStillChange: host.agents?.awaitsLateOutcome(awaited.request) == true)
        }
    }

    func speakRefusal(_ receipt: AgentReceipt, conversation: String) {
        guard let line = AgentOutput.spokenRefusal(receipt) else { return }
        host?.spokenUpdates?.refused(conversation: conversation, line)
    }
}
