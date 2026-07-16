import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false
    func wait() async {
        await withCheckedContinuation { c in
            lock.lock()
            if fired { lock.unlock(); c.resume(); return }
            continuation = c
            lock.unlock()
        }
    }
    func fire() {
        lock.lock(); fired = true; let c = continuation; continuation = nil; lock.unlock()
        c?.resume()
    }
}

@MainActor
struct FirstRunFlowTests {
    private func tempSupportDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-first-run-flow-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeModel(
        supportDir: URL,
        download: @escaping (String, @escaping @Sendable (ModelLoadProgress) -> Void) async throws -> Void = { _, _ in },
        onComplete: @escaping () -> Void = {}
    ) -> FirstRunModel {
        FirstRunModel(
            initialEngineId: SpeechModelCatalog.defaultEnglishId,
            download: download,
            selectEngine: { _ in },
            repository: ConfigRepository(supportDir: supportDir, config: ConfigCache(supportDir: supportDir)),
            onComplete: onComplete)
    }

    private func writeDirect(_ triggerKeys: [Mode.TriggerKey], to modesDir: URL) throws {
        var direct = Mode(id: Mode.directId, name: "Plain Dictation")
        direct.triggerKeys = triggerKeys
        try ModeStore.write(direct, to: modesDir)
    }

    // MARK: 1a — reorder

    @Test func continueFromPermissionsWithLiveTapAdvancesToTrial() {
        let supportDir = tempSupportDir()
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let model = makeModel(supportDir: supportDir)
        model.tapActive = { true }

        model.continueFromPermissions()

        #expect(model.step == .tryIt)
        #expect(model.needsRelaunch == false)
    }

    @Test func continueFromPermissionsWithDeadTapRequestsRelaunch() {
        let supportDir = tempSupportDir()
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let model = makeModel(supportDir: supportDir)
        model.tapActive = { false }

        model.continueFromPermissions()

        #expect(model.needsRelaunch == true)
        #expect(model.step == .intro)
    }

    @Test func trialContinueRoutesToTheAIOffer() {
        let supportDir = tempSupportDir()
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let model = makeModel(supportDir: supportDir)
        model.step = .tryIt

        model.continueFromTrial()

        #expect(model.step == .aiService)
    }

    @Test func finishWithoutAICompletesAndCancelsInFlightSetup() async {
        let supportDir = tempSupportDir()
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let started = Gate(), release = Gate()
        var completed = 0
        let model = makeModel(
            supportDir: supportDir,
            download: { _, _ in started.fire(); await release.wait() },
            onComplete: { completed += 1 })

        model.beginDownload()
        let task = model.downloadTask
        await started.wait()
        model.finishWithoutAI()

        #expect(completed == 1)
        #expect(model.downloadTask == nil)
        release.fire()
        await task?.value
        #expect(model.downloading == false)
    }

    // An interrupted download must wipe its partial weights — otherwise it wedges retry and can't be
    // deleted (it was never marked installed).
    @Test func failedDownloadCleansUpPartialWeights() async {
        let supportDir = tempSupportDir()
        defer { try? FileManager.default.removeItem(at: supportDir) }
        struct Boom: Error {}
        final class Box { var ids: [String] = [] }
        let box = Box()
        let model = FirstRunModel(
            initialEngineId: "whisper",
            download: { _, _ in throw Boom() },
            selectEngine: { _ in },
            cleanupFailedDownload: { box.ids.append($0) },
            repository: ConfigRepository(supportDir: supportDir, config: ConfigCache(supportDir: supportDir)),
            onComplete: {})

        model.beginDownload()
        await model.downloadTask?.value

        #expect(box.ids == ["whisper"])
        #expect(model.downloadError != nil)
        #expect(model.downloading == false)
    }

    @Test func failedDownloadSurfacesPartialWeightCleanupFailure() async {
        let supportDir = tempSupportDir()
        defer { try? FileManager.default.removeItem(at: supportDir) }
        struct Boom: Error {}
        let model = FirstRunModel(
            initialEngineId: "whisper",
            download: { _, _ in throw Boom() },
            selectEngine: { _ in },
            cleanupFailedDownload: { _ in throw Boom() },
            repository: ConfigRepository(supportDir: supportDir, config: ConfigCache(supportDir: supportDir)),
            onComplete: {})

        model.beginDownload()
        await model.downloadTask?.value

        #expect(model.downloadError == "Download failed, and partial model files couldn’t be removed. Try again.")
        #expect(model.downloading == false)
    }

    @Test func installMarkerFailureKeepsCompletedDownloadOnDisk() async {
        let supportDir = tempSupportDir()
        defer { try? FileManager.default.removeItem(at: supportDir) }
        final class Box { var cleaned = false }
        let box = Box()
        let model = FirstRunModel(
            initialEngineId: "whisper",
            download: { _, _ in throw FirstRunDownloadError.installStateNotSaved },
            selectEngine: { _ in },
            cleanupFailedDownload: { _ in box.cleaned = true },
            repository: ConfigRepository(supportDir: supportDir, config: ConfigCache(supportDir: supportDir)),
            onComplete: {})

        model.beginDownload()
        await model.downloadTask?.value

        #expect(box.cleaned == false)
        #expect(model.downloadError == "The model downloaded, but its install state couldn’t be saved. Check available disk space and try again.")
        #expect(model.downloading == false)
    }

    // MARK: 2b — step-dot mapping

    @Test func stepIndexMapsEveryStepAndPlaygroundSharesTheLastDot() {
        let supportDir = tempSupportDir()
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let model = makeModel(supportDir: supportDir)
        #expect(FirstRunModel.stepCount == 5)
        model.step = .intro; #expect(model.stepIndex == 0)
        model.step = .model; #expect(model.stepIndex == 1)
        model.step = .permissions; #expect(model.stepIndex == 2)
        model.stopPolling()
        model.step = .tryIt; #expect(model.stepIndex == 3)
        model.step = .aiService; #expect(model.stepIndex == 4)
        model.step = .playground; #expect(model.stepIndex == 4)
    }

    // MARK: 1c — resolved trigger

    @Test func resolvedTriggerReflectsTheDirectMode() throws {
        let supportDir = tempSupportDir()
        defer { try? FileManager.default.removeItem(at: supportDir) }
        try writeDirect([.init(key: "right_option")], to: supportDir.appendingPathComponent("modes"))
        let model = makeModel(supportDir: supportDir)

        #expect(model.directTrigger == .named(.rightOption))
        #expect(model.directTriggerDisplay == "Right-⌥")
    }

    @Test func missingDirectModeFallsBackToTheFnLabel() {
        let supportDir = tempSupportDir()
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let model = makeModel(supportDir: supportDir)

        #expect(model.directTrigger == nil)
        #expect(model.directTriggerDisplay == "Fn (Globe)")
    }

    // MARK: 1f — trigger rebind

    @Test func rebindPreservesPressStyleAndUpdatesCacheImmediately() throws {
        let supportDir = tempSupportDir()
        let modesDir = supportDir.appendingPathComponent("modes")
        defer { try? FileManager.default.removeItem(at: supportDir) }
        try writeDirect([.init(key: "fn", pressStyle: "tap-to-toggle", tapThresholdMs: 300)], to: modesDir)
        let model = makeModel(supportDir: supportDir)

        model.setDirectTrigger("right_command")

        #expect(model.directTrigger == .named(.rightCommand))
        #expect(model.triggerSaveError == nil)
        let reloaded = ModeStore.loadAll(in: modesDir).first { $0.id == Mode.directId }
        #expect(reloaded?.triggerKeys.first?.key == "right_command")
        #expect(reloaded?.triggerKeys.first?.pressStyle == "tap-to-toggle")
        #expect(reloaded?.triggerKeys.first?.tapThresholdMs == 300)
    }

    @Test func clearingTheTriggerReportsTheNoTriggerState() throws {
        let supportDir = tempSupportDir()
        let modesDir = supportDir.appendingPathComponent("modes")
        defer { try? FileManager.default.removeItem(at: supportDir) }
        try writeDirect([.init(key: "fn")], to: modesDir)
        let model = makeModel(supportDir: supportDir)

        model.setDirectTrigger("")

        #expect(model.directTrigger == nil)
        let reloaded = ModeStore.loadAll(in: modesDir).first { $0.id == Mode.directId }
        #expect(reloaded?.triggerKeys.isEmpty == true)
    }

    @Test func emptyTriggerKeysOnDiskReportNoTriggerOnEntryToTrial() throws {
        let supportDir = tempSupportDir()
        defer { try? FileManager.default.removeItem(at: supportDir) }
        try writeDirect([], to: supportDir.appendingPathComponent("modes"))
        let model = makeModel(supportDir: supportDir)

        model.step = .tryIt

        #expect(model.directTrigger == nil)
    }

    @Test func aFailedTriggerWriteSurfacesTheErrorAndKeepsTheTrigger() throws {
        let supportDir = tempSupportDir()
        let modesDir = supportDir.appendingPathComponent("modes")
        try writeDirect([.init(key: "fn")], to: modesDir)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: modesDir.path)
            try? FileManager.default.removeItem(at: supportDir)
        }
        let model = makeModel(supportDir: supportDir)
        #expect(model.directTrigger == .named(.fn))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: modesDir.path)

        model.setDirectTrigger("right_command")

        #expect(model.triggerSaveError == "Could not save the shortcut.")
        #expect(model.directTrigger == .named(.fn))
    }
}
