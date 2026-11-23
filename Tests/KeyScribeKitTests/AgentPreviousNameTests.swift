import Foundation
import Testing
@testable import KeyScribeKit

struct AgentPreviousNameTests {
    enum Change: String, CaseIterable, CustomTestStringConvertible {
        case rename, tmuxSessionAppears, tmuxSessionRenamed, herdrPaneAppears, herdrPaneRenamed
        var testDescription: String { rawValue }
    }

    enum Timing: String, CaseIterable, CustomTestStringConvertible {
        case sameRun, changeThenRelaunch, relaunchThenChangeOnALaterRead, reinstallWithChangeOnTheFirstRead
        var testDescription: String { rawValue }
    }

    private static let id = "claude:a"
    private let entry = AgentSession(agent: "claude", id: "a", pid: 10, cwd: "/src/kestrel", state: .idle, startedAt: 1000)

    private func tmux(_ session: String) -> AgentPlace {
        let container = "tmux:/s#session:\(session)"
        return AgentPlace(
            surface: "tmux", labels: [.init(text: session, level: .workspace, container: container, surface: "tmux", term: "session")],
            containers: ["tmux:/s#pane:%1", "tmux:/s#window:@1", container])
    }

    private func herdr(_ pane: String) -> AgentPlace {
        AgentPlace(surface: "herdr", labels: [.init(text: pane, level: .pane, container: "/h#pane:p1")], containers: ["/h#pane:p1"])
    }

    private func scenario(_ change: Change) -> (before: AgentPlace?, after: AgentPlace?, old: String, new: String) {
        switch change {
        case .rename: (nil, nil, "kestrel", "falcon")
        case .tmuxSessionAppears: (nil, tmux("agent"), "kestrel", "agent")
        case .tmuxSessionRenamed: (tmux("agent"), tmux("otter"), "agent", "otter")
        case .herdrPaneAppears: (nil, herdr("architect"), "kestrel", "architect")
        case .herdrPaneRenamed: (herdr("architect"), herdr("builder"), "architect", "builder")
        }
    }

    private func read(_ directory: inout AgentDirectory, _ place: AgentPlace?) {
        directory.update(entries: [entry], live: [], places: place.map { [Self.id: $0] } ?? [:])
    }

    private func relaunch(_ directory: AgentDirectory) throws -> AgentDirectory {
        let saved = try JSONEncoder().encode(directory.remembered)
        return AgentDirectory(chosen: directory.chosenNames, remembered: try JSONDecoder().decode([String: RememberedName].self, from: saved))
    }

    private func apply(_ change: Change, to directory: inout AgentDirectory) throws {
        let (before, after, _, new) = scenario(change)
        if change == .rename {
            read(&directory, before)
            try directory.rename(Self.id, to: new)
        } else {
            read(&directory, after)
        }
    }

    private func reaches(_ name: String, in directory: AgentDirectory) -> String? {
        let names = Dictionary(directory.conversations.map { ($0.handle, $0.id) }, uniquingKeysWith: { first, _ in first })
            .merging(directory.formerNames) { kept, _ in kept }
        let address = AgentAddress.parse("tell \(name) to run the tests", names: Array(names.keys))
        guard case .deliver(let id, _, .spoken) = AgentRecipient.resolve(
            address, focused: nil, rows: directory.conversations.map(\.id), names: names)
        else { return nil }
        return id
    }

    @Test(arguments: Change.allCases, Timing.allCases)
    func theNameAConversationAnsweredToBeforeItsNameChangedStillReachesIt(change: Change, timing: Timing) throws {
        let (before, _, old, new) = scenario(change)
        var directory = AgentDirectory()
        read(&directory, before)
        #expect(directory.handles == [old])
        switch timing {
        case .sameRun:
            try apply(change, to: &directory)
        case .changeThenRelaunch:
            try apply(change, to: &directory)
            directory = try relaunch(directory)
            directory.update(entries: [entry], live: [], places: [:], unplaced: [Self.id])
            read(&directory, change == .rename ? before : scenario(change).after)
        case .relaunchThenChangeOnALaterRead:
            directory = try relaunch(directory)
            directory.update(entries: [entry], live: [], places: [:], unplaced: [Self.id])
            #expect(directory.handles == [old])
            try apply(change, to: &directory)
        case .reinstallWithChangeOnTheFirstRead:
            directory = try relaunch(directory)
            try apply(change, to: &directory)
        }
        #expect(directory.handles == [new])
        #expect(reaches(new, in: directory) == Self.id)
        #expect(reaches(old, in: directory) == Self.id)
    }

    @Test(arguments: [Timing.sameRun, .reinstallWithChangeOnTheFirstRead])
    func aRenameKeepsTheNameAMultiplexerTookOverAsWellAsTheOneItReplaces(timing: Timing) throws {
        var directory = AgentDirectory()
        read(&directory, nil)
        if timing == .reinstallWithChangeOnTheFirstRead { directory = try relaunch(directory) }
        read(&directory, tmux("agent"))
        try directory.rename(Self.id, to: "falcon")
        directory = try relaunch(directory)
        read(&directory, tmux("agent"))
        #expect(directory.handles == ["falcon"])
        #expect(reaches("agent", in: directory) == Self.id)
        #expect(reaches("kestrel", in: directory) == Self.id)
    }

    @Test func aRenameOfANameTheUserChoseKeepsOnlyThatName() throws {
        var directory = AgentDirectory()
        read(&directory, nil)
        read(&directory, tmux("agent"))
        try directory.rename(Self.id, to: "falcon")
        try directory.rename(Self.id, to: "hawk")
        #expect(directory.formerNames == ["falcon": Self.id])
    }

    @Test func aPreviousNameSurvivesOnlyForTheSameProcess() throws {
        var directory = AgentDirectory()
        read(&directory, nil)
        try directory.rename(Self.id, to: "falcon")
        var restarted = try relaunch(directory)
        var other = entry
        other.startedAt = 2000
        restarted.update(entries: [other], live: [])
        #expect(restarted.formerNames.isEmpty)
    }

    @Test func aPreviousNameTwoConversationsHadAsksWhichOneWasMeant() {
        let second = AgentSession(agent: "claude", id: "b", pid: 20, cwd: "/src/kestrel", state: .idle, startedAt: 2000)
        var directory = AgentDirectory()
        read(&directory, nil)
        read(&directory, tmux("agent"))
        directory.update(entries: [entry, second], live: [], places: [Self.id: tmux("agent")])
        #expect(handles(directory) == [Self.id: "agent", "claude:b": "kestrel"])
        directory.update(entries: [entry, second], live: [], places: [Self.id: tmux("agent"), "claude:b": tmux("otter")])
        #expect(handles(directory) == [Self.id: "agent", "claude:b": "otter"])
        #expect(directory.formerNames["kestrel"] == nil)
        let names = Dictionary(uniqueKeysWithValues: directory.conversations.map { ($0.handle, $0.id) })
        let shared = directory.sharedPlaceNames
        let address = AgentAddress.parse(
            "tell kestrel to run the tests", names: AgentRecipient.spokenNames(names, shared: shared))
        #expect(AgentRecipient.resolve(address, focused: nil, rows: directory.conversations.map(\.id), names: names, shared: shared)
            == .ask(body: "to run the tests", reason: .sharedName("kestrel", matches: ["agent", "otter"], tellApartIn: nil)))
    }

    private func handles(_ directory: AgentDirectory) -> [String: String] {
        Dictionary(uniqueKeysWithValues: directory.conversations.map { ($0.id, $0.handle) })
    }

    @Test func aWorkspaceNameAConversationHadAloneAsksOnceAnotherConversationJoinsIt() throws {
        let second = AgentSession(agent: "pi", id: "b", pid: 20, cwd: "/src/notes", state: .idle, startedAt: 2000)
        var directory = AgentDirectory()
        read(&directory, tmux("cos"))
        #expect(directory.handles == ["cos"])
        directory.update(entries: [entry, second], live: [], places: [Self.id: tmux("cos"), "pi:b": tmux("cos")])
        #expect(handles(directory) == [Self.id: "cos claude", "pi:b": "cos pi"])
        #expect(directory.formerNames["cos"] == nil)
        guard case .ask(_, .sharedName("cos", matches: ["cos claude", "cos pi"], _)) = resolve("cos", in: directory) else {
            Issue.record("cos did not ask: \(resolve("cos", in: directory))")
            return
        }
        directory = try relaunch(directory)
        directory.update(entries: [entry, second], live: [], places: [Self.id: tmux("cos"), "pi:b": tmux("cos")])
        #expect(directory.formerNames["cos"] == nil)
    }

    @Test func goingBackToTheDefaultNameKeepsTheChosenNameAndNeverItsOwnName() throws {
        var directory = AgentDirectory()
        read(&directory, nil)
        try directory.rename(Self.id, to: "falcon")
        directory.useDefaultName(Self.id)
        read(&directory, nil)
        #expect(directory.handles == ["kestrel"])
        #expect(directory.formerNames == ["falcon": Self.id])
        #expect(directory.remembered[Self.id]?.previous == ["falcon"])
    }

    @Test func savedPreviousNamesThatCannotBeSaidOrAreTheNameItselfAreDroppedOnLoad() throws {
        let saved = RememberedName(name: "kestrel", pid: 10, startedAt: 1000, native: nil, agent: "claude", previous: ["", "Kestrel", "Hawk!", "falcon"])
        var directory = AgentDirectory(remembered: [Self.id: saved])
        read(&directory, nil)
        #expect(directory.handles == ["kestrel"])
        #expect(directory.formerNames == ["falcon": Self.id])
        #expect(directory.remembered[Self.id]?.previous == ["falcon"])
    }

    private func resolve(_ name: String, in directory: AgentDirectory) -> AgentRecipient.Resolution {
        let names = Dictionary(directory.conversations.map { ($0.handle, $0.id) }, uniquingKeysWith: { first, _ in first })
            .merging(directory.formerNames) { kept, _ in kept }
        let shared = directory.sharedPlaceNames
        let address = AgentAddress.parse("tell \(name) to run the tests", names: AgentRecipient.spokenNames(names, shared: shared))
        return AgentRecipient.resolve(address, focused: nil, rows: directory.conversations.map(\.id), names: names, shared: shared)
    }

    enum Way: String, CaseIterable, CustomTestStringConvertible {
        case rename, tmuxLabelAppears, herdrLabelAppears, useDefaultName, carriedByFiling
        var testDescription: String { rawValue }
    }

    enum Around: String, CaseIterable, CustomTestStringConvertible {
        case alone, labelSharedWithAnother, nameOfAnother
        var testDescription: String { rawValue }
    }

    enum Run: String, CaseIterable, CustomTestStringConvertible {
        case sameRun, afterRelaunch
        var testDescription: String { rawValue }
    }

    private static let other = AgentSession(agent: "pi", id: "b", pid: 20, cwd: "/src/notes", state: .idle, startedAt: 2000)
    private static let filed = AgentSession(agent: "claude", id: "t1", pid: 10, cwd: "/src/site", state: .idle, startedAt: 1000)

    private func changed(_ way: Way) throws -> (directory: AgentDirectory, target: AgentSession, place: AgentPlace?, old: String) {
        var directory = AgentDirectory()
        read(&directory, nil)
        switch way {
        case .rename:
            try directory.rename(Self.id, to: "falcon")
            return (directory, entry, nil, "kestrel")
        case .tmuxLabelAppears:
            read(&directory, tmux("agent"))
            return (directory, entry, tmux("agent"), "kestrel")
        case .herdrLabelAppears:
            read(&directory, herdr("architect"))
            return (directory, entry, herdr("architect"), "kestrel")
        case .useDefaultName:
            try directory.rename(Self.id, to: "falcon")
            directory.useDefaultName(Self.id)
            read(&directory, nil)
            return (directory, entry, nil, "falcon")
        case .carriedByFiling:
            try directory.rename(Self.id, to: "falcon")
            let previous = directory.previousNames(of: Self.id)
            directory.update(entries: [Self.filed], live: [])
            let carried = directory.carryChosenName(from: Self.id, to: "claude:t1", previous: previous)
            #expect(carried)
            return (directory, Self.filed, nil, "kestrel")
        }
    }

    @Test(arguments: Way.allCases, Around.allCases)
    func aPreviousNameReachesItsConversationOnlyWhileNothingElseAnswersToIt(way: Way, around: Around) throws {
        for run in Run.allCases {
            var (directory, target, place, old) = try changed(way)
            let targetId = AgentSessionID.make(agent: target.agent, native: target.id)
            var entries = [target]
            var places = place.map { [targetId: $0] } ?? [:]
            switch around {
            case .alone:
                break
            case .labelSharedWithAnother:
                entries.append(Self.other)
                places = [targetId: tmux(old), "pi:b": tmux(old)]
                directory.update(entries: entries, live: [], places: places)
            case .nameOfAnother:
                entries.append(Self.other)
                directory.update(entries: entries, live: [], places: places)
                try directory.rename("pi:b", to: old)
            }
            if run == .afterRelaunch {
                directory = try relaunch(directory)
                directory.update(entries: entries, live: [], places: places)
            }
            let outcome = resolve(old, in: directory)
            switch around {
            case .alone:
                #expect(outcome == .deliver(id: targetId, body: "to run the tests", source: .spoken), "\(run)")
            case .labelSharedWithAnother:
                let members = directory.conversations.map(\.handle).sorted()
                #expect(outcome == .ask(body: "to run the tests", reason: .sharedName(old, matches: members, tellApartIn: nil)), "\(run)")
            case .nameOfAnother:
                #expect(outcome == .deliver(id: "pi:b", body: "to run the tests", source: .spoken), "\(run)")
            }
            for saved in directory.remembered.values {
                #expect(!saved.previous.contains { AgentHandles.matchKey($0) == AgentHandles.matchKey(saved.name) }, "\(run)")
            }
        }
    }

    @Test func olderSavedNamesWithoutPreviousNamesStillLoad() throws {
        let json = #"{"name":"kestrel","pid":10,"started_at":1000,"native":null,"agent":"claude"}"#
        let saved = try JSONDecoder().decode(RememberedName.self, from: Data(json.utf8))
        #expect(saved == RememberedName(name: "kestrel", pid: 10, startedAt: 1000, native: nil, agent: "claude"))
        #expect(saved.previous.isEmpty)
    }

    @Test func aRestoredConversationFiledBeforeItWasFirstListedStillHasItsPreviousNames() {
        let saved = RememberedName(name: "kestrel", pid: 10, startedAt: 1000, native: nil, agent: "claude", previous: ["hawk"])
        let directory = AgentDirectory(chosen: ["claude:old": "falcon"], remembered: ["claude:old": saved])
        #expect(directory.previousNames(of: "claude:old") == ["hawk"])
    }
}
