import AppKit
import ApplicationServices
import KeyScribeKit

struct VoiceCommandOrigin: Equatable, Sendable {
    let bundleId: String
    var pid: Int32?
    var windowId: String?

    init(bundleId: String, pid: Int32? = nil, windowId: String? = nil) {
        self.bundleId = bundleId
        self.pid = pid
        self.windowId = windowId.flatMap { $0.hasPrefix("cg:") ? $0 : nil }
    }
}

enum VoiceCommandFailureKind: Equatable, Sendable {
    case unrecognizedCommand
    case other
}

enum VoiceCommandRetryReason: Equatable, Sendable {
    case unrecognizedAnswer
    case invalidSelection
}

enum VoiceCommandOutcome: Equatable, Sendable {
    case done(summary: String, command: String)
    case started(summary: String, command: String)
    case failed(message: String, command: String? = nil, action: HUDErrorAction? = nil, kind: VoiceCommandFailureKind = .other)
    case needsChoice(VoiceCommandPendingChoice)
    case abandoned
}

struct VoiceCommandChoiceRow: Equatable, Sendable {
    let number: Int
    let name: String
    let detail: String
    let identity: String
}

struct VoiceCommandPendingChoice: Equatable, Sendable {
    let id: Int
    let choice: VoiceCommandChoice
    let request: String
    let origin: VoiceCommandOrigin?
    let rows: [VoiceCommandChoiceRow]
    let places: [VoiceCommandPlace]
    let scripts: [VoiceCommandScript]
}

struct VoiceCommandSelection: Equatable, Sendable {
    let name: String
    let request: String
    let outcome: VoiceCommandOutcome
}

enum VoiceCommandAnswer: Equatable, Sendable {
    case selected(VoiceCommandSelection)
    case cancelled(request: String)
    case retry(message: String, reason: VoiceCommandRetryReason)
    case command(VoiceCommandOutcome)
}

struct TabRead: Equatable, Sendable {
    var tabs: [VoiceCommandCatalog.Tab]
    var refused: [String] = []
    var unavailable: [String] = []
}

enum BrowserTabsReply: Equatable, Sendable {
    case tabs([VoiceCommandCatalog.Tab])
    case refused
    case unavailable
}

enum ScriptRun: Equatable, Sendable {
    case finished(status: Int32, lastError: String?)
    case stillRunning
    case notRunnable
    case couldNotStart(String)
}

enum TabFocusResult: Equatable, Sendable {
    case focused
    case gone
    case noResponse
}

@MainActor
protocol VoiceCommandSystem: AnyObject {
    var ownBundleId: String? { get }
    func defaultBrowserId(for url: String) -> String?
    func runningApps() -> [VoiceCommandCatalog.App]
    func installedApps() async -> [VoiceCommandCatalog.App]
    func browserTabs(in browser: String?) async -> TabRead?
    func appName(forBundleId bundleId: String) -> String?
    func isRunning(bundleId: String) -> Bool
    func isInstalled(bundleId: String) -> Bool
    func openApp(bundleId: String) async -> Bool
    func focusTab(_ tab: VoiceCommandCatalog.Tab) async -> TabFocusResult
    func windows() async -> VoiceCommandCatalog.WindowScan
    func focusWindow(_ window: VoiceCommandCatalog.Window, stillWanted: @MainActor () -> Bool) async -> WindowFocusResult
    func isRunning(pid: Int32, bundleId: String) -> Bool
    func activate(pid: Int32) -> Bool
    func openURL(_ url: String, browser: String?) async -> Bool
    func runScript(
        _ script: VoiceCommandScript, arguments: [String], onLateFinish: @escaping @MainActor (ScriptRun) -> Void
    ) async -> ScriptRun
}

@MainActor
protocol VoiceCommandRunning: AnyObject {
    func run(
        transcript: String, places: [VoiceCommandPlace], scripts: [VoiceCommandScript], origin: VoiceCommandOrigin?,
        stillWanted: @MainActor () -> Bool, onLateResult: @escaping @MainActor (VoiceCommandOutcome) -> Void
    ) async -> VoiceCommandOutcome
    var pendingChoice: VoiceCommandPendingChoice? { get }
    func claimChoice() -> Int?
    func resumeChoice(_ id: Int) -> Bool
    func choiceSecondsLeft(_ id: Int) -> Double?
    func expireChoice(_ id: Int) -> Bool
    func dismissChoice(_ id: Int?)
    func takeChoice(_ id: Int) -> VoiceCommandPendingChoice?
    func answer(
        _ transcript: String, choice id: Int, places: [VoiceCommandPlace], scripts: [VoiceCommandScript],
        origin: VoiceCommandOrigin?, stillWanted: @MainActor () -> Bool,
        onLateResult: @escaping @MainActor (VoiceCommandOutcome) -> Void
    ) async -> VoiceCommandAnswer
    func runChoice(
        _ pending: VoiceCommandPendingChoice, candidate identity: String, places: [VoiceCommandPlace],
        scripts: [VoiceCommandScript], stillWanted: @MainActor () -> Bool,
        onLateResult: @escaping @MainActor (VoiceCommandOutcome) -> Void
    ) async -> VoiceCommandSelection?
}

extension VoiceCommandRunning {
    var pendingChoice: VoiceCommandPendingChoice? { nil }
    func claimChoice() -> Int? { nil }
    func resumeChoice(_ id: Int) -> Bool { false }
    func choiceSecondsLeft(_ id: Int) -> Double? { nil }
    func expireChoice(_ id: Int) -> Bool { false }
    func dismissChoice(_ id: Int?) {}
    func takeChoice(_ id: Int) -> VoiceCommandPendingChoice? { nil }
    func answer(
        _ transcript: String, choice id: Int, places: [VoiceCommandPlace], scripts: [VoiceCommandScript],
        origin: VoiceCommandOrigin?, stillWanted: @MainActor () -> Bool,
        onLateResult: @escaping @MainActor (VoiceCommandOutcome) -> Void
    ) async -> VoiceCommandAnswer {
        .command(await run(transcript: transcript, places: places, scripts: scripts, origin: origin,
                           stillWanted: stillWanted, onLateResult: onLateResult))
    }
    func runChoice(
        _ pending: VoiceCommandPendingChoice, candidate identity: String, places: [VoiceCommandPlace],
        scripts: [VoiceCommandScript], stillWanted: @MainActor () -> Bool,
        onLateResult: @escaping @MainActor (VoiceCommandOutcome) -> Void
    ) async -> VoiceCommandSelection? { nil }
}

@MainActor
final class VoiceCommandRunner: VoiceCommandRunning {
    static let choiceIdleSeconds: Double = 30

    private let system: VoiceCommandSystem
    private let now: () -> Double
    private let idleSeconds: Double
    private(set) var backTarget: VoiceCommandOrigin?
    private var live: (choice: VoiceCommandPendingChoice, phase: ChoicePhase)?
    private var lastChoiceId = 0

    private enum ChoicePhase: Equatable {
        case waiting(until: Double)
        case answering
    }

    var pendingChoice: VoiceCommandPendingChoice? { live?.choice }

    init(
        system: VoiceCommandSystem = LiveVoiceCommandSystem.shared,
        now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        idleSeconds: Double = VoiceCommandRunner.choiceIdleSeconds
    ) {
        self.system = system
        self.now = now
        self.idleSeconds = idleSeconds
    }

    func resolve(
        _ transcript: String, places: [VoiceCommandPlace], scripts: [VoiceCommandScript] = []
    ) async -> VoiceCommandResolution {
        let withoutApps = VoiceCommandResolver.resolve(
            transcript, catalog: VoiceCommandCatalog(scripts: scripts, windows: .complete([])))
        guard case .noMatch = withoutApps else { return withoutApps }
        let running = system.runningApps()
        let installed = VoiceCommandCatalog.reconciling(installed: await system.installedApps(), with: running)
        let catalog = VoiceCommandCatalog(places: places, scripts: scripts, runningApps: running, installedApps: installed)
        return await readingWindows(catalog) { VoiceCommandResolver.resolve(transcript, catalog: $0) }
    }

    private func readingWindows(
        _ catalog: VoiceCommandCatalog, _ resolve: (VoiceCommandCatalog) -> VoiceCommandResolution
    ) async -> VoiceCommandResolution {
        let first = await readingTabs(catalog, resolve)
        guard case .needsWindows = first else { return first }
        var catalog = catalog
        catalog.windows = await system.windows()
        return await readingTabs(catalog, resolve)
    }

    private func readingTabs(
        _ catalog: VoiceCommandCatalog, _ resolve: (VoiceCommandCatalog) -> VoiceCommandResolution
    ) async -> VoiceCommandResolution {
        var catalog = catalog
        let first = resolve(catalog)
        guard case .needsTabs(let browser) = first else { return first }
        guard let read = await system.browserTabs(in: browser) else { return first }
        catalog.tabs = read.tabs
        let resolved = resolve(catalog)
        if case .action(.place(_, .openURL(let url, let opener))) = resolved,
           let destination = opener ?? system.defaultBrowserId(for: url) {
            if read.refused.contains(destination) { return .browserNotAllowed(destination) }
            if read.unavailable.contains(destination) { return .needsTabs(browser: destination) }
        }
        return resolved
    }

    func run(
        transcript: String, places: [VoiceCommandPlace], scripts: [VoiceCommandScript] = [],
        origin: VoiceCommandOrigin?, stillWanted: @MainActor () -> Bool = { true },
        onLateResult: @escaping @MainActor (VoiceCommandOutcome) -> Void = { _ in }
    ) async -> VoiceCommandOutcome {
        live = nil
        let resolution = await resolve(transcript, places: places, scripts: scripts)
        guard stillWanted() else { return .abandoned }
        if case .ambiguous(let choice) = resolution, choice.isOffered {
            return .needsChoice(offer(choice, request: transcript, origin: origin, places: places, scripts: scripts))
        }
        return await run(resolution, origin: origin, stillWanted: stillWanted, onLateResult: onLateResult)
    }

    private func offer(
        _ choice: VoiceCommandChoice, request: String, origin: VoiceCommandOrigin?, places: [VoiceCommandPlace],
        scripts: [VoiceCommandScript]
    ) -> VoiceCommandPendingChoice {
        lastChoiceId += 1
        let rows = choice.candidates.enumerated().map { index, candidate in
            VoiceCommandChoiceRow(
                number: index + 1, name: candidate.name,
                detail: candidate.detail(appName: system.appName(forBundleId:), among: choice.candidates),
                identity: candidate.identity)
        }
        let pending = VoiceCommandPendingChoice(
            id: lastChoiceId, choice: choice, request: request, origin: origin, rows: rows, places: places, scripts: scripts)
        live = (pending, .waiting(until: now() + idleSeconds))
        return pending
    }

    private func deadline(of id: Int) -> Double? {
        guard let live, live.choice.id == id, case .waiting(let until) = live.phase else { return nil }
        return until
    }

    func claimChoice() -> Int? {
        guard let live, let until = deadline(of: live.choice.id) else { return nil }
        guard now() < until else { self.live = nil; return nil }
        self.live?.phase = .answering
        return live.choice.id
    }

    func resumeChoice(_ id: Int) -> Bool {
        guard live?.choice.id == id, live?.phase == .answering else { return false }
        live?.phase = .waiting(until: now() + idleSeconds)
        return true
    }

    func choiceSecondsLeft(_ id: Int) -> Double? {
        deadline(of: id).map { max(0, $0 - now()) }
    }

    func expireChoice(_ id: Int) -> Bool {
        guard let until = deadline(of: id), now() >= until else { return false }
        live = nil
        return true
    }

    func dismissChoice(_ id: Int? = nil) {
        guard let live, id == nil || live.choice.id == id else { return }
        self.live = nil
    }

    func takeChoice(_ id: Int) -> VoiceCommandPendingChoice? {
        guard let live, live.choice.id == id else { return nil }
        self.live = nil
        return live.choice
    }

    func answer(
        _ transcript: String, choice id: Int, places: [VoiceCommandPlace], scripts: [VoiceCommandScript],
        origin: VoiceCommandOrigin?, stillWanted: @MainActor () -> Bool = { true },
        onLateResult: @escaping @MainActor (VoiceCommandOutcome) -> Void = { _ in }
    ) async -> VoiceCommandAnswer {
        guard let live, live.choice.id == id, live.phase == .answering else {
            return .command(await run(transcript: transcript, places: places, scripts: scripts, origin: origin,
                                      stillWanted: stillWanted, onLateResult: onLateResult))
        }
        let pending = live.choice
        switch VoiceCommandChoiceAnswer.parse(transcript, count: pending.rows.count) {
        case .select(let index):
            self.live = nil
            let selection = await runChoice(
                pending, candidate: pending.rows[index].identity, places: places, scripts: scripts,
                stillWanted: stillWanted, onLateResult: onLateResult)
            return selection.map(VoiceCommandAnswer.selected) ?? .command(.abandoned)
        case .cancel:
            self.live = nil
            return .cancelled(request: pending.request)
        case .invalidSelection:
            return .retry(message: pending.choice.retryMessage, reason: .invalidSelection)
        case .unrecognized:
            guard VoiceCommandGrammar.parse(transcript) != nil else {
                return .retry(message: pending.choice.retryMessage, reason: .unrecognizedAnswer)
            }
            return .command(await run(transcript: transcript, places: places, scripts: scripts, origin: origin,
                                      stillWanted: stillWanted, onLateResult: onLateResult))
        }
    }

    func runChoice(
        _ pending: VoiceCommandPendingChoice, candidate identity: String, places: [VoiceCommandPlace],
        scripts: [VoiceCommandScript], stillWanted: @MainActor () -> Bool = { true },
        onLateResult: @escaping @MainActor (VoiceCommandOutcome) -> Void = { _ in }
    ) async -> VoiceCommandSelection? {
        if live?.choice.id == pending.id { live = nil }
        guard let candidate = pending.choice.candidates.first(where: { $0.identity == identity }) else { return nil }
        let resolution: VoiceCommandResolution
        if case .app(let app) = candidate, !system.isInstalled(bundleId: app.bundleId), !system.isRunning(bundleId: app.bundleId) {
            resolution = .unavailable(app.name)
        } else {
            resolution = await readingTabs(VoiceCommandCatalog(places: places, scripts: scripts)) {
                VoiceCommandResolver.resolve(candidate, text: pending.choice.text, catalog: $0)
            }
        }
        guard stillWanted() else { return VoiceCommandSelection(name: candidate.name, request: pending.request, outcome: .abandoned) }
        let outcome = await run(resolution, origin: pending.origin, stillWanted: stillWanted, onLateResult: onLateResult)
        return VoiceCommandSelection(name: candidate.name, request: pending.request, outcome: outcome)
    }

    func run(
        _ resolution: VoiceCommandResolution, origin: VoiceCommandOrigin?,
        stillWanted: @MainActor () -> Bool = { true },
        onLateResult: @escaping @MainActor (VoiceCommandOutcome) -> Void = { _ in }
    ) async -> VoiceCommandOutcome {
        let origin = origin.flatMap { $0.bundleId == system.ownBundleId ? nil : $0 }
        switch resolution {
        case .notACommand:
            return .failed(message: "Not a command. \(Self.notACommandHint)",
                           kind: .unrecognizedCommand)
        case .scriptNotFound(let target):
            return .failed(message: Self.notFoundMessage(target))
        case .noMatch(let target):
            return .failed(message: Self.noMatchMessage(target))
        case .needsWindows, .windowsIncomplete:
            return .failed(message: Self.windowsIncompleteMessage)
        case .windowsNeedAccessibility:
            return .failed(message: Self.windowsNeedAccessibilityMessage, action: .openAccessibilitySettings)
        case .ambiguous(let choice):
            return .failed(message: choice.tooManyMessage)
        case .unavailable(let name):
            return .failed(message: Self.unavailableMessage(name))
        case .needsTabs(let browser):
            let name = browser.flatMap(system.appName(forBundleId:)) ?? "The browser"
            return .failed(message: "\(name) did not list its open tabs, so nothing was opened.")
        case .browserNotAllowed(let browser):
            return .failed(message: Self.notAllowedMessage(browser: system.appName(forBundleId: browser) ?? browser))
        case .scriptNeedsText(let name):
            return .failed(message: Self.needsTextMessage(script: name))
        case .action(let action):
            return await execute(action, origin: origin, stillWanted: stillWanted, onLateResult: onLateResult)
        }
    }

    private func execute(
        _ action: VoiceCommandAction, origin: VoiceCommandOrigin?, stillWanted: @MainActor () -> Bool,
        onLateResult: @escaping @MainActor (VoiceCommandOutcome) -> Void
    ) async -> VoiceCommandOutcome {
        let summary = action.summary(appName: system.appName(forBundleId:))
        var command = action.command(appName: system.appName(forBundleId:))
        let succeeded: Bool
        switch action {
        case .goBack:
            return await goBack(to: origin, stillWanted: stillWanted)
        case .window(let window):
            switch await system.focusWindow(window, stillWanted: stillWanted) {
            case .focused:
                succeeded = true
            case .alreadyFrontmost:
                return .done(summary: summary, command: command)
            case .gone:
                return .failed(message: Self.windowGoneMessage, command: command)
            case .elsewhere:
                return .failed(message: Self.windowElsewhereMessage, command: command)
            case .noResponse, .failed:
                return .failed(message: Self.windowNotForwardMessage(window.appName), command: command)
            case .cancelled:
                return .abandoned
            }
            guard stillWanted() else { return .abandoned }
        case .app(let app):
            succeeded = await system.openApp(bundleId: app.bundleId)
        case .place(_, .app(let bundleId)):
            succeeded = await system.openApp(bundleId: bundleId)
        case .place(let place, .tab(let tab)):
            let focus = await system.focusTab(tab)
            guard focus == .noResponse || stillWanted() else { return .abandoned }
            switch focus {
            case .focused:
                succeeded = await system.openApp(bundleId: tab.browserBundleId)
            case .noResponse:
                let browser = system.appName(forBundleId: tab.browserBundleId) ?? "The browser"
                return .failed(message: "\(browser) did not respond, so \(place.name) was not opened again.", command: command)
            case .gone:
                guard case .url(let url) = place.target else {
                    return .failed(message: "Could not switch to \(summary).", command: command)
                }
                if let refusal = browserRefusal(place.browser, place: place) { return refusal }
                command = VoiceCommandAction.place(place, .openURL(url, browser: place.browser))
                    .command(appName: system.appName(forBundleId:))
                succeeded = await system.openURL(url, browser: place.browser)
            }
        case .place(let place, .openURL(let url, let browser)):
            if let refusal = browserRefusal(browser, place: place) { return refusal }
            succeeded = await system.openURL(url, browser: browser)
        case .script(let script, let arguments):
            let run = await system.runScript(script, arguments: arguments) { late in
                onLateResult(Self.outcome(of: late, script: script, command: command))
            }
            return Self.outcome(of: run, script: script, command: command)
        }
        guard succeeded else { return .failed(message: "Could not switch to \(summary).", command: command) }
        if let origin, origin.bundleId != Self.appBundleId(of: action) { backTarget = origin }
        return .done(summary: summary, command: command)
    }

    private static func appBundleId(of action: VoiceCommandAction) -> String? {
        switch action {
        case .app(let app): return app.bundleId
        case .place(_, .app(let bundleId)): return bundleId
        default: return nil
        }
    }

    private func goBack(to origin: VoiceCommandOrigin?, stillWanted: @MainActor () -> Bool) async -> VoiceCommandOutcome {
        let nothing = VoiceCommandOutcome.failed(message: "Nothing to go back to.")
        guard let back = backTarget else { return nothing }
        let name = system.appName(forBundleId: back.bundleId) ?? back.bundleId
        let command = "Returns to \(name)."
        let failure = VoiceCommandOutcome.failed(message: "Could not go back.", command: command)
        if let pid = back.pid, let windowId = back.windowId {
            let window = VoiceCommandCatalog.Window(bundleId: back.bundleId, appName: name, pid: pid, id: windowId, title: "")
            switch await system.focusWindow(window, stillWanted: stillWanted) {
            case .focused:
                guard stillWanted() else { return .abandoned }
                backTarget = origin
                return .done(summary: name, command: command)
            case .alreadyFrontmost:
                return .done(summary: name, command: command)
            case .gone, .elsewhere:
                break
            case .noResponse, .failed:
                return failure
            case .cancelled:
                return .abandoned
            }
        }
        let succeeded: Bool
        if let pid = back.pid {
            guard system.isRunning(pid: pid, bundleId: back.bundleId) else { return nothing }
            guard stillWanted() else { return .abandoned }
            succeeded = system.activate(pid: pid)
        } else {
            guard system.isRunning(bundleId: back.bundleId) else { return nothing }
            succeeded = await system.openApp(bundleId: back.bundleId)
        }
        guard succeeded else { return failure }
        backTarget = origin
        return .done(summary: name, command: command)
    }

    nonisolated static func noMatchMessage(_ target: String) -> String {
        "No matching app, place, or window found for \u{201C}\(target)\u{201D}."
    }

    nonisolated static let windowsIncompleteMessage = "Could not check all open windows. Nothing was opened. Try again."
    nonisolated static let windowsNeedAccessibilityMessage =
        "Accessibility is off, so open windows could not be checked. Nothing was opened."
    nonisolated static let windowGoneMessage = "That window is no longer open."
    nonisolated static let windowElsewhereMessage = "That window is now on another desktop, so it was not brought forward."

    nonisolated static func windowNotForwardMessage(_ app: String) -> String {
        "Could not bring that window forward in \(app). Try again."
    }

    static func unavailableMessage(_ name: String) -> String {
        "\(name) is no longer available, so nothing was run."
    }

    static func needsTextMessage(script: String) -> String {
        "Say what to pass to \(script) after its name."
    }

    static let notACommandHint = VoiceCommandPhrase.guidance.prefix(1).uppercased() + VoiceCommandPhrase.guidance.dropFirst() + "."

    static func notFoundMessage(_ target: String) -> String {
        "No script or shortcut is called \u{201C}\(target)\u{201D}."
    }

    static func outcome(of run: ScriptRun, script: VoiceCommandScript, command: String) -> VoiceCommandOutcome {
        switch run {
        case .finished(0, _):
            return .done(summary: script.name, command: command)
        case .stillRunning:
            return .started(summary: script.name, command: command)
        case .finished(let status, let lastError):
            let exit = script.isShortcut ? "" : " (exit \(status))"
            return .failed(message: "\(script.name) failed\(exit)" + (lastError.map { ": \($0)" } ?? "."), command: command)
        case .notRunnable where script.isShortcut:
            return .failed(message: "Shortcuts could not be started from \(Branding.appName) on this Mac.", command: command)
        case .notRunnable:
            return .failed(
                message: "\(script.program) is not a program that can be run. Check the path, and that the file is executable.",
                command: command)
        case .couldNotStart(let reason):
            return .failed(message: "Could not run \(script.name): \(reason)", command: command)
        }
    }

    static func notAllowedMessage(browser: String) -> String {
        "\(Branding.appName) is not allowed to control \(browser), so nothing was opened. Allow it in System Settings \u{2192} Privacy & Security \u{2192} Automation."
    }

    private func browserRefusal(_ browser: String?, place: VoiceCommandPlace) -> VoiceCommandOutcome? {
        guard let browser, !system.isInstalled(bundleId: browser) else { return nil }
        return .failed(message: "The browser chosen for \(place.name) is not installed.")
    }
}

@MainActor
final class LiveVoiceCommandSystem: VoiceCommandSystem {
    static let shared = LiveVoiceCommandSystem()

    struct InstalledScan: Sendable {
        let apps: [VoiceCommandCatalog.App]
        let browsers: [VoiceCommandCatalog.App]
        let tabBrowsers: Set<String>
        let generation: Int
        let completedAt: ContinuousClock.Instant
    }

    private var snapshot: InstalledScan?
    private var scanning: Task<InstalledScan, Never>?
    private var generations = 0
    private let roots: [URL]
    private let handlers: @Sendable () -> [URL]
    private let now: () -> ContinuousClock.Instant
    private static let installedTTL: Duration = .seconds(60)
    private static let scripts = DeadlineQueue(label: "com.keyscribe.voice-commands.applescript")
    private static let accessibility = DeadlineQueue(label: "com.keyscribe.voice-commands.accessibility")
    private static let windowReadDeadline: TimeInterval = 1
    private static let tabReadDeadline: TimeInterval = 1.5
    private static let focusDeadline: TimeInterval = 2

    init(
        roots: [URL] = LiveVoiceCommandSystem.applicationRoots,
        handlers: @escaping @Sendable () -> [URL] = LiveVoiceCommandSystem.httpsHandlerURLs,
        now: @escaping () -> ContinuousClock.Instant = { .now }
    ) {
        self.roots = roots
        self.handlers = handlers
        self.now = now
    }

    var ownBundleId: String? { Bundle.main.bundleIdentifier }

    func defaultBrowserId(for url: String) -> String? {
        URL(string: url).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }.flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    func runningApps() -> [VoiceCommandCatalog.App] {
        InstalledApps.runningApps().filter { $0.bundleId != ownBundleId }
    }

    func installedApps() async -> [VoiceCommandCatalog.App] {
        await installedSnapshot().apps
    }

    func installedSnapshot() async -> InstalledScan {
        if let snapshot, now() - snapshot.completedAt < Self.installedTTL { return snapshot }
        if let scanning { return await scanning.value }
        let own = ownBundleId
        let (roots, handlers) = (roots, self.handlers)
        let running = InstalledApps.runningBundleURLs()
        generations += 1
        let generation = generations
        let task = Task { @MainActor in
            let found = await Task.detached(priority: .userInitiated) {
                let registered: @Sendable (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                let apps = Self.scanInstalledApps(in: roots, excluding: own, registered: registered)
                let browsers = Self.scanBrowsers(handlers(), excluding: own, running: running, registered: registered)
                return (apps, browsers)
            }.value
            let scan = InstalledScan(
                apps: found.0, browsers: found.1.browsers, tabBrowsers: found.1.tabBrowsers,
                generation: generation, completedAt: self.now())
            self.snapshot = scan
            self.scanning = nil
            return scan
        }
        scanning = task
        return await task.value
    }

    nonisolated static let applicationRoots = [
        URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    nonisolated static func httpsHandlerURLs() -> [URL] {
        URL(string: "https://example.com").map { NSWorkspace.shared.urlsForApplications(toOpen: $0) } ?? []
    }

    nonisolated static func scanBrowsers(
        _ handlers: [URL], excluding own: String?, running: [String: URL], registered: (String) -> URL? = { _ in nil }
    ) -> (browsers: [VoiceCommandCatalog.App], tabBrowsers: Set<String>) {
        var copies: [String: [URL]] = [:]
        for url in handlers {
            guard let bundleId = infoPlist(of: url)?["CFBundleIdentifier"] as? String, bundleId != own else { continue }
            copies[bundleId, default: []].append(url)
        }
        var tabBrowsers = Set<String>()
        let browsers = copies.compactMap { bundleId, urls -> VoiceCommandCatalog.App? in
            guard let url = running[bundleId] ?? registered(bundleId) ?? urls.min(by: { $0.path < $1.path }) else { return nil }
            if hasScriptableTabs(url) { tabBrowsers.insert(bundleId) }
            return AppNames.app(at: url, bundleId: bundleId)
                ?? AppNaming.app(bundleId: bundleId, names: [url.deletingPathExtension().lastPathComponent])
        }
        return (sortedByName(browsers), tabBrowsers)
    }

    nonisolated private static func sortedByName(_ apps: [VoiceCommandCatalog.App]) -> [VoiceCommandCatalog.App] {
        apps.sorted { a, b in
            let byName = a.name.localizedCaseInsensitiveCompare(b.name)
            return byName != .orderedSame ? byName == .orderedAscending : a.bundleId < b.bundleId
        }
    }

    nonisolated private static func infoPlist(of app: URL) -> [String: Any]? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }

    nonisolated static func scanInstalledApps(
        in roots: [URL], excluding own: String?, registered: (String) -> URL? = { _ in nil }
    ) -> [VoiceCommandCatalog.App] {
        let fm = FileManager.default
        func children(of dir: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        }
        func isFolder(_ url: URL) -> Bool {
            url.pathExtension.isEmpty && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        var copies: [String: [URL]] = [:]
        for root in roots {
            let entries = children(of: root)
            let candidates = entries + entries.filter(isFolder).flatMap(children(of:))
            for url in candidates where url.pathExtension == "app" {
                guard let bundleId = Bundle(url: url)?.bundleIdentifier, bundleId != own else { continue }
                copies[bundleId, default: []].append(url)
            }
        }
        let apps = copies.compactMap { bundleId, urls -> VoiceCommandCatalog.App? in
            guard let url = registered(bundleId) ?? urls.min(by: { $0.path < $1.path }) else { return nil }
            return AppNames.app(at: url, bundleId: bundleId)
                ?? AppNaming.app(bundleId: bundleId, names: [url.deletingPathExtension().lastPathComponent])
        }
        return sortedByName(apps)
    }

    func appName(forBundleId bundleId: String) -> String? {
        InstalledApps.name(forBundleId: bundleId)
    }

    func isRunning(bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    func isInstalled(bundleId: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }

    func openApp(bundleId: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return true
        } catch {
            Log.context.error("voice command: could not open \(bundleId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func openURL(_ url: String, browser: String?) async -> Bool {
        guard let target = URL(string: url), let scheme = target.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            if let browser {
                guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser) else {
                    Log.context.error("voice command: browser \(browser, privacy: .public) is not installed")
                    return false
                }
                _ = try await NSWorkspace.shared.open([target], withApplicationAt: app, configuration: configuration)
            } else {
                _ = try await NSWorkspace.shared.open(target, configuration: configuration)
            }
            return true
        } catch {
            Log.context.error("voice command: could not open a URL: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    nonisolated static let shortcutsTool = "/usr/bin/shortcuts"

    func runScript(
        _ script: VoiceCommandScript, arguments: [String], onLateFinish: @escaping @MainActor (ScriptRun) -> Void
    ) async -> ScriptRun {
        let late: @Sendable (ScriptRun) -> Void = { run in Task { @MainActor in onLateFinish(run) } }
        guard let shortcut = script.shortcut else {
            return await ScriptLauncher.run(program: script.program, arguments: arguments, onLateFinish: late)
        }
        let input = arguments.first
        return await ScriptLauncher.run(
            program: Self.shortcutsTool, arguments: Self.shortcutArguments(shortcut, input: input), input: input,
            onLateFinish: late)
    }

    nonisolated static func shortcutArguments(_ shortcut: VoiceCommandShortcut, input: String?) -> [String] {
        ["run", shortcut.target] + (input == nil ? [] : ["--input-path", "-"])
    }

    nonisolated static let shortcutListDeadline: TimeInterval = 10

    func shortcuts() async -> [VoiceCommandShortcut]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let output = Self.readOutput(
                    program: Self.shortcutsTool, arguments: ["list", "--show-identifiers"], within: Self.shortcutListDeadline)
                continuation.resume(returning: output.map {
                    VoiceCommandShortcut.parseList($0)
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                })
            }
        }
    }

    nonisolated static func readOutput(program: String, arguments: [String], within seconds: TimeInterval) -> String? {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-output-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL) else { return nil }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        guard exited.wait(timeout: .now() + seconds) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: outputURL) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func browserTabs(in browser: String?) async -> TabRead? {
        let scan = await installedSnapshot()
        let browsers = Self.runningTabBrowsers(in: scan, running: Self.runningIds()).filter { browser == nil || $0 == browser }
        guard !browsers.isEmpty else { return TabRead(tabs: []) }
        let consent = await AutomationConsent.settle(browsers)
        guard !Task.isCancelled else { return nil }
        var read = TabRead(tabs: [])
        if !consent.readable.isEmpty {
            guard case .finished(let found) = await Self.scripts.run(within: Self.tabReadDeadline, { isCurrent in
                Self.collectTabs(from: consent.readable, isCurrent: isCurrent) { BrowserScripting.tabs(of: $0, isCurrent: isCurrent) }
            }) else {
                Log.context.error("voice command: the browser tabs could not be read in time")
                return nil
            }
            read = found
        }
        read.refused += consent.refused
        read.unavailable += consent.unanswered
        for bundleId in read.refused {
            Log.context.error("voice command: \(bundleId, privacy: .public) refused Automation")
        }
        for bundleId in read.unavailable {
            Log.context.error("voice command: \(bundleId, privacy: .public) tabs could not be read")
        }
        return read
    }

    nonisolated static func collectTabs(
        from browsers: [String], isCurrent: () -> Bool, read: (String) -> BrowserTabsReply
    ) -> TabRead {
        var result = TabRead(tabs: [])
        for bundleId in browsers {
            guard isCurrent() else { break }
            switch read(bundleId) {
            case .tabs(let tabs): result.tabs += tabs
            case .refused: result.refused.append(bundleId)
            case .unavailable: result.unavailable.append(bundleId)
            }
        }
        return result
    }

    func focusTab(_ tab: VoiceCommandCatalog.Tab) async -> TabFocusResult {
        switch await Self.scripts.run(within: Self.focusDeadline, { BrowserScripting.focus(tab, isCurrent: $0) }) {
        case .expired:
            Log.context.error("voice command: \(tab.browserBundleId, privacy: .public) did not answer the tab focus in time")
            return .noResponse
        case .finished(false):
            return .gone
        case .finished(true):
            return .focused
        }
    }

    func windows() async -> VoiceCommandCatalog.WindowScan {
        let processes = AppWindows.processes(excluding: ProcessInfo.processInfo.processIdentifier, named: runningApps())
        let trusted = AXIsProcessTrusted()
        let started = DispatchTime.now()
        guard case .finished(let scan) = await Self.accessibility.run(within: Self.windowReadDeadline, { isCurrent in
            AppWindows.collect(processes, trusted: trusted, isCurrent: isCurrent) { AppWindows.read(pid: $0.pid, isCurrent: isCurrent) }
        }) else {
            Log.context.error("voice command: open windows could not be read in time (\(processes.count, privacy: .public) apps)")
            return .incomplete
        }
        let ms = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        switch scan {
        case .complete(let windows):
            Log.context.debug("voice command: read \(windows.count, privacy: .public) windows from \(processes.count, privacy: .public) apps in \(ms, privacy: .public)ms")
        case .incomplete:
            Log.context.error("voice command: an app did not list its windows (\(processes.count, privacy: .public) apps, \(ms, privacy: .public)ms)")
        case .needsAccessibility:
            Log.context.error("voice command: open windows need Accessibility")
        }
        return scan
    }

    func focusWindow(_ window: VoiceCommandCatalog.Window, stillWanted: @MainActor () -> Bool) async -> WindowFocusResult {
        guard let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated,
              app.bundleIdentifier == window.bundleId else { return .gone }
        let deadline = Date().addingTimeInterval(Self.focusDeadline)
        func withinDeadline<T: Sendable>(_ work: @escaping @Sendable (_ isCurrent: () -> Bool) -> T) async -> DeadlineResult<T> {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return .expired }
            return await Self.accessibility.run(within: left, work)
        }
        guard case .finished(let location) = await withinDeadline({ AppWindows.locate(window, isCurrent: $0) }) else {
            Log.context.error("voice command: \(window.bundleId, privacy: .public) did not answer the window focus in time")
            return .noResponse
        }
        guard stillWanted() else { return .cancelled }
        switch location {
        case .absent: return .gone
        case .elsewhere: return .elsewhere
        case .noResponse:
            Log.context.error("voice command: \(window.bundleId, privacy: .public) did not list its windows for focus")
            return .noResponse
        case .found(let handle, let minimized, let focused):
            if focused, !minimized, !app.isHidden, NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid {
                return .alreadyFrontmost
            }
            guard let number = CGWindowID(window.id.dropFirst(3)) else { return .failed }
            let steps = AppWindows.liveSteps(
                handle, number: number, app: app, withinDeadline: { deadline.timeIntervalSinceNow > 0 }
            ) { work in
                guard case .finished(let step) = await withinDeadline(work) else { return .noResponse }
                return step
            }
            let result = await AppWindows.bringForward(
                isHidden: app.isHidden, isMinimized: minimized, steps: steps, stillWanted: stillWanted)
            if result == .noResponse || result == .failed {
                Log.context.error("voice command: \(window.bundleId, privacy: .public) window could not be confirmed in front")
            }
            return result
        }
    }

    func isRunning(pid: Int32, bundleId: String) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated && app.bundleIdentifier == bundleId
    }

    func activate(pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        if app.isHidden { app.unhide() }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, AppWindows.messagingTimeout)
        if AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success { return true }
        return app.activate()
    }

    func frontTab(ofBrowser bundleId: String) async -> (url: String, title: String)? {
        let scan = await installedSnapshot()
        guard isRunning(bundleId: bundleId), scan.tabBrowsers.contains(bundleId),
              await AutomationConsent.settle([bundleId]).readable == [bundleId],
              case .finished(let tab) = await Self.scripts.run(within: Self.tabReadDeadline, {
                  BrowserScripting.frontTab(of: bundleId, isCurrent: $0).map { FrontTab(url: $0.url, title: $0.title) }
              }), let tab else { return nil }
        return (tab.url, tab.title)
    }

    private struct FrontTab: Sendable {
        let url: String
        let title: String
    }

    private static func runningIds() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    nonisolated static func runningTabBrowsers(in scan: InstalledScan, running: Set<String>) -> [String] {
        scan.tabBrowsers.filter { running.contains($0) }.sorted()
    }

    nonisolated static func hasScriptableTabs(_ app: URL) -> Bool {
        guard let name = infoPlist(of: app)?["OSAScriptingDefinition"] as? String,
              let parser = XMLParser(contentsOf: app.appendingPathComponent("Contents/Resources").appendingPathComponent(name))
        else { return false }
        let finder = TabClassFinder()
        parser.delegate = finder
        parser.parse()
        return finder.found
    }

}

private final class TabClassFinder: NSObject, XMLParserDelegate {
    private(set) var found = false

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        guard elementName == "class", attributes["name"] == "tab" else { return }
        found = true
        parser.abortParsing()
    }
}

enum BrowserScripting {
    static let replyTimeout = 3

    enum Shape: CaseIterable {
        case chromium, safari

        var titleProperty: String {
            switch self {
            case .chromium: "title"
            case .safari: "name"
            }
        }
    }

    static func tabs(of bundleId: String, isCurrent: () -> Bool) -> BrowserTabsReply {
        for shape in Shape.allCases {
            guard isCurrent() else { return .unavailable }
            switch run(tabsSource(of: bundleId, shape: shape)) {
            case .refused:
                return .refused
            case .failed(let code) where code == timedOut:
                return .unavailable
            case .failed:
                continue
            case .value(let result):
                guard result.numberOfItems == 2, let urls = result.atIndex(1), let titles = result.atIndex(2) else { continue }
                return .tabs(parse(urls: urls, titles: titles, bundleId: bundleId))
            }
        }
        return .unavailable
    }

    static func tabsSource(of bundleId: String, shape: Shape) -> String {
        bounded("""
        tell application id \(literal(bundleId)) to return {URL of every tab of every window, \
        \(shape.titleProperty) of every tab of every window}
        """)
    }

    static func frontTabSource(of bundleId: String, shape: Shape) -> String {
        let tabRef = shape == .chromium ? "active tab of front window" : "current tab of front window"
        return bounded("""
        tell application id \(literal(bundleId)) to return {URL of \(tabRef), \(shape.titleProperty) of \(tabRef)}
        """)
    }

    private static func bounded(_ statements: String) -> String {
        "with timeout of \(replyTimeout) seconds\n\(statements)\nend timeout"
    }

    static func focus(_ tab: VoiceCommandCatalog.Tab, isCurrent: () -> Bool) -> Bool {
        let bodies = [
            "set active tab index of window w to t",
            "set current tab of window w to tab t of window w",
        ]
        return firstAnswer(bodies.map { focusSource(tab, selecting: $0) }, isCurrent: isCurrent) { source in
            guard case .value(let result) = run(source) else { return nil }
            return result.booleanValue
        } ?? false
    }

    static func firstAnswer<T>(_ sources: [String], isCurrent: () -> Bool, run: (String) -> T?) -> T? {
        for source in sources {
            guard isCurrent() else { return nil }
            if let answer = run(source) { return answer }
        }
        return nil
    }

    static func focusSource(_ tab: VoiceCommandCatalog.Tab, selecting body: String) -> String {
        sameURLHandler + bounded("""
        tell application id \(literal(tab.browserBundleId))
            set wanted to \(literal(tab.url))
            set found to missing value
            if (count of windows) \u{2265} \(tab.window) then
                if (count of tabs of window \(tab.window)) \u{2265} \(tab.tab) then
                    if my sameURL(URL of tab \(tab.tab) of window \(tab.window), wanted) then set found to {\(tab.window), \(tab.tab)}
                end if
            end if
            if found is missing value then
                repeat with w from 1 to count of windows
                    repeat with t from 1 to count of tabs of window w
                        if my sameURL(URL of tab t of window w, wanted) then
                            set found to {w, t}
                            exit repeat
                        end if
                    end repeat
                    if found is not missing value then exit repeat
                end repeat
            end if
            if found is missing value then return false
            set w to item 1 of found
            set t to item 2 of found
            \(body)
            set index of window w to 1
            return true
        end tell
        """)
    }

    static let sameURLHandler = """
        on sameURL(candidate, wanted)
            considering case
                return candidate is wanted
            end considering
        end sameURL

        """

    static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func frontTab(of bundleId: String, isCurrent: () -> Bool) -> (url: String, title: String)? {
        firstAnswer(Shape.allCases.map { frontTabSource(of: bundleId, shape: $0) }, isCurrent: isCurrent) { source in
            guard case .value(let result) = run(source), result.numberOfItems == 2,
                  let url = result.atIndex(1)?.stringValue, !url.isEmpty else { return nil }
            return (url, result.atIndex(2)?.stringValue ?? "")
        }
    }

    private static func parse(urls: NSAppleEventDescriptor, titles: NSAppleEventDescriptor, bundleId: String) -> [VoiceCommandCatalog.Tab] {
        var tabs: [VoiceCommandCatalog.Tab] = []
        guard urls.numberOfItems > 0 else { return tabs }
        for w in 1...urls.numberOfItems {
            guard let windowURLs = urls.atIndex(w), windowURLs.numberOfItems > 0 else { continue }
            let windowTitles = titles.atIndex(w)
            for t in 1...windowURLs.numberOfItems {
                guard let url = windowURLs.atIndex(t)?.stringValue, !url.isEmpty else { continue }
                let title = windowTitles?.atIndex(t)?.stringValue ?? ""
                tabs.append(VoiceCommandCatalog.Tab(browserBundleId: bundleId, window: w, tab: t, url: url, title: title))
            }
        }
        return tabs
    }

    private enum Reply {
        case value(NSAppleEventDescriptor)
        case refused
        case failed(Int)
    }

    private static let notPermitted = -1743
    private static let timedOut = -1712

    private static func run(_ source: String) -> Reply {
        guard let script = NSAppleScript(source: source) else { return .failed(0) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard let error else { return .value(result) }
        let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        return code == notPermitted ? .refused : .failed(code)
    }
}
