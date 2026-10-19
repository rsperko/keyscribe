import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

private final class Handlers: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL]
    private var calls = 0
    private var offMain = true
    private let started = DispatchSemaphore(value: 0)
    private let gate: DispatchSemaphore?

    init(_ urls: [URL] = [], gated: Bool = false) {
        self.urls = urls
        gate = gated ? DispatchSemaphore(value: 0) : nil
    }

    var source: @Sendable () -> [URL] {
        { [self] in
            lock.withLock {
                calls += 1
                if Thread.isMainThread { offMain = false }
            }
            started.signal()
            gate?.wait()
            return lock.withLock { urls }
        }
    }

    var callCount: Int { lock.withLock { calls } }
    var ranOffMain: Bool { lock.withLock { offMain } }
    func set(_ new: [URL]) { lock.withLock { urls = new } }
    func release() { gate?.signal() }
    func waitUntilStarted() async { await Task.detached { [self] in blockUntilStarted() }.value }
    private func blockUntilStarted() { started.wait() }
}

private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-browsers-\(UUID().uuidString)")
    static let tabSdef = #"<dictionary><suite name="S"><class name="tab" code="Ctab"/></suite></dictionary>"#
    static let plainSdef = #"<dictionary><suite name="S"><command name="open"/></suite></dictionary>"#

    @discardableResult
    func app(_ path: String, id: String, name: String? = nil, sdef: String? = nil, sdefFile: String = "Browser.sdef") throws -> URL {
        let app = root.appendingPathComponent(path)
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        var plist: [String: String] = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"]
        if let name { plist["CFBundleName"] = name }
        if let sdef {
            plist["OSAScriptingDefinition"] = sdefFile
            try sdef.write(to: resources.appendingPathComponent(sdefFile), atomically: true, encoding: .utf8)
        }
        try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
struct BrowserDiscoveryTests {
    private final class Clock {
        var instant = ContinuousClock.now
        func advance(_ seconds: Int) { instant = instant.advanced(by: .seconds(seconds)) }
    }

    private func make(_ handlers: Handlers, roots: [URL] = [], clock: Clock = Clock()) -> LiveVoiceCommandSystem {
        LiveVoiceCommandSystem(roots: roots, handlers: handlers.source, now: { clock.instant })
    }

    @Test func theScanReportsEveryHttpsHandlerAndWhichCanListTabs() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let apps = fixture.root.appendingPathComponent("Apps")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let tabs = try fixture.app("Apps/Tabby.app", id: "test.tabby", name: "Tabby", sdef: Fixture.tabSdef)
        let plain = try fixture.app("Apps/Plain.app", id: "test.plain", name: "Plain Browser")
        let elsewhere = try fixture.app("Elsewhere/Far.app", id: "test.far", name: "Far Browser", sdef: Fixture.tabSdef)
        let firstCopy = try fixture.app("Copies/A/Twin.app", id: "test.twin", name: "Twin", sdef: Fixture.plainSdef)
        let secondCopy = try fixture.app("Copies/B/Twin.app", id: "test.twin", name: "Twin Other", sdef: Fixture.tabSdef)
        let handlers = Handlers([tabs, plain, elsewhere, secondCopy, firstCopy])
        let system = make(handlers, roots: [apps])

        let scan = await system.installedSnapshot()

        #expect(scan.browsers.map(\.name) == ["Far", "Plain", "Tabby", "Twin"])
        #expect(scan.tabBrowsers == ["test.tabby", "test.far"])
        #expect(Set(scan.apps.map(\.bundleId)) == ["test.tabby", "test.plain"])
    }

    @Test func aRunningCopyIsPreferredForNameAndCapability() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let installed = try fixture.app("A/Installed.app", id: "test.twin", sdef: Fixture.plainSdef)
        let running = try fixture.app("B/Running.app", id: "test.twin", sdef: Fixture.tabSdef)
        let found = LiveVoiceCommandSystem.scanBrowsers([installed], excluding: nil, running: ["test.twin": running])
        #expect(found.browsers.map(\.name) == ["Running"])
        #expect(found.tabBrowsers == ["test.twin"])
    }

    @Test func discoveryFollowsTheMacOnceTheSnapshotExpires() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let kept = try fixture.app("Kept.app", id: "test.kept", name: "Kept", sdef: Fixture.tabSdef)
        let removed = try fixture.app("Removed.app", id: "test.removed", name: "Removed", sdef: Fixture.tabSdef)
        let updated = try fixture.app("Updated.app", id: "test.updated", name: "Updated")
        let handlers = Handlers([kept, removed, updated])
        let clock = Clock()
        let system = make(handlers, clock: clock)
        let running: Set<String> = ["test.kept", "test.removed", "test.updated", "test.added"]

        var scan = await system.installedSnapshot()
        #expect(scan.browsers.map(\.bundleId) == ["test.kept", "test.removed", "test.updated"])
        #expect(LiveVoiceCommandSystem.runningTabBrowsers(in: scan, running: running) == ["test.kept", "test.removed"])

        let added = try fixture.app("Added.app", id: "test.added", name: "Added")
        try fixture.app("Updated.app", id: "test.updated", name: "Updated", sdef: Fixture.tabSdef)
        handlers.set([kept, updated, added])
        clock.advance(59)
        #expect(await system.installedSnapshot().generation == scan.generation)
        #expect(handlers.callCount == 1)

        clock.advance(2)
        scan = await system.installedSnapshot()
        #expect(handlers.callCount == 2)
        #expect(scan.browsers.map(\.bundleId) == ["test.added", "test.kept", "test.updated"])
        #expect(LiveVoiceCommandSystem.runningTabBrowsers(in: scan, running: running) == ["test.kept", "test.updated"])
    }

    @Test func eachInPlaceDictionaryChangeIsRereadAtTheSameBundle() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let url = try fixture.app("Browser.app", id: "test.browser", sdef: Fixture.tabSdef)
        let handlers = Handlers([url])
        let clock = Clock()
        let system = make(handlers, clock: clock)
        #expect(await system.installedSnapshot().tabBrowsers == ["test.browser"])

        let steps: [(sdef: String?, file: String, tabs: Bool)] = [
            (nil, "Browser.sdef", false),
            (Fixture.tabSdef, "Renamed.sdef", true),
            (Fixture.plainSdef, "Renamed.sdef", false),
        ]
        for step in steps {
            try fixture.app("Browser.app", id: "test.browser", sdef: step.sdef, sdefFile: step.file)
            clock.advance(61)
            #expect(await system.installedSnapshot().tabBrowsers.contains("test.browser") == step.tabs)
        }
        #expect(handlers.callCount == steps.count + 1)
    }

    @Test func concurrentCallersShareOneScanEvenWhenOneIsCancelled() async {
        let handlers = Handlers(gated: true)
        let clock = Clock()
        let system = make(handlers, clock: clock)
        let apps = Task { await system.installedApps() }
        let snapshot = Task { await system.installedSnapshot() }
        let cancelled = Task { await system.installedSnapshot() }
        await handlers.waitUntilStarted()
        cancelled.cancel()
        handlers.release()

        _ = await apps.value
        let first = await snapshot.value
        #expect(await cancelled.value.generation == first.generation)
        #expect(handlers.callCount == 1)

        clock.advance(61)
        let later = Task { await system.installedSnapshot() }
        await handlers.waitUntilStarted()
        handlers.release()
        let second = await later.value
        #expect(second.generation > first.generation)
        #expect(await system.installedSnapshot().generation == second.generation)
        #expect(handlers.callCount == 2)
    }

    @Test func discoveryRunsOffTheMainThread() async {
        let handlers = Handlers()
        _ = await make(handlers).installedSnapshot()
        #expect(handlers.callCount == 1)
        #expect(handlers.ranOffMain)
    }

    @Test func tabReadsDiscoverOnAColdSystemWithoutAskingABrowserThatIsNotRunning() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let url = try fixture.app("Browser.app", id: "test.cold", sdef: Fixture.tabSdef)
        let handlers = Handlers([url])
        let system = make(handlers)
        #expect(await system.frontTab(ofBrowser: "test.cold") == nil)
        #expect(handlers.callCount == 1)
        #expect(await system.browserTabs(in: "test.cold") == TabRead(tabs: []))
        #expect(handlers.callCount == 1)
    }

    @Test func settingsLoadsBrowsersWithoutConfusingLoadingWithNone() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let tabs = try fixture.app("Elsewhere/Tabby.app", id: "test.tabby", name: "Tabby", sdef: Fixture.tabSdef)
        let plain = try fixture.app("Elsewhere/Plain.app", id: "test.plain", name: "Plain")
        let dir = fixture.root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repository = ConfigRepository(supportDir: dir, config: ConfigCache(supportDir: dir))
        let model = VoiceCommandsSettingsModel(repository: repository, system: make(Handlers([tabs, plain])))

        #expect(model.isCheckingBrowsers)
        #expect(model.browsers.isEmpty)
        #expect(!model.canCaptureTab(of: "test.tabby"))

        await model.loadBrowserChoices()
        #expect(!model.isCheckingBrowsers)
        #expect(model.browsers.map(\.name) == ["Plain", "Tabby"])
        #expect(model.canCaptureTab(of: "test.tabby"))
        #expect(!model.canCaptureTab(of: "test.plain"))
        #expect(await model.currentTab(of: VoiceCommandCatalog.App(name: "Plain", bundleId: "test.plain")) == nil)
    }
}
