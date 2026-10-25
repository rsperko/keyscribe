import Testing
@testable import KeyScribeKit

struct VoiceCommandSidebarTests {
    private typealias Item = VoiceCommandCatalog.SidebarItem

    private let slackId = "com.tinyspeck.slackmacgap"
    private var slack: VoiceCommandPlace { VoiceCommandPlace(name: "Slack", target: .sidebar(bundleId: slackId)) }

    private func item(_ name: String, in section: String? = nil, at path: [Int] = [0]) -> Item {
        Item(bundleId: slackId, pid: 42, name: name, section: section, path: path)
    }

    private func resolve(_ transcript: String, items: [Item]?, complete: Bool = true) -> VoiceCommandResolution {
        var catalog = VoiceCommandCatalog(places: [slack], windows: .complete([]))
        catalog.sidebarItems = items
        catalog.sidebarIsComplete = complete
        return VoiceCommandResolver.resolve(transcript, catalog: catalog)
    }

    @Test func theAppsSidebarIsReadOnlyWhenNeeded() {
        #expect(resolve("slack general", items: nil) == .needsSidebar(slackId))
    }

    @Test func aListedEntryIsOpened() {
        let general = item("general", in: "Channels", at: [1, 0, 0])
        #expect(resolve("slack general", items: [item("Threads"), general]) == .action(.sidebarItem(general)))
    }

    @Test func namesAreMatchedLoosely() {
        let ana = item("Ana Diaz", in: "Direct Messages", at: [2, 0, 0])
        let release = item("release-engineering", in: "Channels", at: [1, 0, 0])
        #expect(resolve("slack ana", items: [ana, release]) == .action(.sidebarItem(ana)))
        #expect(resolve("slack diaz ana", items: [ana, release]) == .action(.sidebarItem(ana)))
        #expect(resolve("slack release engineering", items: [ana, release]) == .action(.sidebarItem(release)))
        #expect(resolve("slack releese engineering", items: [ana, release]) == .action(.sidebarItem(release)))
        #expect(resolve("slack release engineer ing", items: [ana, release]) == .action(.sidebarItem(release)))
    }

    @Test func duplicateNamesAlwaysAsk() {
        let channel = item("design", in: "Channels", at: [1, 0, 0])
        let person = item("design", in: "Apps", at: [3, 0, 0])
        guard case .ambiguous(let choice) = resolve("slack design", items: [channel, person]) else {
            Issue.record("expected a choice"); return
        }
        #expect(choice.candidates == [.sidebarItem(channel), .sidebarItem(person)])
        #expect(VoiceCommandCandidate.sidebarItem(channel).detail(appName: { _ in "Slack" }, among: choice.candidates)
                == "Slack \u{00B7} Channels")
    }

    @Test func aMatchFromAnIncompleteReadAsksInsteadOfOpening() {
        let general = item("general", in: "Channels", at: [1, 0, 0])
        guard case .ambiguous(let choice) = resolve("slack general", items: [general], complete: false) else {
            Issue.record("expected a choice"); return
        }
        #expect(choice.candidates == [.sidebarItem(general)])
        guard case .ambiguous = resolve("slack generel", items: [general], complete: false) else {
            Issue.record("expected a choice for a near miss"); return
        }
    }

    @Test func nothingListedIsReported() {
        #expect(resolve("slack payroll", items: [item("general")]) == .noSidebarMatch("payroll", app: slackId))
    }

    @Test func theNameAloneBringsTheAppForward() {
        #expect(resolve("slack", items: nil) == .action(.place(slack, .app(bundleId: slackId))))
    }

    @Test func switchToTheAppsNameStillOpensTheApp() {
        let app = VoiceCommandCatalog.App(name: "Slack", bundleId: slackId)
        let catalog = VoiceCommandCatalog(places: [slack], runningApps: [app], windows: .complete([]))
        #expect(VoiceCommandResolver.resolve("switch to slack", catalog: catalog) == .action(.app(app)))
    }

    @Test func aSidebarSearchRoundTripsThroughTOML() throws {
        let config = VoiceCommandConfig(places: [slack])
        let toml = try VoiceCommandStore.encode(config)
        #expect(toml.contains("sidebar = '\(slackId)'"))
        #expect(try VoiceCommandStore.decode(from: toml) == config)
        #expect(VoiceCommandStore.unknownKeys(in: toml).isEmpty)
    }

    @Test func aSidebarSearchTakesNoBrowserOrQuickSwitch() {
        for extra in ["browser = \"com.google.Chrome\"", "quick_switch = true"] {
            let toml = """
            schema_version = 1

            [[command]]
            name = "Slack"
            sidebar = "\(slackId)"
            \(extra)
            """
            #expect(throws: ConfigError.self) { try VoiceCommandStore.decode(from: toml) }
        }
    }

    @Test func aSidebarSearchExampleSaysWhereItLooks() {
        let example = VoiceCommandExample.make(for: .place(slack), appName: { _ in "Slack" })
        #expect(example.heard == "slack inbox")
        #expect(example.result == "Opens the entry in Slack\u{2019}s sidebar whose name best matches \u{201C}inbox\u{201D}.")
    }
}
