import AppKit
import ApplicationServices
import KeyScribeKit

enum SidebarAccess {
    nonisolated static let searchDepth = 48
    nonisolated static let rowDepth = 24
    nonisolated static let elementLimit = 6_000
    nonisolated static let skippedRoles: Set<String> = ["AXTable", "AXTextArea", "AXBrowser"]
    nonisolated static let electronWarmUp: TimeInterval = 2
    nonisolated static let electronPoll: TimeInterval = 0.15
    nonisolated static let confirmWindow: TimeInterval = 1
    nonisolated static let confirmPoll: TimeInterval = 0.1

    struct Step {
        let isRequired: Bool
        let run: () -> Bool
    }

    private enum Located {
        case outline(AXUIElement, window: AXUIElement)
        case problem(SidebarProblem)
    }

    nonisolated static func usesElectron(_ app: NSRunningApplication) -> Bool {
        guard let bundle = app.bundleURL else { return false }
        let framework = bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }

    nonisolated static func perform(_ steps: [Step], isCurrent: () -> Bool) -> SidebarOpenResult {
        for step in steps {
            guard isCurrent() else { return .noResponse }
            if !step.run(), step.isRequired { return .noResponse }
        }
        return .opened
    }

    nonisolated static func read(pid: Int32, bundleId: String, electron: Bool, isCurrent: () -> Bool) -> SidebarRead {
        guard AXIsProcessTrusted() else { return .unreadable(.needsAccessibility) }
        let app = application(pid)
        var located = locate(in: frontWindow(app), isCurrent: isCurrent)
        var switched = false
        if electron, case .problem(.noSidebar) = located, isCurrent(), exposeElectronTree(app) {
            switched = true
            let until = Date().addingTimeInterval(electronWarmUp)
            while case .problem(.noSidebar) = located, Date() < until, isCurrent() {
                Thread.sleep(forTimeInterval: electronPoll)
                located = locate(in: frontWindow(app), isCurrent: isCurrent)
            }
        }
        switch located {
        case .problem(let problem): return .unreadable(problem, switchedOnAccessibility: switched)
        case .outline(let outline, let window):
            var budget = elementLimit
            guard let node = node(outline, depth: 0, budget: &budget, isCurrent: isCurrent), isCurrent() else {
                return .unreadable(.noResponse, switchedOnAccessibility: switched)
            }
            return result(of: node, bundleId: bundleId, pid: pid, window: AXWindowID.of(window), switched: switched)
        }
    }

    nonisolated static func result(
        of outline: SidebarNode, bundleId: String, pid: Int32, window: UInt32?, switched: Bool = false
    ) -> SidebarRead {
        guard let window else { return .unreadable(.windowUnknown, switchedOnAccessibility: switched) }
        var listing = SidebarOutline.listing(in: outline, bundleId: bundleId, pid: pid, window: window)
        listing.switchedOnAccessibility = switched
        return .listing(listing)
    }

    nonisolated static func open(_ item: VoiceCommandCatalog.SidebarItem, isCurrent: () -> Bool) -> SidebarOpenResult {
        guard let number = item.window else { return .gone }
        guard let window = window(numbered: number, in: application(item.pid)) else { return .gone }
        guard case .outline(let outline, _) = locate(in: window, isCurrent: isCurrent) else {
            return isCurrent() ? .gone : .noResponse
        }
        var budget = elementLimit
        guard let tree = node(outline, depth: 0, budget: &budget, isCurrent: isCurrent), isCurrent() else { return .noResponse }
        guard let plan = SidebarOutline.openPlan(for: item, in: tree) else { return .gone }
        guard let row = element(at: item.path, in: outline) else { return .gone }
        let raise = Step(isRequired: false) { AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success }
        let outcome: SidebarOpenResult
        switch plan {
        case .press(let path):
            guard let target = element(at: path, in: outline) else { return .gone }
            outcome = perform([raise, Step(isRequired: true) {
                AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
            }], isCurrent: isCurrent)
        case .select:
            outcome = perform([raise, Step(isRequired: true) {
                AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success
            }], isCurrent: isCurrent)
        }
        guard outcome == .opened else { return outcome }
        return confirm(item.name, row: row, window: window, isCurrent: isCurrent)
    }

    nonisolated private static func confirm(
        _ name: String, row: AXUIElement, window: AXUIElement, isCurrent: () -> Bool
    ) -> SidebarOpenResult {
        let until = Date().addingTimeInterval(confirmWindow)
        while isCurrent() {
            var ref: CFTypeRef?
            let selected = AXUIElementCopyAttributeValue(row, kAXSelectedAttribute as CFString, &ref) == .success
                ? (ref as? Bool) : nil
            if SidebarOutline.confirms(name: name, selected: selected, windowTitle: string(window, kAXTitleAttribute)) {
                return .opened
            }
            guard Date() < until else { break }
            Thread.sleep(forTimeInterval: confirmPoll)
        }
        return .unconfirmed
    }

    nonisolated private static func application(_ pid: Int32) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AppWindows.messagingTimeout)
        return app
    }

    nonisolated private static func exposeElectronTree(_ app: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
    }

    nonisolated private static func locate(in window: AXUIElement?, isCurrent: () -> Bool) -> Located {
        guard let window else { return .problem(.noSidebar) }
        var outlines: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var next = 0
        while next < queue.count, next < elementLimit {
            guard isCurrent() else { return .problem(.noResponse) }
            let (element, depth) = queue[next]
            next += 1
            let role = string(element, kAXRoleAttribute) ?? ""
            if role == kAXOutlineRole as String {
                outlines.append(element)
                continue
            }
            guard depth < searchDepth, !skippedRoles.contains(role) else { continue }
            queue += children(element).map { ($0, depth + 1) }
        }
        guard let leftmost = outlines.min(by: { x(of: $0) < x(of: $1) }) else { return .problem(.noSidebar) }
        return .outline(leftmost, window: window)
    }

    nonisolated private static func frontWindow(_ app: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attribute as CFString, &ref) == .success, let ref,
               CFGetTypeID(ref) == AXUIElementGetTypeID() {
                return (ref as! AXUIElement)
            }
        }
        return windows(of: app).first
    }

    nonisolated private static func window(numbered number: UInt32, in app: AXUIElement) -> AXUIElement? {
        windows(of: app).first { AXWindowID.of($0) == number }
    }

    nonisolated private static func windows(of app: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success else { return [] }
        return ref as? [AXUIElement] ?? []
    }

    nonisolated private static func node(
        _ element: AXUIElement, depth: Int, budget: inout Int, isCurrent: () -> Bool
    ) -> SidebarNode? {
        guard isCurrent(), budget > 0 else { return nil }
        budget -= 1
        AXUIElementSetMessagingTimeout(element, AppWindows.messagingTimeout)
        var node = SidebarNode(
            role: string(element, kAXRoleAttribute) ?? "",
            subrole: string(element, kAXSubroleAttribute),
            title: string(element, kAXTitleAttribute),
            label: string(element, kAXDescriptionAttribute),
            value: string(element, kAXValueAttribute),
            level: number(element, kAXDisclosureLevelAttribute),
            actions: actions(of: element))
        let kids = children(element)
        guard depth < rowDepth else {
            node.isTruncated = !kids.isEmpty
            return node
        }
        for child in kids {
            guard let built = Self.node(child, depth: depth + 1, budget: &budget, isCurrent: isCurrent) else {
                node.isTruncated = true
                break
            }
            node.children.append(built)
        }
        return node
    }

    nonisolated private static func element(at path: [Int], in root: AXUIElement) -> AXUIElement? {
        var element = root
        for index in path {
            let kids = children(element)
            guard index < kids.count else { return nil }
            element = kids[index]
        }
        return element
    }

    nonisolated private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success else { return [] }
        return ref as? [AXUIElement] ?? []
    }

    nonisolated private static func actions(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    nonisolated private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    nonisolated private static func number(_ element: AXUIElement, _ attribute: String) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.intValue
    }

    nonisolated private static func x(of element: AXUIElement) -> CGFloat {
        var ref: CFTypeRef?
        var point = CGPoint(x: CGFloat.greatestFiniteMagnitude, y: 0)
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref) == .success, let ref,
              CFGetTypeID(ref) == AXValueGetTypeID() else { return point.x }
        AXValueGetValue(ref as! AXValue, .cgPoint, &point)
        return point.x
    }
}
