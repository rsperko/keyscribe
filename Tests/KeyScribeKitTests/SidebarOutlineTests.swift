import Testing
@testable import KeyScribeKit

struct SidebarOutlineTests {
    private typealias Node = SidebarNode
    private typealias Item = VoiceCommandCatalog.SidebarItem

    private func row(
        title: String? = nil, label: String? = nil, level: Int? = nil, _ children: [Node] = []
    ) -> Node {
        Node(role: "AXRow", subrole: "AXOutlineRow", title: title, label: label, level: level, children: children)
    }

    private func text(_ value: String) -> Node { Node(role: "AXStaticText", value: value) }
    private func group(_ children: [Node], label: String? = nil) -> Node { Node(role: "AXGroup", label: label, children: children) }
    private func cell(label: String? = nil, _ children: [Node]) -> Node { Node(role: "AXCell", label: label, children: children) }
    private func outline(_ rows: [Node]) -> Node { Node(role: "AXOutline", children: rows) }

    private func items(_ outline: Node) -> [Item] {
        SidebarOutline.listing(in: outline, bundleId: "app", pid: 7).items
    }

    private func pressable(_ children: [Node], label: String? = nil) -> Node {
        Node(role: "AXGroup", label: label, actions: ["AXPress"], children: children)
    }

    @Test func aRowIsNamedByItsTextNotItsBadgeOrCount() {
        let mail = outline([
            row([cell(label: "Inbox", [text("Inbox"), Node(role: "AXButton", title: "129")])]),
            row([cell(label: "Notes, 93 notes", [group([text("Notes"), Node(role: "AXUnknown", value: "93")])])]),
            row(title: "Drafts & sent 2", [group([text("Drafts & sent"), text("2")])]),
        ])
        #expect(items(mail).map(\.name) == ["Inbox", "Notes", "Drafts & sent"])
    }

    @Test func anEditableNameStillNamesTheRow() {
        let notes = outline([row([cell([Node(role: "AXTextField", value: "Settings")])])])
        #expect(items(notes).map(\.name) == ["Settings"])
    }

    @Test func aRowWithOnlyATitleUsesIt() {
        #expect(items(outline([row(title: "Threads")])).map(\.name) == ["Threads"])
    }

    @Test func aRowWithNoNameIsSkipped() {
        #expect(items(outline([row([cell([text("  ")])]), row()])).isEmpty)
    }

    @Test func aNestedRowIsListedUnderItsSection() {
        let slack = outline([
            row(title: "Threads", [group([text("Threads")])]),
            row(label: "Channels", [group([row([group([text("general")])]), row([group([text("random")])])])]),
            row(label: "Direct Messages", [group([row([group([group([]), text("Ana Diaz"), text("you")])])])]),
        ])
        #expect(items(slack) == [
            Item(bundleId: "app", pid: 7, name: "Threads", section: nil, path: [0]),
            Item(bundleId: "app", pid: 7, name: "general", section: "Channels", path: [1, 0, 0]),
            Item(bundleId: "app", pid: 7, name: "random", section: "Channels", path: [1, 0, 1]),
            Item(bundleId: "app", pid: 7, name: "Ana Diaz", section: "Direct Messages", path: [2, 0, 0]),
        ])
    }

    @Test func aFlatOutlineTakesItsSectionFromTheRowAboveItsLevel() {
        let mail = outline([
            row(level: 0, [cell([text("Inbox")])]),
            row(level: 1, [cell([text("Work")])]),
            row(level: 1, [cell([text("Home")])]),
            row(level: 0, [cell([text("Home")])]),
            row(level: 1, [cell([text("Receipts")])]),
        ])
        #expect(items(mail).map(\.section) == [nil, "Inbox", "Inbox", nil, "Home"])
    }

    @Test func rowsBeyondTheLimitMakeTheListingIncomplete() {
        let many = outline((0..<(SidebarOutline.itemLimit + 5)).map { row(title: "Row \($0)") })
        let listing = SidebarOutline.listing(in: many, bundleId: "app", pid: 7)
        #expect(listing.items.count == SidebarOutline.itemLimit)
        #expect(!listing.isComplete)
        let exact = outline((0..<SidebarOutline.itemLimit).map { row(title: "Row \($0)") })
        #expect(SidebarOutline.listing(in: exact, bundleId: "app", pid: 7).isComplete)
    }

    @Test func aTreeCutShortMakesTheListingIncomplete() {
        var cut = row(label: "Channels", [group([row([group([text("general")])])])])
        cut.isTruncated = true
        #expect(!SidebarOutline.listing(in: outline([cut]), bundleId: "app", pid: 7).isComplete)
        #expect(SidebarOutline.listing(in: outline([row(title: "Threads")]), bundleId: "app", pid: 7).isComplete)
    }

    @Test func entriesRememberTheirWindow() {
        let listing = SidebarOutline.listing(in: outline([row(title: "Threads")]), bundleId: "app", pid: 7, window: 31)
        #expect(listing.items.map(\.window) == [31])
    }

    @Test func openingPressesTheElementThatHoldsTheName() {
        let slack = outline([
            row(label: "Channels", [group([row([pressable([text("general")])])])]),
        ])
        let general = items(slack)[0]
        #expect(SidebarOutline.openPlan(for: general, in: slack) == .press([0, 0, 0, 0]))
    }

    @Test func openingNeverPressesADisclosureTriangleCheckboxOrButton() {
        for role in ["AXDisclosureTriangle", "AXCheckBox", "AXButton"] {
            let mail = outline([row([
                Node(role: role, actions: ["AXPress"], children: [text("Inbox")]),
                cell([Node(role: "AXButton", title: "129", actions: ["AXPress"])]),
            ])])
            #expect(SidebarOutline.openPlan(for: items(mail)[0], in: mail) == .select([0]))
        }
    }

    @Test func aPressableGroupWithoutTheNameIsNotPressed() {
        let other = outline([row([group([text("general")]), pressable([text("Mute")])])])
        #expect(SidebarOutline.openPlan(for: items(other)[0], in: other) == .select([0]))
    }

    @Test func anOpenIsConfirmedBySelectionOrByTheWindowNamingIt() {
        #expect(SidebarOutline.confirms(name: "general", selected: true, windowTitle: nil))
        #expect(SidebarOutline.confirms(name: "general", selected: false, windowTitle: "general (Channel) - Acme - Slack"))
        #expect(SidebarOutline.confirms(name: "Ana Diaz", selected: nil, windowTitle: "ana diaz (DM) - Slack"))
        #expect(!SidebarOutline.confirms(name: "general", selected: false, windowTitle: "general-chat (Channel) - Slack"))
        #expect(!SidebarOutline.confirms(name: "Sent", selected: nil, windowTitle: "Inbox – 12 messages"))
        #expect(!SidebarOutline.confirms(name: "Sent", selected: false, windowTitle: nil))
    }

    @Test func aCheckSaysWhatWasFound() {
        func listing(_ names: [String], complete: Bool = true, switched: Bool = false) -> SidebarListing {
            var listing = SidebarListing(
                items: names.enumerated().map { Item(bundleId: "app", pid: 7, name: $1, section: nil, path: [$0]) },
                isComplete: complete)
            listing.switchedOnAccessibility = switched
            return listing
        }
        #expect(listing([]).checkSummary(appName: "Slack")
                == "Slack\u{2019}s front window shows no sidebar entries this command can open.")
        #expect(listing(["general", "random", "Ana Diaz", "tech"]).checkSummary(appName: "Slack")
                == "Found 4 entries in Slack\u{2019}s front window, such as general, random, and Ana Diaz.")
        #expect(listing(["Inbox"], complete: false, switched: true).checkSummary(appName: "Slack")
                == "Found 1 entry in Slack\u{2019}s front window, such as Inbox. Not every entry could be read, so a match will be offered as a choice before it opens. Slack\u{2019}s accessibility support was turned on to read it and stays on until Slack quits.")
    }

    @Test func openingRefusesAnEntryThatChangedSinceItWasRead() {
        let before = outline([
            row(label: "Work", [group([row([pressable([text("design")])])])]),
            row(label: "Home", [group([row([pressable([text("design")])])])]),
        ])
        let work = items(before)[0]
        let swapped = outline([
            row(label: "Home", [group([row([pressable([text("design")])])])]),
            row(label: "Work", [group([row([pressable([text("design")])])])]),
        ])
        #expect(SidebarOutline.openPlan(for: work, in: before) != nil)
        #expect(SidebarOutline.openPlan(for: work, in: swapped) == nil)
        #expect(SidebarOutline.openPlan(for: work, in: outline([])) == nil)
    }
}
