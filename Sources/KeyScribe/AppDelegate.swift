import AppKit
import ServiceManagement
import KeyScribeKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings = Settings.defaults
    private var configError: String?
    private var provider: SpeechEngineProvider!
    private var config: ConfigCache!
    private var configWatcher: ConfigWatcher?
    // Lets the watcher tell the app's own config writes (skip) from external edits (reload).
    private let selfWriteGate = ConfigSelfWriteGate()
    private var speechModels: SpeechModelsModel!
    private let hud = HUDController()
    private let menu = MenuBarController()
    private var hotkey: HotkeyMonitor!
    private var controller: DictationController!
    private var firstRun: FirstRunController?
    private var settingsController: SettingsController!
    private var notices = NoticesController()
    private var history: HistoryStore!
    private var historyController: HistoryController!
    private var correctionPanel: CorrectionPanelController!
    private var configRepository: ConfigRepository!
    // Legacy crash recovery for audio state markers written by earlier builds.
    private var audioRestorer: SystemAudioStateRestorer!
    // System sleep suspends CoreAudio, so the resident capture engine's cached device binding is stale on
    // wake. Refresh it while idle (off the hot path) so the first post-wake dictation binds cleanly.
    private var wakeObserver: NSObjectProtocol?

    // Optional extension seams, nil by default — a build injects these (e.g. from main.swift) before
    // launch. With neither set, lifecycle and bootstrap behave exactly as without them.
    var updater: AppUpdater?
    var legacyImporter: LegacyConfigImporter?

    private let firstRunKey = ResetTool.firstRunKey
    private let forcePermissionsSetup = CommandLine.arguments.contains("--setup-permissions")
    private let forceResumeOnboarding = CommandLine.arguments.contains("--resume-onboarding")
    private let forceFirstRun = CommandLine.arguments.contains("--first-run")

    func applicationWillTerminate(_: Notification) {
        controller?.cancel()
    }

    func applicationDidFinishLaunching(_: Notification) {
        audioRestorer = SystemAudioStateRestorer(markerURL: KeyScribePaths.pendingSystemRestoreFile)
        audioRestorer.reconcile()
        runLegacyImportIfNeeded()
        loadSettings()
        let engines = EngineRegistry.makeAll(modelsDir: KeyScribePaths.modelsDir)
        ModelInstallStore.reconcile(engines: engines)
        provider = resolveProvider(engines: engines)
        ModeStore.seedStartersIfEmpty(in: KeyScribePaths.modesDir, ledgerDir: KeyScribePaths.lkgDir)
        ModeStore.ensureSystemModes(in: KeyScribePaths.modesDir, lkgDir: KeyScribePaths.lkgDir.appendingPathComponent("modes", isDirectory: true))
        let reconciled = ModeStore.reconcileSeeds(
            modesDir: KeyScribePaths.modesDir, ledgerDir: KeyScribePaths.lkgDir,
            settingsDir: KeyScribePaths.supportDir)
        if !reconciled.isEmpty {
            Log.models.info("seed reconcile: renamed=\(reconciled.renamed, privacy: .public) added=\(reconciled.added, privacy: .public) updated=\(reconciled.updated, privacy: .public)")
            loadSettings()
        }
        config = ConfigCache(supportDir: KeyScribePaths.supportDir)
        configRepository = ConfigRepository(
            supportDir: KeyScribePaths.supportDir, config: config, selfWriteGate: selfWriteGate)
        configRepository.onChange = { [weak self] in
            // A mode write can change enable state or trigger key, so re-register bindings. The FSEvents
            // watcher skips in-app writes (self-write echoes), so without this a mode's trigger never
            // rebinds until relaunch.
            self?.rebuildHotkeyMonitor()
            self?.refreshStatus()
        }
        selfWriteGate.adopt(ConfigTreeSnapshot.capture(supportDir: KeyScribePaths.supportDir))
        configWatcher = ConfigWatcher(path: KeyScribePaths.supportDir.path) { [weak self, gate = selfWriteGate, dir = KeyScribePaths.supportDir] in
            // Off-main (FSEvents utility queue): skip the hop entirely on a pure self-write echo.
            guard gate.shouldReload(current: ConfigTreeSnapshot.capture(supportDir: dir)) else { return }
            Task { @MainActor in self?.reloadConfig() }
        }
        history = HistoryStore(supportDir: KeyScribePaths.supportDir)
        history.applyRetention(retentionDays: settings.history.retentionDays)
        controller = DictationController(
            settings: settings, provider: provider, config: config, history: history, hud: hud,
            pressSnapshot: ContextProbe.initialSnapshot,
            snapshot: { [hud] in ContextProbe.snapshot(excludingWindow: hud.hudWindowID) },
            snapshotAsync: { [hud] in await ContextProbe.snapshotAsync(excludingWindow: hud.hudWindowID) })
        controller.preloadActiveEngineIfNeeded()
        hud.onInsertLocalTranscript = { [weak self] in self?.controller.insertLocalTranscriptNow() }
        hud.onPasteLast = { [weak self] in self?.controller.pasteLast() }
        hud.canCancel = { [weak self] in self?.controller.isCancellable ?? false }
        hud.onEscapeCancel = { [weak self] in
            self?.hotkey.cancelGestures()
            self?.controller.cancel()
            self?.refreshStatus()
        }

        historyController = HistoryController(
            store: history,
            addDictionaryWord: { [weak self] word in self?.configRepository.addDictionaryWord(word) ?? false },
            addReplacement: { [weak self] heard, replace in self?.configRepository.addReplacement(heard: heard, replace: replace) ?? false },
            openSettings: { [weak self] destination in self?.settingsController.present(destination) })
        correctionPanel = CorrectionPanelController(
            destinations: { [weak self] in self?.correctionDestinations() ?? [.global] },
            addDictionaryWord: { [weak self] word, destination in
                switch destination.scope {
                case .global:
                    return self?.configRepository.addDictionaryWord(word) ?? false
                case .mode(let id):
                    return self?.configRepository.addDictionaryWord(word, toMode: id) ?? false
                }
            },
            addReplacement: { [weak self] heard, replace, regex, destination in
                switch destination.scope {
                case .global:
                    return self?.configRepository.addReplacement(heard: heard, replace: replace, regex: regex) ?? false
                case .mode(let id):
                    return self?.configRepository.addReplacement(heard: heard, replace: replace, regex: regex, toMode: id) ?? false
                }
            })

        menu.showsUpdateCheck = updater != nil
        menu.install()
        menu.onPasteLast = { [weak self] in self?.controller.pasteLast() }
        menu.onOpenHistory = { [weak self] in self?.historyController.present() }
        menu.onOpenSettings = { [weak self] in self?.settingsController.present() }
        menu.onOpenSpeechModels = { [weak self] in self?.settingsController.present(.speechModels) }
        menu.onOpenModes = { [weak self] in self?.settingsController.present(.modes) }
        menu.onOpenNotices = { [weak self] in self?.notices.present() }
        menu.onMenuWillOpen = { [weak self] in
            self?.rebuildMenuItems()
            self?.refreshStatus()
        }
        menu.onSelectNextMode = { [weak self] id in
            self?.controller.setNextModeOverride(id: id)
            self?.controller.acknowledgeNextMode()
            self?.refreshStatus()
        }
        menu.onSelectSpeechModel = { [weak self] id in self?.speechModels.select(id) }
        menu.onAddVocabulary = { [weak self] in self?.correctionPanel.present() }
        menu.onUpdate = { [weak self] in self?.updater?.performUpdate() }
        updater?.onUpdateAvailable = { [weak self] in self?.menu.setUpdateAvailable(true) }
        controller.onRecordingChanged = { [weak self] active in
            self?.menu.setDictating(active)
            if !active { self?.updater?.dictationDidFinish() }
        }
        controller.onBecameIdle = { [weak self] in
            guard let self else { return }
            // Resync gesture state on every return to idle. A controller-side abort (over-limit, mic error)
            // drops the machine to idle while a PressGesture still thinks it is recording, so the next
            // tap-to-toggle press would emit .commit into an idle machine (a no-op). Safe at idle: a real
            // in-progress gesture keeps the machine recording, never idle.
            if !self.hotkey.hasPhysicallyDownGesture {
                self.hotkey.cancelGestures()
            }
            guard self.pendingHotkeyRebuild else { return }
            self.pendingHotkeyRebuild = false
            self.buildHotkeyMonitor()
        }

        speechModels = SpeechModelsModel(
            activeId: settings.stt.engine,
            stt: settings.stt,
            download: { [weak self] id, progress in
                guard let engine = self?.provider.engine(id) else { throw EngineUnavailable.notWired(id) }
                try await engine.load(progress: progress)
            },
            verify: { [weak self] id in
                guard let self, let engine = self.provider.engine(id) else { return false }
                return await self.controller.selfTestForSettings(engine)
            },
            evictEngine: { [weak self] id in
                guard let self, let engine = self.provider.engine(id) else { return }
                await self.controller.evictEngineForSettings(engine)
            },
            onActiveChange: { [weak self] id in self?.setEngine(id) },
            onDictionaryMatchingChange: { [weak self] stt in self?.setDictionaryMatching(stt) },
            deferWhileBusy: { [weak self] work in
                guard let self else { work(); return }
                self.controller.runWhenIdle(work)
            })

        settingsController = SettingsController(
            settings: settings, speechModels: speechModels, repository: configRepository,
            onChange: { [weak self] updated in self?.applySettings(updated) },
            onReload: { [weak self] in self?.reloadConfig() },
            onResetHUDPosition: { [weak self] in self?.hud.resetAnchor() },
            detectProblems: { [weak self] in self?.currentProblems() ?? [] },
            accessibilityTapActive: { [weak self] in self?.hotkey?.isTapActive ?? false },
            onRelaunch: { [weak self] in self?.relaunchForPermissionSetup() },
            onEraseAllData: { [weak self] in self?.eraseAllDataAndRelaunch() })
        settingsController.recordingState.onChange = { [weak self] recording in
            self?.hotkey?.isSuspended = recording
        }
        refreshPreferredDeviceName()

        buildHotkeyMonitor()
        applyLoginItem(settings.loadOnLogin)

        // Start the tap now if permissions allow (idempotent); first-run retries via onReadyToDictate
        // once granted, so dictation works regardless of onboarding completion.
        startListening()
        let permissionsReady = Permissions.microphoneStatus() == .granted
            && Permissions.accessibilityStatus() == .granted
        if forceFirstRun {
            // Dev flag: replay the full wizard regardless of the completion flag or permission state.
            presentFirstRun()
        } else if forceResumeOnboarding {
            // Relaunched from the onboarding permissions funnel — the grants now read fresh. Resume the
            // full wizard at the post-permissions step (must precede the permissionsReady branch below,
            // which would otherwise mark setup complete and show nothing, skipping AI + try-it). P2-21.
            presentFirstRun(resumeOnboarding: true)
        } else if forcePermissionsSetup {
            presentFirstRun(permissionsOnly: true)
        } else if UserDefaults.standard.bool(forKey: firstRunKey) || permissionsReady {
            // Already set up (or returning) — don't re-show the wizard; record completion.
            UserDefaults.standard.set(true, forKey: firstRunKey)
        } else {
            presentFirstRun()
        }

        // Warm the HUD window, audio unit, and resolved config so the FIRST dictation doesn't pay their
        // one-time realization on the hot path (handleStart reads config.resolved before the mic starts).
        // Deferred a tick so it never adds to launch itself.
        Task { @MainActor [weak self] in
            self?.hud.prewarm()
            self?.controller.prewarmCapture()
            _ = self?.config.resolved
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.refreshCaptureBinding() }
        }
    }

    // First-run only: before KeyScribe seeds or loads any config, let an injected importer populate the
    // support dir from a legacy app. Gated on the variant's support dir not yet existing, so it runs at
    // most once; no importer injected → no-op.
    private func runLegacyImportIfNeeded() {
        guard let legacyImporter else { return }
        let supportDir = KeyScribePaths.supportDir
        guard !FileManager.default.fileExists(atPath: supportDir.path) else { return }
        do { try legacyImporter.importIfNeeded(into: supportDir) }
        catch { Log.config.error("legacy import failed: \(error.localizedDescription, privacy: .public)") }
    }

    private func loadSettings() {
        do {
            settings = try SettingsStore.loadOrCreate(supportDir: KeyScribePaths.supportDir)
            configError = nil
        } catch {
            settings = Settings.defaults
            configError = "Using defaults — \(error)"
        }
    }

    private func resolveProvider(engines: [any SpeechEngine]) -> SpeechEngineProvider {
        (try? SpeechEngineProvider(engines: engines, activeId: settings.stt.engine))
            ?? (try! SpeechEngineProvider(engines: engines, activeId: SpeechModelCatalog.defaultEnglishId))
    }

    // Precedence order for the app-wide hotkey namespace: Modes (config order) then the two globals.
    // The losers of a chord collision are suppressed at dispatch so the higher-precedence owner fires
    // (first match wins; Modes beat the globals) — and the same set drives the Settings red-dot.
    private func shadowedHotkeyIds() -> Set<String> {
        var ordered: [HotkeyConflicts.Registrant] = []
        for mode in config.modes where mode.enabled {
            for tk in mode.triggerKeys {
                ordered.append(.init(id: "\(mode.id)#\(tk.key)", key: tk.key))
            }
        }
        ordered.append(.init(id: GlobalHotkey.vocabularyId, key: settings.shortcuts.addVocabulary))
        ordered.append(.init(id: GlobalHotkey.pasteLastId, key: settings.shortcuts.pasteLastDictation))
        return HotkeyConflicts.shadowed(ordered)
    }

    private func buildHotkeyMonitor() {
        let shadowed = shadowedHotkeyIds()
        var bindings: [HotkeyMonitor.Binding] = []
        for mode in config.modes where mode.enabled {
            for tk in mode.triggerKeys {
                guard !shadowed.contains("\(mode.id)#\(tk.key)"),
                      let desc = try? KeyDescriptor(parsing: tk.key) else { continue }
                bindings.append(.init(
                    triggerKey: tk.key, descriptor: desc,
                    style: PressStyle(rawValue: tk.pressStyle) ?? .holdOrTap,
                    tapThreshold: Double(tk.tapThresholdMs) / 1000))
            }
        }
        let actionBindings = self.actionBindings(shadowed: shadowed)

        let actionDescriptors = Dictionary(uniqueKeysWithValues: actionBindings.map { ($0.id, $0.descriptor) })
        menu.setActionShortcuts(
            addVocabulary: actionDescriptors[HotkeyAction.addVocabulary.rawValue],
            pasteLast: actionDescriptors[HotkeyAction.pasteLast.rawValue])

        if hotkey == nil {
            hotkey = HotkeyMonitor(
                bindings: bindings, actionBindings: actionBindings,
                onStart: { [weak self] key in self?.controller.handleStart(triggerKey: key) },
                onCommit: { [weak self] _ in
                    self?.controller.handleCommit()
                    self?.refreshStatus()
                },
                onAction: { [weak self] id in self?.handleHotkeyAction(id) })
        } else {
            hotkey.update(bindings: bindings, actionBindings: actionBindings)
        }
    }

    private enum HotkeyAction: String { case addVocabulary, pasteLast }

    // Only chord descriptors are honored — a modifier-only named key would also drive dictation and
    // makes no sense as a discrete action. An unparseable or non-chord string is silently skipped.
    private func actionBindings(shadowed: Set<String>) -> [HotkeyMonitor.ActionBinding] {
        let entries: [(HotkeyAction, String, String)] = [
            (.addVocabulary, settings.shortcuts.addVocabulary, GlobalHotkey.vocabularyId),
            (.pasteLast, settings.shortcuts.pasteLastDictation, GlobalHotkey.pasteLastId),
        ]
        return entries.compactMap { action, key, globalId in
            guard !shadowed.contains(globalId), !key.isEmpty,
                  let desc = try? KeyDescriptor(parsing: key), case .chord = desc else { return nil }
            return .init(id: action.rawValue, descriptor: desc)
        }
    }

    private func handleHotkeyAction(_ id: String) {
        switch HotkeyAction(rawValue: id) {
        case .addVocabulary: correctionPanel.present()
        case .pasteLast: controller.pasteLast()
        case nil: break
        }
    }

    // Set when a config reload arrives mid-dictation: the hotkey rebuild is deferred to the next idle
    // moment (DictationController.onBecameIdle), so a key held during the reload isn't stranded by a
    // fresh PressGesture that never saw its key-down.
    private var pendingHotkeyRebuild = false

    // Drop the cached config and re-register per-mode bindings from the fresh modes. Called by the file
    // watcher (external edits) and the Settings reload button; the rebuild defers if a key is held (see
    // rebuildHotkeyMonitor).
    func reloadConfig() {
        // Re-seed/normalize the system Direct floor before reloading, so an external delete or hand-edit
        // of `_direct.toml` heals immediately (and Fn re-registers) instead of waiting for relaunch.
        ModeStore.ensureSystemModes(in: KeyScribePaths.modesDir, lkgDir: KeyScribePaths.lkgDir.appendingPathComponent("modes", isDirectory: true))
        // Adopt the post-heal state BEFORE the reads below so this reload does not echo into a second one;
        // an edit landing after is caught by the next fire, never absorbed unread.
        selfWriteGate.adopt(ConfigTreeSnapshot.capture(supportDir: KeyScribePaths.supportDir))
        config.invalidate()
        // Absorb an external settings.toml edit (the Advanced pane promises edits are detected). Adopting
        // it into `settings` also means a later in-app toggle merges against the current on-disk value
        switch Self.settingsFileState(current: settings, supportDir: KeyScribePaths.supportDir) {
        case .unchanged:
            configError = nil
            rebuildHotkeyMonitor()
        case .updated(let fresh):
            configError = nil
            applySettingsEffects(fresh)   // rebuilds the hotkey monitor for us
        case .invalid(let message):
            configError = "Settings file has errors — \(message)"
            rebuildHotkeyMonitor()
        }
        refreshStatus()
        // Rebuild the frozen plan off this path so the first press after an edit doesn't pay the
        // modes/dictionary/fragments realization invalidate() just discarded (mirrors the launch warm).
        Task { @MainActor [weak self] in _ = self?.config.resolved }
    }

    private func startListening() {
        // start() registers the Carbon chord hotkeys (no permission needed) regardless of the tap, and
        // creates the modifier-only event tap only when Accessibility is already granted — untrusted it
        // defers tap creation and returns false (leaving chords working). So chord triggers never depend on
        // Accessibility, and we never poke tapCreate before the grant.
        _ = hotkey.start()
        refreshStatus()
    }

    enum SettingsFileState: Equatable {
        case unchanged
        case updated(Settings)
        case invalid(String)
    }

    static func settingsFileState(current: Settings, supportDir: URL) -> SettingsFileState {
        do {
            let fresh = try SettingsStore.loadOrCreate(supportDir: supportDir)
            return fresh == current ? .unchanged : .updated(fresh)
        } catch {
            return .invalid("\(error)")
        }
    }

    nonisolated static func hotkeyConflictDetected(shadowed: Set<String>) -> Bool {
        shadowed.contains(GlobalHotkey.vocabularyId) || shadowed.contains(GlobalHotkey.pasteLastId)
    }

    private func setEngine(_ id: String) {
        guard id != settings.stt.engine else { return }
        var updated = settings
        updated.stt.engine = id
        applySettings(updated)
    }

    private func setDictionaryMatching(_ stt: Settings.STT) {
        guard stt != settings.stt else { return }
        var updated = settings
        updated.stt = stt
        applySettings(updated)
    }

    private func applySettings(_ updated: Settings) {
        applySettingsEffects(updated)
        guard configError == nil else { return }
        do {
            try SettingsStore.write(updated, to: KeyScribePaths.supportDir)
            recordSettingsSelfWrite()
        }
        catch { Log.config.error("settings write failed: \(error.localizedDescription, privacy: .public)") }
    }

    private func recordSettingsSelfWrite() {
        selfWriteGate.recordSelfWrite(
            url: KeyScribePaths.supportDir.appendingPathComponent(SettingsStore.fileName),
            supportDir: KeyScribePaths.supportDir)
    }

    // Apply the runtime consequences of a settings change WITHOUT writing to disk. `applySettings` calls
    // this then persists; `reloadConfig` calls it after re-reading an external edit off disk (no write,
    // so an externally-changed field isn't round-tripped and clobbered).
    private func applySettingsEffects(_ updated: Settings) {
        let previousHistory = settings.history
        if updated.stt.engine != settings.stt.engine {
            let previous = provider.active
            if (try? provider.setActive(updated.stt.engine)) != nil {
                controller.evictSwitchedAwayEngine(previous)
                // Selecting an engine is intent to use it, so start loading and warming it now if installed.
                controller.preloadActiveEngineIfNeeded()
            }
        }
        settings = updated
        if updated.history != previousHistory {
            history?.applyRetention(retentionDays: updated.history.retentionDays)
        }
        controller.updateSettings(updated)
        rebuildHotkeyMonitor()
        applyLoginItem(updated.loadOnLogin)
        settingsController.update(settings: updated)
        refreshStatus()
    }

    // Rebuilding the hotkey monitor replaces its bindings and clears gesture state; doing that while a
    // key is held/latched would drop the pending release edge, so defer to the next idle moment
    // (DictationController.onBecameIdle drains `pendingHotkeyRebuild`).
    private func rebuildHotkeyMonitor() {
        if controller.isBusy { pendingHotkeyRebuild = true }
        else { buildHotkeyMonitor() }
    }

    // Keep the stored friendly name for the preferred input device fresh: if it is connected now and its
    // name has drifted (renamed device, or a name we never captured), update and persist. A disconnected
    // preferred device keeps its last-seen name so the picker still reads as itself.
    private func refreshPreferredDeviceName() {
        guard let uid = settings.audio.inputDeviceUID,
              let device = AudioInputDevices.available().first(where: { $0.uid == uid }),
              settings.audio.inputDeviceName != device.name else { return }
        settings.audio = .init(inputDeviceUID: uid, inputDeviceName: device.name)
        do {
            try SettingsStore.write(settings, to: KeyScribePaths.supportDir)
            recordSettingsSelfWrite()
        }
        catch { Log.config.error("settings write failed: \(error.localizedDescription, privacy: .public)") }
        settingsController.update(settings: settings)
    }

    private func applyLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        } catch {}
    }

    private func presentFirstRun(permissionsOnly: Bool = false, resumeOnboarding: Bool = false) {
        firstRun = FirstRunController(
            initialEngineId: provider.active.id,
            download: { [weak self] id, progress in
                guard let engine = self?.provider.engine(id) else { throw EngineUnavailable.notWired(id) }
                try await engine.load(progress: progress)
                self?.speechModels?.noteInstalled(id)
            },
            selectEngine: { [weak self] id in self?.setEngine(id) },
            onReadyToDictate: { [weak self] in
                self?.startListening()
                self?.controller.prewarmCapture()
            },
            permissionsOnly: permissionsOnly,
            resumeOnboarding: resumeOnboarding,
            repository: configRepository,
            // The full onboarding wizard resumes itself after the permission relaunch (P2-21); the
            // permissions-only repair flow (reached from Settings) stays a permissions-only relaunch.
            onRelaunch: { [weak self] in self?.relaunchForPermissionSetup(resumeOnboarding: !permissionsOnly) },
            tapActive: { [weak self] in self?.hotkey?.isTapActive ?? false }
        ) { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(true, forKey: firstRunKey)
            self.controller.onDictationCompleted = nil
            self.firstRun = nil
            self.startListening()
            self.controller.prewarmCapture()
        }
        controller.onDictationCompleted = { [weak self] completion in
            self?.firstRun?.noteDictation(completion)
        }
        firstRun?.present()
    }

    private func correctionDestinations() -> [CorrectionDestination] {
        CorrectionDestination.list(for: config.modes)
    }

    // Relaunch into guided setup so the new process reads the just-granted Accessibility verdict fresh
    // (it is cached at launch). First reset any denied ListenEvent record: a pre-fix build calling
    // tapCreate before the grant could leave one that permanently suppresses the modifier tap even after
    // Accessibility is granted; clearing heals those installs (no-op on a clean machine). User-initiated,
    // so it cannot loop.
    private func relaunchForPermissionSetup(resumeOnboarding: Bool = false) {
        ResetTool.resetInputMonitoring()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [resumeOnboarding ? "--resume-onboarding" : "--setup-permissions"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    // Erase all on-disk data + BYOK Keychain keys, then relaunch into a clean first run. The fresh
    // instance is spawned before this one terminates so the menu-bar app does not just vanish; with the
    // onboarding flag cleared (and TCC grants intact) it lands on the first-run wizard.
    private func eraseAllDataAndRelaunch() {
        ResetTool(supportDir: KeyScribePaths.supportDir, defaults: .standard).run(.eraseAll)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private func refreshStatus() {
        menu.setHasResult(controller.hasResult)
        let problems = currentProblems()
        menu.setErrorBadge(!problems.isEmpty)
        settingsController?.refreshProblems(problems)

        if let message = combinedConfigError {
            menu.setStatus(message)
        } else if Permissions.microphoneStatus() != .granted {
            menu.setStatus("Microphone access needed")
        } else if Permissions.accessibilityStatus() != .granted {
            menu.setStatus("Accessibility access needed")
        } else if !(hotkey?.isTapActive ?? true) {
            menu.setStatus("Relaunch to finish setup")
        } else {
            // The mode portion names the one-shot override if one is pending, otherwise Automatic's default.
            let enabledModes = config.modes.filter(\.enabled)
            let automatic = enabledModes.first { $0.id == Mode.directId } ?? enabledModes.first
            let nextMode = controller.nextModeOverrideName ?? automatic?.name
            let model = speechModels.activeName
            menu.setStatus(nextMode.map { "\($0) · \(model)" } ?? model)
        }
    }

    // The modes/speech-model submenus are only visible while the menu is open, so they are rebuilt on
    // menuWillOpen rather than on every refreshStatus — the latter fires after each dictation, which
    // otherwise reallocated every submenu item while the menu was closed.
    private func rebuildMenuItems() {
        let modes = config.modes.filter(\.enabled)
        let automatic = modes.first { $0.id == Mode.directId } ?? modes.first
        var inertReasons: [String: String] = [:]
        for mode in modes where connectionUnavailable(for: mode) {
            inertReasons[mode.id] = "needs an AI service"
        }
        menu.setModes(
            modes, automaticName: automatic?.name, overrideName: controller.nextModeOverrideID,
            inertReasons: inertReasons)
        menu.setSpeechModels(speechModels.rows)
    }

    // settings.toml decode failures (owned by AppDelegate) plus any malformed vocabulary/connection
    // file surfaced by the config cache — both light the Advanced pane's malformed-config problem and
    // the menu status line so a broken config file is never silently swallowed (P2-14).
    private var combinedConfigError: String? {
        let parts = [configError, config.configFileError].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func currentProblems() -> [SettingsProblem] {
        let modes = config.modes.filter(\.enabled)
        let failedConnectionIds = settingsController?.failedConnectionIds ?? []
        return SettingsProblem.detect(
            hasConfigError: combinedConfigError != nil,
            microphoneGranted: Permissions.microphoneStatus() == .granted,
            accessibilityGranted: Permissions.accessibilityStatus() == .granted,
            accessibilityTapActive: hotkey?.isTapActive ?? true,
            activeEngineUsable: speechModels?.activeEngineUsable ?? true,
            modelSelfTestFailed: speechModels?.hasFailedModel ?? false,
            aiConnectionTestFailed: failedConnectionIds.isEmpty == false,
            aiConnectionMisconfigured: config.connections.connections.contains { $0.configIssue != nil },
            modeNeedsAIService: modes.contains { connectionUnavailable(for: $0) },
            modeUsesFailedConnection: modes.contains { usesFailedConnection($0, failed: failedConnectionIds) },
            hotkeyConflict: Self.hotkeyConflictDetected(shadowed: shadowedHotkeyIds()))
    }

    private func connectionUnavailable(for mode: Mode) -> Bool {
        guard let rewrite = mode.aiRewrite else { return false }
        return rewrite.connection.isEmpty || config.connections.connection(id: rewrite.connection) == nil
    }

    // The mode is wired to an AI connection whose last Test Connection failed — the mode itself won't
    // rewrite, so the Modes pane is flagged in addition to AI Services.
    private func usesFailedConnection(_ mode: Mode, failed: Set<String>) -> Bool {
        guard let rewrite = mode.aiRewrite else { return false }
        return failed.contains(rewrite.connection)
    }
}
