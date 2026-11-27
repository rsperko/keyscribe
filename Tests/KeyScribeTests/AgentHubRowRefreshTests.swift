import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct AgentHubRowRefreshTests {
    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    @MainActor private final class Rig {
        let hub: AgentHub
        let fake = AgentHubTests.FakeDiscovery()
        let transport = AgentHubTests.FakeTransport()
        var states: [String: AgentLiveState] = [:]
        var titles: [String: String] = [:]
        var attention: [String] = []
        var changes = 0
        let clock = AgentHubTests.Clock()

        init(count: Int, alone: Bool) async {
            hub = AgentHub(transport: transport, discovery: [fake], now: { [clock] in clock.now })
            hub.refreshesRowsAlone = alone
            fake.listing = { [unowned self] native in self.session(native) }
            fake.result = .found((0..<count).map { session("f\($0)") })
            transport.live = Set((0..<count).filter { $0 % 3 != 0 }.map { "fake:f\($0)" })
            hub.onAttention = { [unowned self] conversation, handle, attention, requested in
                self.attention.append("\(conversation) \(handle) \(String(describing: attention)) \(requested)")
            }
            hub.onChange = { [unowned self] in self.changes += 1 }
            await hub.rescan()
        }

        func session(_ native: String) -> AgentSession {
            let number = Int(native.dropFirst()) ?? 0
            return AgentSession(
                agent: "fake", id: native, pid: 1000 + number, cwd: "/src/\(native)", state: states[native] ?? .idle,
                title: AgentTitle(generatedTitle: titles[native]))
        }

        var labels: [String] {
            transport.sent.compactMap { command, session in
                if case .status(_, _, let text) = command { "\(session) \(text)" } else { nil }
            }
        }
    }

    private enum Step {
        case turnStarted(Int), turnComplete(Int), waiting(Int, Bool), hello(Int, String?), title(Int, String), retitled(Int, String)
        case liveChanges(Int), otherGoesQuiet(Int, Int), time(Int, Int), stranger(Int), strangerGoesQuiet(Int, Int)

        static func random(_ count: Int, using generator: inout Generator) -> Step {
            let n = Int.random(in: 0..<count, using: &generator)
            switch Int.random(in: 0..<11, using: &generator) {
            case 0: return .turnStarted(n)
            case 1: return .turnComplete(n)
            case 2: return .waiting(n, Bool.random(using: &generator))
            case 3: return .hello(n, [nil, "named \(n)", "renamed \(n)"].randomElement(using: &generator)!)
            case 4: return .title(n, ["named \(n)", "other \(n)"].randomElement(using: &generator)!)
            case 5: return .retitled(n, ["first task \(n)", "second task \(n)"].randomElement(using: &generator)!)
            case 6: return .otherGoesQuiet(n, Int.random(in: 0..<count, using: &generator))
            case 7: return .time(n, [1, 3, 6, 40].randomElement(using: &generator)!)
            case 8: return .stranger(Int.random(in: 0..<3, using: &generator))
            case 9: return .strangerGoesQuiet(Int.random(in: 0..<3, using: &generator), n)
            default: return .liveChanges(n)
            }
        }

        @MainActor func play(on rig: Rig) {
            let hub = rig.hub
            switch self {
            case .turnStarted(let n):
                rig.states["f\(n)"] = .working
                hub.handle(.turnStarted(session: "fake:f\(n)", turn: "t\(n)"))
            case .turnComplete(let n):
                rig.states["f\(n)"] = .idle
                hub.handle(.turnComplete(session: "fake:f\(n)", reason: "answer", answer: "Done."))
            case .waiting(let n, let asks):
                rig.states["f\(n)"] = asks ? .waitingQuestion : .working
                hub.handle(.waiting(session: "fake:f\(n)", prompt: asks ? AgentPrompt(title: "Which one?") : nil))
            case .hello(let n, let title):
                rig.transport.live.insert("fake:f\(n)")
                hub.handle(.hello(.init(
                    protocolVersion: 2, agent: "fake", agentVersion: "", instance: "i\(n)", session: "fake:f\(n)", pid: 1000 + n,
                    features: ["label"], title: title)))
            case .title(let n, let text):
                hub.handle(.title(session: "fake:f\(n)", text: text))
            case .retitled(let n, let title):
                rig.titles["f\(n)"] = title
                hub.handle(.turnStarted(session: "fake:f\(n)", turn: "r\(n)"))
            case .otherGoesQuiet(let quiet, let n):
                if rig.transport.live.contains("fake:f\(quiet)") {
                    rig.transport.live.remove("fake:f\(quiet)")
                } else {
                    rig.transport.live.insert("fake:f\(quiet)")
                }
                hub.handle(.turnStarted(session: "fake:f\(n)", turn: "q\(n)"))
            case .time(let n, let seconds):
                rig.clock.now += TimeInterval(seconds)
                hub.handle(.title(session: "fake:f\(n)", text: ["named \(n)", "other \(n)"][seconds % 2]))
            case .stranger(let x):
                rig.transport.live.insert("fake:x\(x)")
                hub.handle(.hello(.init(
                    protocolVersion: 2, agent: "fake", agentVersion: "", instance: "x\(x)", session: "fake:x\(x)", pid: 9000 + x,
                    features: ["label"], title: "stranger \(x)")))
            case .strangerGoesQuiet(let x, let n):
                rig.transport.live.remove("fake:x\(x)")
                hub.handle(.turnStarted(session: "fake:f\(n)", turn: "s\(n)"))
            case .liveChanges(let n):
                if rig.transport.live.contains("fake:f\(n)") {
                    rig.transport.live.remove("fake:f\(n)")
                } else {
                    rig.transport.live.insert("fake:f\(n)")
                }
                hub.handle(.turnComplete(session: "fake:f\(n)", reason: "answer", answer: ""))
            }
        }
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8])
    func everyEventEndsWhereARebuildOfTheWholeRosterEnds(seed: UInt64) async {
        let count = 24
        let alone = await Rig(count: count, alone: true)
        let whole = await Rig(count: count, alone: false)
        var generator = Generator(state: seed)
        for index in 0..<160 {
            let step = Step.random(count, using: &generator)
            step.play(on: alone)
            step.play(on: whole)
            await alone.hub.scansSettled()
            await whole.hub.scansSettled()
            let at = "step \(index): \(step)"
            #expect(alone.hub.directory.conversations == whole.hub.directory.conversations, "\(at)")
            #expect(alone.hub.directory.disconnected == whole.hub.directory.disconnected, "\(at)")
            #expect(alone.labels == whole.labels, "\(at)")
            #expect(alone.attention.sorted() == whole.attention.sorted(), "\(at)")
            #expect(alone.changes == whole.changes, "\(at)")
            #expect(alone.hub.openPrompts == whole.hub.openPrompts, "\(at)")
            #expect(alone.transport.forgotten.sorted() == whole.transport.forgotten.sorted(), "\(at)")
            if alone.hub.directory.conversations != whole.hub.directory.conversations { break }
        }
        #expect(alone.hub.fullRefreshes < whole.hub.fullRefreshes)
    }

    @Test func eventsAboutListedConversationsRebuildNoRosterEvenInABurstOfHellos() async {
        let rig = await Rig(count: 400, alone: true)
        let before = rig.hub.fullRefreshes
        rig.states["f7"] = .working
        rig.hub.handle(.turnStarted(session: "fake:f7", turn: "t1"))
        rig.states["f7"] = .idle
        rig.hub.handle(.turnComplete(session: "fake:f7", reason: "answer", answer: "Done."))
        for n in 0..<400 {
            rig.hub.handle(.hello(.init(protocolVersion: 2, agent: "fake", agentVersion: "", instance: "i\(n)", session: "fake:f\(n)", pid: 1000 + n)))
        }
        await rig.hub.scansSettled()
        #expect(rig.hub.fullRefreshes == before)
        #expect(rig.hub.directory.conversation(id: "fake:f7")?.state == .idle)
    }
}
