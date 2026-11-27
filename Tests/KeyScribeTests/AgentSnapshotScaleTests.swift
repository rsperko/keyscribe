import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@Suite struct AgentSnapshotScaleTests {
    static let words = [
        "release", "notes", "review", "budget", "deploy", "search", "billing", "parser", "cache", "ledger",
        "router", "widget", "import", "export", "schema", "sync", "queue", "token", "theme", "audit",
    ]

    static func names(_ count: Int) -> [String: String] {
        var names: [String: String] = [:]
        var index = 0
        outer: for a in words { for b in words { for c in words + ["one", "two", "three", "four", "five"] where a != b && b != c && a != c {
            names["\(a) \(b) \(c)"] = "agent:\(index)"
            index += 1
            if index == count { break outer }
        } } }
        return names
    }

    static func snapshot(_ count: Int) -> AgentSnapshot {
        let names = names(count)
        var snapshot = AgentSnapshot(names: names, conversations: [])
        snapshot.addLate(names: names, shared: [:], natives: AgentNativeRoster())
        return snapshot
    }

    static func takeNameWork(_ count: Int) -> (Duration, AgentAddress?) {
        var address: AgentAddress?
        let elapsed = ContinuousClock().measure {
            let snapshot = Self.snapshot(count)
            let addresses = snapshot.addresses
            for _ in 0..<2 {
                address = AgentAddress.parse("tell release notes review to send it", among: addresses, natives: snapshot.natives)
            }
        }
        return (elapsed, address)
    }

    @Test func aTakesNameWorkGrowsWithTheNamesNotTheirSquare() {
        let (elapsed, address) = Self.takeNameWork(1600)
        #expect(address == .name("release notes review", body: "to send it"))
        #expect(elapsed < .milliseconds(250))
    }

    @Test func lateNamesMergeTheSameAtAnySize() {
        var frozen = AgentSnapshot(
            names: ["docs": "a", "api": "b"], conversations: [], shared: ["APIs": AgentRecipient.SharedName(names: ["api"], kind: .also("b"))])
        frozen.addLate(
            names: ["docs": "a", "Docs": "c", "api work": "b", "new one": "z"],
            shared: ["work": AgentRecipient.SharedName(names: ["docs", "api"]), "else": AgentRecipient.SharedName(names: ["docs", "gone"])],
            natives: AgentNativeRoster())
        #expect(frozen.addressable == ["docs": "a", "api": "b", "api work": "b"])
        #expect(frozen.sharedNames.keys.sorted() == ["APIs", "work"])
        #expect(frozen.spokenNames.sorted() == ["APIs", "api", "api work", "docs", "work"])
    }
}
