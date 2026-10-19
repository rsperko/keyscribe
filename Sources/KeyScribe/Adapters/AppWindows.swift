import AppKit
import ApplicationServices
import KeyScribeKit

struct WindowProcess: Equatable, Sendable {
    let pid: Int32
    let bundleId: String
    let appName: String
}

struct ListedWindow: Equatable, Sendable {
    var subrole: String?
    var title: String?
    var number: CGWindowID?
    var isMinimized = false
    var document: String?
}

enum AppWindowsReply: Equatable, Sendable {
    case windows([ListedWindow])
    case noResponse
    case notTrusted
}

enum WindowFocusResult: Equatable, Sendable {
    case focused
    case alreadyFrontmost
    case gone
    case elsewhere
    case noResponse
    case failed
    case cancelled
}

enum WindowStep: Equatable, Sendable {
    case done
    case noResponse
    case failed
}

struct WindowHandle: @unchecked Sendable {
    let app: AXUIElement
    let window: AXUIElement
}

enum WindowLocation: Sendable {
    case found(WindowHandle, isMinimized: Bool, isFocused: Bool)
    case absent
    case elsewhere
    case noResponse
}

@MainActor
struct WindowSteps {
    var unhide: () async -> WindowStep
    var unminimize: () async -> WindowStep
    var raise: () async -> WindowStep
    var makeMain: () async -> WindowStep
    var activate: () async -> WindowStep
    var activateFallback: () async -> WindowStep
    var confirm: () async -> WindowStep
}

enum AppWindows {
    nonisolated static let messagingTimeout: Float = 0.1

    nonisolated static func processes(excluding ownPid: Int32) -> [WindowProcess] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isTerminated, app.processIdentifier != ownPid,
                  let bundleId = app.bundleIdentifier else { return nil }
            return WindowProcess(pid: app.processIdentifier, bundleId: bundleId, appName: app.localizedName ?? bundleId)
        }
    }

    nonisolated static func targets(_ listed: [ListedWindow], of process: WindowProcess) -> [VoiceCommandCatalog.Window] {
        listed.compactMap { window in
            guard window.subrole == (kAXStandardWindowSubrole as String),
                  let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let number = window.number else { return nil }
            return VoiceCommandCatalog.Window(
                bundleId: process.bundleId, appName: process.appName, pid: process.pid, id: "cg:\(number)", title: title,
                isMinimized: window.isMinimized, document: window.document)
        }
    }

    nonisolated static func collect(
        _ processes: [WindowProcess], trusted: Bool, isCurrent: () -> Bool, read: (WindowProcess) -> AppWindowsReply
    ) -> VoiceCommandCatalog.WindowScan {
        guard trusted else { return .needsAccessibility }
        var windows: [VoiceCommandCatalog.Window] = []
        for process in processes {
            guard isCurrent() else { return .incomplete }
            switch read(process) {
            case .windows(let listed): windows += targets(listed, of: process)
            case .noResponse: return .incomplete
            case .notTrusted: return .needsAccessibility
            }
        }
        return isCurrent() ? .complete(windows) : .incomplete
    }

    nonisolated static func reply(for error: AXError) -> AppWindowsReply {
        switch error {
        case .success, .noValue, .attributeUnsupported, .invalidUIElement, .notImplemented: .windows([])
        case .apiDisabled: .notTrusted
        default: .noResponse
        }
    }

    nonisolated static func read(pid: Int32, isCurrent: () -> Bool) -> AppWindowsReply {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var ref: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref)
        guard error == .success, let elements = ref as? [AXUIElement] else { return reply(for: error) }
        var listed: [ListedWindow] = []
        for element in elements {
            guard isCurrent() else { return .noResponse }
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            switch describe(element) {
            case .some(let window): listed.append(window)
            case .none: return .noResponse
            }
        }
        return .windows(listed)
    }

    nonisolated private static func describe(_ element: AXUIElement) -> ListedWindow? {
        guard case .value(let subrole) = attribute(element, kAXSubroleAttribute) else { return nil }
        var window = ListedWindow(subrole: subrole as? String)
        guard window.subrole == (kAXStandardWindowSubrole as String) else { return window }
        guard case .value(let title) = attribute(element, kAXTitleAttribute) else { return nil }
        window.title = title as? String
        window.number = AXWindowID.of(element)
        if case .value(let minimized) = attribute(element, kAXMinimizedAttribute) { window.isMinimized = (minimized as? Bool) == true }
        if case .value(let document) = attribute(element, kAXDocumentAttribute) { window.document = document as? String }
        return window
    }

    private enum Attribute {
        case value(CFTypeRef?)
        case unanswered
    }

    nonisolated private static func attribute(_ element: AXUIElement, _ name: String) -> Attribute {
        var ref: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, name as CFString, &ref) {
        case .success: return .value(ref)
        case .noValue, .attributeUnsupported: return .value(nil)
        default: return .unanswered
        }
    }

    nonisolated static func locate(_ target: VoiceCommandCatalog.Window, isCurrent: () -> Bool) -> WindowLocation {
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var ref: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref)
        guard isCurrent(), case .windows = reply(for: error) else { return .noResponse }
        for element in (ref as? [AXUIElement]) ?? [] {
            guard isCurrent() else { return .noResponse }
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            guard let number = AXWindowID.of(element), "cg:\(number)" == target.id else { continue }
            let minimized: Bool
            switch attribute(element, kAXMinimizedAttribute) {
            case .value(let value): minimized = (value as? Bool) == true
            case .unanswered: return .noResponse
            }
            var focused: CFTypeRef?
            let isFocused = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success
                && focused.map { CFGetTypeID($0) == AXUIElementGetTypeID() && AXWindowID.of($0 as! AXUIElement) == number } == true
            return .found(WindowHandle(app: app, window: element), isMinimized: minimized, isFocused: isFocused)
        }
        return exists(target) ? .elsewhere : .absent
    }

    nonisolated static func exists(_ target: VoiceCommandCatalog.Window) -> Bool {
        guard target.id.hasPrefix("cg:"), let number = CGWindowID(target.id.dropFirst(3)),
              let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], number) as? [[String: Any]] else { return false }
        return info.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == target.pid }
    }

    @MainActor
    static func bringForward(
        isHidden: Bool, isMinimized: Bool, steps: WindowSteps, stillWanted: @MainActor () -> Bool
    ) async -> WindowFocusResult {
        enum Kind { case required, optional, activate }
        var sequence: [(step: () async -> WindowStep, kind: Kind)] = []
        if isHidden { sequence.append((steps.unhide, .required)) }
        if isMinimized { sequence.append((steps.unminimize, .required)) }
        sequence += [(steps.raise, .required), (steps.makeMain, .optional), (steps.activate, .activate), (steps.confirm, .required)]
        for (step, kind) in sequence {
            guard stillWanted() else { return .cancelled }
            var result = await step()
            if kind == .optional { continue }
            if kind == .activate, result == .failed {
                guard stillWanted() else { return .cancelled }
                result = await steps.activateFallback()
            }
            switch result {
            case .done: continue
            case .noResponse: return .noResponse
            case .failed: return .failed
            }
        }
        return stillWanted() ? .focused : .cancelled
    }

    nonisolated static func step(_ error: AXError) -> WindowStep {
        switch error {
        case .success: .done
        case .cannotComplete: .noResponse
        default: .failed
        }
    }

    nonisolated static let confirmAttempts = 6
    nonisolated static let confirmInterval: TimeInterval = 0.05

    nonisolated static func isInFront(_ handle: WindowHandle, number: CGWindowID, isCurrent: () -> Bool) -> WindowStep {
        var answered = false
        for attempt in 0..<confirmAttempts {
            guard isCurrent() else { return .noResponse }
            if attempt > 0 { Thread.sleep(forTimeInterval: confirmInterval) }
            var frontmost: CFTypeRef?
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(handle.app, kAXFrontmostAttribute as CFString, &frontmost) == .success,
                  AXUIElementCopyAttributeValue(handle.app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
                  let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { continue }
            answered = true
            if (frontmost as? Bool) == true, AXWindowID.of(focused as! AXUIElement) == number { return .done }
        }
        return answered ? .failed : .noResponse
    }

    @MainActor
    static func liveSteps(
        _ handle: WindowHandle, number: CGWindowID, app running: NSRunningApplication,
        withinDeadline: @escaping () -> Bool,
        perform: @escaping (@escaping @Sendable (_ isCurrent: () -> Bool) -> WindowStep) async -> WindowStep
    ) -> WindowSteps {
        WindowSteps(
            unhide: { running.unhide() ? .done : .failed },
            unminimize: {
                await perform { _ in
                    step(AXUIElementSetAttributeValue(handle.window, kAXMinimizedAttribute as CFString, kCFBooleanFalse))
                }
            },
            raise: { await perform { _ in step(AXUIElementPerformAction(handle.window, kAXRaiseAction as CFString)) } },
            makeMain: {
                await perform { _ in step(AXUIElementSetAttributeValue(handle.window, kAXMainAttribute as CFString, kCFBooleanTrue)) }
            },
            activate: {
                await perform { _ in
                    step(AXUIElementSetAttributeValue(handle.app, kAXFrontmostAttribute as CFString, kCFBooleanTrue))
                }
            },
            activateFallback: {
                guard withinDeadline(), !running.isTerminated else { return .noResponse }
                return running.activate() ? .done : .failed
            },
            confirm: { await perform { isInFront(handle, number: number, isCurrent: $0) } })
    }
}
