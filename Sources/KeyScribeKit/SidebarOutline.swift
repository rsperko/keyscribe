import Foundation

public struct SidebarNode: Equatable, Sendable {
    public var role: String
    public var subrole: String?
    public var title: String?
    public var label: String?
    public var value: String?
    public var level: Int?
    public var actions: [String]
    public var children: [SidebarNode]
    public var isTruncated: Bool

    public init(
        role: String, subrole: String? = nil, title: String? = nil, label: String? = nil, value: String? = nil,
        level: Int? = nil, actions: [String] = [], children: [SidebarNode] = [], isTruncated: Bool = false
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.label = label
        self.value = value
        self.level = level
        self.actions = actions
        self.children = children
        self.isTruncated = isTruncated
    }

    public var isOutlineRow: Bool { subrole == "AXOutlineRow" }
}

public struct SidebarListing: Equatable, Sendable {
    public var items: [VoiceCommandCatalog.SidebarItem]
    public var isComplete: Bool
    public var switchedOnAccessibility = false

    public init(items: [VoiceCommandCatalog.SidebarItem], isComplete: Bool) {
        self.items = items
        self.isComplete = isComplete
    }

    public struct Section: Equatable, Sendable {
        public let title: String?
        public let names: [String]

        public init(title: String?, names: [String]) {
            self.title = title
            self.names = names
        }
    }

    public var sections: [Section] {
        var order: [String?] = []
        var names: [String?: [String]] = [:]
        for item in items {
            if names[item.section] == nil { order.append(item.section) }
            names[item.section, default: []].append(item.name)
        }
        return order.map { Section(title: $0, names: names[$0] ?? []) }
    }

    public func notes(appName: String) -> [String] {
        var notes: [String] = []
        if items.isEmpty { notes.append("\(appName)\u{2019}s front window shows no sidebar items this command can open.") }
        if !isComplete { notes.append("Not every item could be read, so a match will be offered as a choice before it opens.") }
        if switchedOnAccessibility { notes.append(Self.switchedNote(appName: appName)) }
        return notes
    }

    public static func switchedNote(appName: String) -> String {
        "\(appName)\u{2019}s accessibility support was turned on to read it and stays on until \(appName) quits."
    }
}

public enum SidebarOpenPlan: Equatable, Sendable {
    case press([Int])
    case select([Int])
}

public enum SidebarOutline {
    public static let itemLimit = 500
    static let nameDepth = 5
    static let pressDepth = 2
    static let nameRoles: Set<String> = ["AXStaticText", "AXTextField"]
    static let pressRoles: Set<String> = ["AXGroup", "AXLink"]

    public static func listing(
        in outline: SidebarNode, bundleId: String, pid: Int32, window: UInt32? = nil
    ) -> SidebarListing {
        var items: [VoiceCommandCatalog.SidebarItem] = []
        var isComplete = true
        var byLevel: [Int: String] = [:]
        func visit(_ node: SidebarNode, path: [Int], section: String?) {
            if node.isTruncated { isComplete = false }
            for (index, child) in node.children.enumerated() {
                let childPath = path + [index]
                guard child.isOutlineRow else {
                    visit(child, path: childPath, section: section)
                    continue
                }
                guard let name = name(of: child) else {
                    visit(child, path: childPath, section: usable(child.label) ?? usable(child.title) ?? section)
                    continue
                }
                guard items.count < itemLimit else {
                    isComplete = false
                    return
                }
                var rowSection = section
                if let level = child.level {
                    if rowSection == nil, level > 0 { rowSection = byLevel[level - 1] }
                    byLevel = byLevel.filter { $0.key < level }
                    byLevel[level] = name
                }
                items.append(VoiceCommandCatalog.SidebarItem(
                    bundleId: bundleId, pid: pid, name: name, section: rowSection, path: childPath, window: window))
                visit(child, path: childPath, section: name)
            }
        }
        visit(outline, path: [], section: nil)
        return SidebarListing(items: items, isComplete: isComplete)
    }

    public static func openPlan(for item: VoiceCommandCatalog.SidebarItem, in outline: SidebarNode) -> SidebarOpenPlan? {
        let current = listing(in: outline, bundleId: item.bundleId, pid: item.pid, window: item.window).items
        guard current.contains(where: { $0.path == item.path && $0.name == item.name && $0.section == item.section }),
              let row = node(at: item.path, in: outline) else { return nil }
        return pressTarget(in: row, named: item.name).map { .press(item.path + $0) } ?? .select(item.path)
    }

    public static func confirms(name: String, selected: Bool?, windowTitle: String?) -> Bool {
        if selected == true { return true }
        guard let windowTitle else { return false }
        let wanted = words(name)
        let shown = words(windowTitle)
        guard !wanted.isEmpty, wanted.count <= shown.count else { return false }
        return (0...(shown.count - wanted.count)).contains { Array(shown[$0..<$0 + wanted.count]) == wanted }
    }

    private static func words(_ text: String) -> [String] {
        let edges = CharacterSet.alphanumerics.inverted
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: edges) }
            .filter { !$0.isEmpty }
    }

    public static func name(of row: SidebarNode) -> String? {
        firstName(in: row, depth: 1) ?? usable(row.title)
    }

    private static func firstName(in node: SidebarNode, depth: Int) -> String? {
        for child in node.children where !child.isOutlineRow {
            if nameRoles.contains(child.role), let value = usable(child.value) { return value }
            if depth < nameDepth, let found = firstName(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func pressTarget(in node: SidebarNode, named name: String, depth: Int = 1) -> [Int]? {
        guard depth <= pressDepth else { return nil }
        for (index, child) in node.children.enumerated() where !child.isOutlineRow {
            if pressRoles.contains(child.role), child.actions.contains("AXPress"), firstName(in: child, depth: 1) == name {
                return [index]
            }
            if let deeper = pressTarget(in: child, named: name, depth: depth + 1) { return [index] + deeper }
        }
        return nil
    }

    private static func node(at path: [Int], in root: SidebarNode) -> SidebarNode? {
        var node = root
        for index in path {
            guard index < node.children.count else { return nil }
            node = node.children[index]
        }
        return node
    }

    private static func usable(_ text: String?) -> String? {
        AppNaming.usable(text)
    }
}
