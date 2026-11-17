import Foundation
import Testing
@testable import KeyScribeKit

struct ConnectorSetupsTests {
    private var ids: () -> String {
        var next = 0
        return {
            next += 1
            return "id-\(next)"
        }
    }

    @Test func enrollingASetupAdmitsOnlyItsOwnInstallation() {
        var setups = ConnectorSetups()
        let made = ids
        let custom = setups.enroll(agent: "pi", folder: "/u/.pi/custom", makeInstallation: made)
        #expect(setups.admits(agent: "pi", installation: custom.installation))
        #expect(!setups.admits(agent: "claude", installation: custom.installation))
        #expect(!setups.admits(agent: "pi", installation: "other"))
        #expect(!setups.admits(agent: "pi", installation: nil))
        #expect(setups.setup(agent: "pi", folder: "/u/.pi/agent") == nil)
    }

    @Test func enrollingAgainKeepsTheInstallationIdentity() {
        var setups = ConnectorSetups()
        let made = ids
        let first = setups.enroll(agent: "pi", folder: "/a", makeInstallation: made)
        let again = setups.enroll(agent: "pi", folder: "/a", makeInstallation: made)
        #expect(first.installation == again.installation)
        #expect(setups.setups.count == 1)
    }

    @Test func eachSetupHasItsOwnIdentityAndRevokingOneLeavesTheOthers() {
        var setups = ConnectorSetups()
        let made = ids
        let a = setups.enroll(agent: "claude", folder: "/a", makeInstallation: made)
        let b = setups.enroll(agent: "claude", folder: "/b", makeInstallation: made)
        #expect(a.installation != b.installation)
        setups.beginRemoval(agent: "claude", folder: "/a")
        #expect(!setups.admits(agent: "claude", installation: a.installation))
        #expect(setups.admits(agent: "claude", installation: b.installation))
        #expect(setups.setup(agent: "claude", folder: "/a")?.removing == true)
    }

    @Test func retryingARemovalNeverRestoresAdmission() {
        var setups = ConnectorSetups()
        let a = setups.enroll(agent: "pi", folder: "/a", makeInstallation: ids)
        setups.beginRemoval(agent: "pi", folder: "/a")
        setups.beginRemoval(agent: "pi", folder: "/a")
        #expect(!setups.admits(agent: "pi", installation: a.installation))
        setups.finishRemoval(agent: "pi", folder: "/a")
        #expect(setups.setup(agent: "pi", folder: "/a") == nil)
    }

    @Test func reinstallingAfterAnUnfinishedRemovalIssuesANewIdentity() {
        var setups = ConnectorSetups()
        let made = ids
        let old = setups.enroll(agent: "pi", folder: "/a", makeInstallation: made)
        setups.beginRemoval(agent: "pi", folder: "/a")
        let fresh = setups.enroll(agent: "pi", folder: "/a", makeInstallation: made)
        #expect(fresh.installation != old.installation)
        #expect(!fresh.removing)
        #expect(!setups.admits(agent: "pi", installation: old.installation))
    }

    @Test func knownSetupsAreTheDefaultThenEnrolledThenDiscoveredWithoutDuplicates() {
        var setups = ConnectorSetups()
        setups.enroll(agent: "pi", folder: "/custom", makeInstallation: ids)
        setups.enroll(agent: "claude", folder: "/elsewhere", makeInstallation: ids)
        let known = setups.known(agent: "pi", default: "/u/.pi/agent", discovered: ["/found", "/custom", "/u/.pi/agent"])
        #expect(known == ["/u/.pi/agent", "/custom", "/found"])
    }

    @Test func theFileRoundTripsWithItsSchemaVersion() throws {
        var setups = ConnectorSetups()
        setups.enroll(agent: "pi", folder: "/a", makeInstallation: ids)
        let data = try JSONEncoder().encode(setups)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schema_version"] as? Int == ConnectorSetups.schemaVersion)
        #expect(try JSONDecoder().decode(ConnectorSetups.self, from: data) == setups)
    }

    @Test func aChosenCommandIsKeptWithTheFoldersEnrollment() throws {
        var setups = ConnectorSetups()
        let made = ids
        setups.enroll(agent: "claude", folder: "/a", tool: "/Users/a/tools/claude", makeInstallation: made)
        #expect(setups.setup(agent: "claude", folder: "/a")?.tool == "/Users/a/tools/claude")
        setups.enroll(agent: "claude", folder: "/a", makeInstallation: made)
        #expect(setups.setup(agent: "claude", folder: "/a")?.tool == "/Users/a/tools/claude")
        setups.choose(tool: nil, agent: "claude", folder: "/a")
        #expect(setups.setup(agent: "claude", folder: "/a")?.tool == nil)
        setups.choose(tool: "/x/claude", agent: "claude", folder: "/missing")
        #expect(setups.setup(agent: "claude", folder: "/missing") == nil)
    }

    @Test func aChosenCommandRoundTripsAndAnOlderFileWithoutOneStillReads() throws {
        var setups = ConnectorSetups()
        setups.enroll(agent: "pi", folder: "/p", tool: "/opt/pi", makeInstallation: { "id-1" })
        let data = try JSONEncoder().encode(setups)
        #expect(try JSONDecoder().decode(ConnectorSetups.self, from: data) == setups)
        let older = Data(#"{"schema_version":1,"setups":[{"agent":"pi","folder":"/p","installation":"id-1","removing":false}]}"#.utf8)
        #expect(try JSONDecoder().decode(ConnectorSetups.self, from: older).setup(agent: "pi", folder: "/p")?.tool == nil)
        let json = String(decoding: try JSONEncoder().encode(ConnectorSetups(setups: [ConnectorSetup(agent: "pi", folder: "/p", installation: "i")])), as: UTF8.self)
        #expect(!json.contains("tool"))
    }
}
