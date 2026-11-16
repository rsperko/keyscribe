import CoreGraphics
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct AgentHUDTests {
    private let conversations = [
        AgentConversation(id: "a", agent: "claude", pid: 1, cwd: "/src/keyscribe", handle: "keyscribe", state: .working, connectorLive: true),
        AgentConversation(id: "b", agent: "claude", pid: 2, cwd: "/src/chatplay", handle: "chatplay", state: .idle, connectorLive: true),
    ]

    private func recording(_ focused: String?, conversations: [AgentConversation]? = nil) -> HUDState {
        let list = conversations ?? self.conversations
        return .recording(mode: "Agent", level: 0.3, latchedTrigger: nil,
                          agents: AgentRoster(frozen: list, live: list, focused: focused))
    }

    @Test func theConversationInFrontIsTheHeadlineAndTheListSaysWhereItCameFrom() {
        let state = recording("b")
        #expect(state.primaryText == "To chatplay")
        #expect(state.secondaryText == "Listening")
        #expect(state.agentRosterHint == "The conversation in front of you. To talk to another, say \u{201C}tell keyscribe \u{2026}\u{201D} or \u{201C}tell conversation 1 \u{2026}\u{201D}.")
        #expect(state.panelWidth == HUDState.recording(mode: "Polish", level: 0, latchedTrigger: nil).panelWidth)
        #expect(state.panelWidth == HUDState.transcribing(mode: "Agent").panelWidth)
    }

    @Test func withNothingFocusedTheHeadlineSaysSoAndTheHintTeachesAddressing() {
        #expect(recording(nil).primaryText == "No conversation focused")
        #expect(recording(nil).agentRosterHint == "Start with \u{201C}tell keyscribe \u{2026}\u{201D} or \u{201C}tell conversation 1 \u{2026}\u{201D}, then your message.")
        #expect(recording(nil, conversations: []).agentRosterHint == "No agent sessions are running.")
    }

    @Test func whileNamesAreUnavailableTheHintOffersOnlyRowNumbers() {
        let state = HUDState.recording(mode: "Agent", level: 0.3, latchedTrigger: nil,
            agents: AgentRoster(frozen: conversations, live: conversations, focused: "b", namesAvailable: false))
        #expect(state.agentRosterHint == "The conversation in front of you. Names are off until they can be loaded; to talk to another, say \u{201C}tell conversation 1 \u{2026}\u{201D}.")
        let none = HUDState.recording(mode: "Agent", level: 0.3, latchedTrigger: nil,
            agents: AgentRoster(frozen: conversations, live: conversations, focused: nil, namesAvailable: false))
        #expect(none.agentRosterHint == "Names are off until they can be loaded. Start with \u{201C}tell conversation 1 \u{2026}\u{201D}, then your message.")
        let only = HUDState.recording(mode: "Agent", level: 0.3, latchedTrigger: nil,
            agents: AgentRoster(frozen: [conversations[0]], live: [conversations[0]], focused: "a", namesAvailable: false))
        #expect(only.agentRosterHint == "The conversation in front of you. Names are off until they can be loaded.")
    }

    @Test func voiceOverHearsTheConversationInFrontAndHowManySessionsOnce() {
        #expect(recording("b").voiceOverAnnouncement == "Recording to chatplay. 2 sessions")
        #expect(recording(nil, conversations: [conversations[0]]).voiceOverAnnouncement == "Recording. No conversation focused. 1 session")
    }

    @Test func aSessionChangingStateWhileRecordingIsNotAnnouncedAgain() {
        let entry = recording("b")
        var changed = conversations
        changed[1].state = .working
        let updated = recording("b", conversations: changed)
        #expect(entry.voiceOverAnnouncement(after: .hidden) == "Recording to chatplay. 2 sessions")
        #expect(updated.voiceOverAnnouncement(after: entry) == nil)

        let countdown = RecordingCountdown(secondsLeft: 10, totalSeconds: 10)
        let counting = HUDState.recording(mode: "Agent", level: 0, latchedTrigger: nil, countdown: countdown, agents: updated.agentRoster)
        #expect(counting.voiceOverAnnouncement(after: updated) == "Recording stops in 10 seconds")
        let countingChanged = HUDState.recording(mode: "Agent", level: 0, latchedTrigger: nil, countdown: countdown, agents: entry.agentRoster)
        #expect(countingChanged.voiceOverAnnouncement(after: counting) == nil)
    }

    @Test func theConversationInFrontArrivingWhileRecordingIsAnnouncedOnce() {
        let entry = recording(nil)
        let moved = recording("b")
        #expect(moved.voiceOverAnnouncement(after: entry) == "Recording to chatplay")
        let level = HUDState.recording(mode: "Agent", level: 0.9, latchedTrigger: nil, agents: moved.agentRoster)
        #expect(level.voiceOverAnnouncement(after: moved) == nil)
    }

    @Test func theConversationInFrontSaysSoInTheHint() {
        #expect(recording("b").agentRosterHint?.hasPrefix("The conversation in front of you.") == true)
    }

    @Test func aLongListScrollsInsideTheSpaceTheScreenLeaves() {
        #expect(HUDState.agentListHeight(rows: 3, screenHeight: 900) == nil)
        let tall = try? #require(HUDState.agentListHeight(rows: 40, screenHeight: 2000))
        #expect(tall == HUDState.agentListHeight(rows: 40, screenHeight: 3000))
        let short = try? #require(HUDState.agentListHeight(rows: 12, screenHeight: 500))
        #expect((short ?? .infinity) <= HUDAnchor.listCap(screenHeight: 500))
        #expect((short ?? 0) >= HUDState.agentRowStep)
        #expect(tall == CGFloat(HUDState.agentRowsShown(screenHeight: 2000)) * HUDState.agentRowStep)
    }

    @Test func aRowReadsAsOneSentence() {
        let row = AgentRoster.Row(id: "a", number: 2, name: "keyscribe", detail: "Claude \u{00B7} keyscribe", state: "Working", available: true, target: true)
        #expect(HUDState.spoken(row) == "2, keyscribe, Claude \u{00B7} keyscribe, Working, in front")
    }

    @Test func ordinaryRecordingIsUnchanged() {
        let plain = HUDState.recording(mode: "Polish", level: 0.4, latchedTrigger: nil)
        #expect(plain.agentRosterHint == nil)
        #expect(plain.primaryText == "Polish")
        #expect(plain.voiceOverAnnouncement == "Recording")
    }

    @Test func thereIsAPreviewOfTheSessionList() {
        guard case .recording(_, _, _, _, let agents?) = HUDPreview.state(named: "recording-agents") else {
            Issue.record("no agent preview")
            return
        }
        #expect(agents.rows.count > 1)
    }

    @Test func theLongListPreviewPutsTheConversationInFrontBelowTheInitialViewport() throws {
        let agents = try #require(HUDPreview.state(named: "recording-agents-long")?.agentRoster)
        let target = try #require(agents.rows.first(where: { $0.target }))
        #expect(target.number > HUDState.agentRowsShown(screenHeight: 2000))
        #expect(agents.rows.map(\.number) == Array(1...agents.rows.count))
    }
}
