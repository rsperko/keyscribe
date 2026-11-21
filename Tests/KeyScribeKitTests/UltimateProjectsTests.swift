import Foundation
import KeyScribeKit
import Testing

struct UltimateProjectsTests {
    private static let listing = #"""
        [{"id":1,"cwd":"/w/app"},
         {"id":28,"title":"@lander","label":"lander","cwd":"/h/lander/b8"},
         {"id":53,"title":"@ultimate","label":"agent","cwd":"/w/app","inputAt":1795105970306,"answerAt":1795105970389},
         {"id":61,"title":"Fix the login redirect","cwd":"/h/worktrees/61","inputAt":1795106000000},
         {"id":70,"title":"Side chat","label":"side-chat","cwd":"/w/app"},
         {"id":72,"title":"@scribe","label":"agent","cwd":"/w/app"}]
        """#

    @Test func aProjectListsItsWritableConversationsButNotItsRootOrLander() {
        let conversations = UltimateProjects.conversations(Data(Self.listing.utf8))
        #expect(conversations?.map(\.id) == ["53", "61", "70", "72"])
    }

    @Test func everyWritableKindOfSidebarConversationIsListed() throws {
        let listing = Data(#"""
            [{"id":1}, {"id":2,"label":"lander"}, {"id":3,"label":"agent","title":"@ultimate"},
             {"id":4,"label":"coordinator","title":"Discussing plum orchards"},
             {"id":5,"title":"My conversation"}, {"id":6,"label":"side-chat","title":"Side chat"},
             {"id":7,"label":"researcher","parentConversationId":4,"ownerTaskId":8}]
            """#.utf8)
        #expect(try #require(UltimateProjects.conversations(listing)).map(\.id) == ["3", "4", "5", "6", "7"])
    }

    @Test func aStandingAgentsHandleIsItsTitleAndABranchTitleIsNever() {
        let conversations = UltimateProjects.conversations(Data(Self.listing.utf8)) ?? []
        #expect(conversations.first { $0.id == "53" }?.handle == "@ultimate")
        #expect(conversations.first { $0.id == "72" }?.handle == "@scribe")
        #expect(conversations.first { $0.id == "61" }?.handle == nil)
        #expect(conversations.first { $0.id == "61" }?.folder == "/h/worktrees/61")
    }

    @Test func aConversationsLatestActivityIsItsNewerOfInputAndAnswer() {
        let conversations = UltimateProjects.conversations(Data(Self.listing.utf8)) ?? []
        #expect(conversations.first { $0.id == "53" }?.activeAt == 1_795_105_970)
        #expect(conversations.first { $0.id == "72" }?.activeAt == nil)
    }

    @Test func theConnectorsListIsTakenAsItGivesEachConversation() throws {
        let answer = Data(#"""
            {"result":[{"id":53,"handle":"@ultimate","title":"@ultimate","cwd":"/w","activeAt":9},
                       {"id":61,"title":"Discussing plum orchards","cwd":"/w/wt/61"},
                       {"id":70,"handle":"feather","cwd":"/w/wt/61"}]}
            """#.utf8)
        #expect(UltimateProjects.listed(answer) == [
            .init(id: "53", handle: "@ultimate", sidebarTitle: "@ultimate", folder: "/w", activeAt: 9),
            .init(id: "61", sidebarTitle: "Discussing plum orchards", folder: "/w/wt/61"),
            .init(id: "70", handle: "feather", folder: "/w/wt/61"),
        ])
        #expect(UltimateProjects.listed(Data(#"{"result":[]}"#.utf8)) == [])
        #expect(UltimateProjects.listed(Data(#"{"ok":false}"#.utf8)) == nil)
        #expect(UltimateProjects.listed(Data(#"[{"id":53,"cwd":"/w"}]"#.utf8)) == nil)
    }

    @Test func theFileGivesOnlyStandingAgentsAHandle() throws {
        let listing = Data(#"""
            [{"id":4,"label":"coordinator","title":"Discussing plum orchards","cwd":"/w"},
             {"id":6,"label":"side-chat","title":"Side chat","cwd":"/w"}]
            """#.utf8)
        let conversations = try #require(UltimateProjects.conversations(listing))
        #expect(conversations.map(\.handle) == [nil, nil])
        #expect(conversations.map(\.sidebarTitle) == ["Discussing plum orchards", "Side chat"])
    }

    @Test func aListingThatIsNotAnArrayOfConversationsIsUnreadableNotEmpty() {
        #expect(UltimateProjects.conversations(Data("{}".utf8)) == nil)
        #expect(UltimateProjects.conversations(Data("[".utf8)) == nil)
        #expect(UltimateProjects.conversations(Data("[]".utf8)) == [])
    }

    @Test func theLockNamesTheProcessAndPortServingAProject() {
        let lock = UltimateProjects.lock(Data(#"{"pid":21528,"port":4747,"project":"/w/app"}"#.utf8))
        #expect(lock == UltimateProjects.Lock(pid: 21528, port: 4747))
    }

    @Test func aLockWithoutAUsablePidOrPortServesNothing() {
        #expect(UltimateProjects.lock(Data(#"{"pid":0,"port":4747}"#.utf8)) == nil)
        #expect(UltimateProjects.lock(Data(#"{"pid":12,"port":0}"#.utf8)) == nil)
        #expect(UltimateProjects.lock(Data(#"{"pid":12}"#.utf8)) == nil)
        #expect(UltimateProjects.lock(Data("nope".utf8)) == nil)
    }

    @Test func theProjectRecordNamesTheProjectByItsFolder() {
        let project = UltimateProjects.project(Data(#"{"root":"/w/my-app","name":"my-app","openedAt":1}"#.utf8))
        #expect(project == UltimateProjects.Project(root: "/w/my-app", name: "my-app"))
        #expect(UltimateProjects.project(Data(#"{"name":"x"}"#.utf8)) == nil)
    }

    @Test func aSetupFolderIsAnUltimateUserFolder() {
        #expect(UltimateProjects.isSetupFolder(name: ".ultimate", contents: ["projects", "settings.json"]))
        #expect(UltimateProjects.isSetupFolder(name: ".ultimate", contents: ["model-families.json"]))
        #expect(!UltimateProjects.isSetupFolder(name: "ultimate", contents: ["projects"]))
        #expect(!UltimateProjects.isSetupFolder(name: ".ultimate", contents: ["notes.txt"]))
    }

    @Test func turnedOffMeansTheUserSettingsDisableTheExtensionByItsFolderName() {
        let settings = Data(#"{"extensions":{"disable":["keyscribe","sounds"]}}"#.utf8)
        #expect(UltimateProjects.turnedOff(settings, extension: "keyscribe") == true)
        #expect(UltimateProjects.turnedOff(settings, extension: "keyscribe-dev") == false)
        #expect(UltimateProjects.turnedOff(Data("{}".utf8), extension: "keyscribe") == false)
        #expect(UltimateProjects.turnedOff(nil, extension: "keyscribe") == false)
        #expect(UltimateProjects.turnedOff(Data("{".utf8), extension: "keyscribe") == nil)
        #expect(UltimateProjects.turnedOff(Data(#"{"extensions":{"disable":"keyscribe"}}"#.utf8), extension: "keyscribe") == nil)
    }
}
