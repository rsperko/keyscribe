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

    private let firstRunKey = "didCompleteFirstRun"

    func applicationDidFinishLaunching(_: Notification) {
        loadSettings()
        let engines = EngineRegistry.makeAll(modelsDir: KeyScribePaths.modelsDir)
        ModelInstallStore.reconcile(engines: engines)
        provider = resolveProvider(engines: engines)
        ModeStore.seedStartersIfEmpty(in: KeyScribePaths.modesDir)
        config = ConfigCache(supportDir: KeyScribePaths.supportDir)
        configWatcher = ConfigWatcher(path: KeyScribePaths.supportDir.path) { [weak self] in
            Task { @MainActor in self?.reloadConfig() }
        }
        history = HistoryStore(supportDir: KeyScribePaths.supportDir)
        if settings.history.enabled {
            history.applyRetention(retentionDays: settings.history.retentionDays)
        }
        controller = DictationController(
            settings: settings, provider: provider, config: config, history: history, hud: hud)
        controller.preloadActiveEngineIfNeeded()
        hud.onInsertLocalTranscript = { [weak self] in self?.controller.insertLocalTranscriptNow() }
        hud.onPasteLast = { [weak self] in self?.controller.pasteLast() }

        historyController = HistoryController(
            store: history,
            addDictionaryWord: { [weak self] word in self?.addDictionaryWord(word) },
            addReplacement: { [weak self] heard, replace in self?.addReplacement(heard: heard, replace: replace) },
            openSettings: { [weak self] in self?.settingsController.present() })
        correctionPanel = CorrectionPanelController(
            addDictionaryWord: { [weak self] word in self?.addDictionaryWord(word) },
            addReplacement: { [weak self] heard, replace in self?.addReplacement(heard: heard, replace: replace) })

        menu.install()
        menu.onPasteLast = { [weak self] in self?.controller.pasteLast() }
        menu.onOpenHistory = { [weak self] in self?.historyController.present() }
        menu.onOpenSettings = { [weak self] in self?.settingsController.present() }
        menu.onOpenNotices = { [weak self] in self?.notices.present() }
        menu.onMenuWillOpen = { [weak self] in self?.refreshStatus() }
        menu.onSelectNextMode = { [weak self] id in
            self?.controller.setNextModeOverride(id: id)
            self?.controller.acknowledgeNextMode()
            self?.refreshStatus()
        }
        menu.onAddDictionaryEntry = { [weak self] in self?.correctionPanel.present(.dictionary) }
        menu.onAddReplacement = { [weak self] in self?.correctionPanel.present(.replacement) }
        controller.onRecordingChanged = { [weak self] active in self?.menu.setDictating(active) }

        speechModels = SpeechModelsModel(
            activeId: settings.stt.engine,
            download: { [weak self] id, progress in
                guard let engine = self?.provider.engine(id) else { throw EngineUnavailable.notWired(id) }
                try await engine.load(progress: progress)
            },
            verify: { [weak self] id in
                guard let engine = self?.provider.engine(id) else { return false }
                return await ModelSelfTestRunner.verify(engine)
            },
            evictEngine: { [weak self] id in
                if let e = self?.provider.engine(id) { await e.evict() }
            },
            onActiveChange: { [weak self] id in self?.setEngine(id) })

        settingsController = SettingsController(
            settings: settings, speechModels: speechModels,
            onChange: { [weak self] updated in self?.applySettings(updated) },
            onReload: { [weak self] in self?.reloadConfig() },
            detectProblems: { [weak self] in self?.currentProblems() ?? [] })
        settingsController.recordingState.onChange = { [weak self] recording in
            self?.hotkey?.isSuspended = recording
        }

        buildHotkeyMonitor()
        applyLoginItem(settings.loadOnLogin)

        // Start the tap now if permissions already allow (idempotent); first-run re-tries it via
        // onReadyToDictate once permissions are granted. So dictation works regardless of whether
        // onboarding has been completed.
        startListening()
        let permissionsReady = Permissions.microphoneStatus() == .granted
            && Permissions.inputMonitoringStatus() == .granted
            && Permissions.accessibilityStatus() == .granted
        if UserDefaults.standard.bool(forKey: firstRunKey) || permissionsReady {
            // Already set up (or returning) — don't re-show the wizard; record completion.
            UserDefaults.standard.set(true, forKey: firstRunKey)
        } else {
            presentFirstRun()
        }
    }

    private func loadSettings() {
        do {
            settings = try SettingsStore.loadOrCreate(supportDir: KeyScribePaths.supportDir)
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
        ordered.append(.init(id: GlobalHotkey.dictionaryId, key: settings.shortcuts.addDictionaryEntry))
        ordered.append(.init(id: GlobalHotkey.replacementId, key: settings.shortcuts.addReplacement))
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

        if hotkey == nil {
            hotkey = HotkeyMonitor(
                bindings: bindings, actionBindings: actionBindings,
                onStart: { [weak self] key in self?.controller.handleStart(triggerKey: key) },
                onCommit: { [weak self] _ in
                    self?.controller.handleCommit()
                    self?.refreshStatus()
                },
                onAction: { [weak self] id in self?.handleHotkeyAction(id) },
                onCancel: { [weak self] in
                    self?.controller.cancel()
                    self?.refreshStatus()
                },
                canCancel: { [weak self] in self?.controller.isCancellable ?? false })
        } else {
            hotkey.update(bindings: bindings, actionBindings: actionBindings)
        }
    }

    private enum HotkeyAction: String { case addDictionary, addReplacement }

    // Only chord descriptors are honored — a modifier-only named key would also drive dictation and
    // makes no sense as a discrete action. An unparseable or non-chord string is silently skipped.
    private func actionBindings(shadowed: Set<String>) -> [HotkeyMonitor.ActionBinding] {
        let entries: [(HotkeyAction, String, String)] = [
            (.addDictionary, settings.shortcuts.addDictionaryEntry, GlobalHotkey.dictionaryId),
            (.addReplacement, settings.shortcuts.addReplacement, GlobalHotkey.replacementId),
        ]
        return entries.compactMap { action, key, globalId in
            guard !shadowed.contains(globalId), !key.isEmpty,
                  let desc = try? KeyDescriptor(parsing: key), case .chord = desc else { return nil }
            return .init(id: action.rawValue, descriptor: desc)
        }
    }

    private func handleHotkeyAction(_ id: String) {
        switch HotkeyAction(rawValue: id) {
        case .addDictionary: correctionPanel.present(.dictionary)
        case .addReplacement: correctionPanel.present(.replacement)
        case nil: break
        }
    }

    private func addDictionaryWord(_ word: String) {
        let set = DictionaryStore.loadOrDefault(supportDir: KeyScribePaths.supportDir).adding(word: word)
        try? DictionaryStore.write(set, to: KeyScribePaths.supportDir)
    }

    private func addReplacement(heard: String, replace: String) {
        let set = ReplacementsStore.loadOrDefault(supportDir: KeyScribePaths.supportDir)
            .addingLiteral(heard: heard, replace: replace)
        try? ReplacementsStore.write(set, to: KeyScribePaths.supportDir)
    }

    // Drop the cached config and re-register per-mode key bindings from the fresh modes. Called by
    // the file watcher (external edits) and the Settings reload button.
    func reloadConfig() {
        config.invalidate()
        buildHotkeyMonitor()
        refreshStatus()
    }

    private func startListening() {
        if Permissions.inputMonitoringStatus() == .granted {
            _ = hotkey.start()
        }
        refreshStatus()
    }

    private func setEngine(_ id: String) {
        guard id != settings.stt.engine else { return }
        var updated = settings
        updated.stt = .init(
            engine: id, eviction: settings.stt.eviction,
            evictionIdleSeconds: settings.stt.evictionIdleSeconds)
        applySettings(updated)
    }

    private func applySettings(_ updated: Settings) {
        if updated.stt.engine != settings.stt.engine {
            let previous = provider.active
            if (try? provider.setActive(updated.stt.engine)) != nil {
                Task { await previous.evict() }
            }
        }
        settings = updated
        controller.updateSettings(updated)
        buildHotkeyMonitor()
        applyLoginItem(updated.loadOnLogin)
        try? SettingsStore.write(updated, to: KeyScribePaths.supportDir)
        settingsController.update(settings: updated)
        refreshStatus()
    }

    private func applyLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        } catch {}
    }

    private func presentFirstRun() {
        firstRun = FirstRunController(
            initialEngineId: provider.active.id,
            download: { [weak self] id, progress in
                guard let engine = self?.provider.engine(id) else { throw EngineUnavailable.notWired(id) }
                try await engine.load(progress: progress)
            },
            selectEngine: { [weak self] id in self?.setEngine(id) },
            onReadyToDictate: { [weak self] in self?.startListening() }
        ) { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(true, forKey: firstRunKey)
            self.controller.onDictationCompleted = nil
            self.firstRun = nil
            self.startListening()
        }
        controller.onDictationCompleted = { [weak self] outcome in
            self?.firstRun?.noteDictation(outcome)
        }
        firstRun?.present()
    }

    private func refreshStatus() {
        menu.setHasResult(controller.hasResult)
        let modes = config.modes.filter(\.enabled)
        let automatic = modes.first { $0.id == settings.defaultModeId } ?? modes.first
        var inertReasons: [String: String] = [:]
        for mode in modes where connectionUnavailable(for: mode) {
            inertReasons[mode.id] = "needs an AI service"
        }
        menu.setModes(
            modes, automaticName: automatic?.name, overrideName: controller.nextModeOverrideName,
            inertReasons: inertReasons)
        let problems = currentProblems()
        menu.setErrorBadge(!problems.isEmpty)
        settingsController?.refreshProblems()

        if let configError {
            menu.setStatus(configError)
        } else if Permissions.microphoneStatus() != .granted {
            menu.setStatus("Microphone permission needed")
        } else if Permissions.inputMonitoringStatus() != .granted {
            menu.setStatus("Input Monitoring permission needed")
        } else if Permissions.accessibilityStatus() != .granted {
            menu.setStatus("Accessibility permission needed")
        } else {
            menu.setStatus("Ready · Local transcription")
        }
    }

    private func currentProblems() -> [SettingsProblem] {
        let modes = config.modes.filter(\.enabled)
        let failedConnectionIds = settingsController?.failedConnectionIds ?? []
        return SettingsProblem.detect(
            hasConfigError: configError != nil,
            microphoneGranted: Permissions.microphoneStatus() == .granted,
            inputMonitoringGranted: Permissions.inputMonitoringStatus() == .granted,
            accessibilityGranted: Permissions.accessibilityStatus() == .granted,
            activeEngineUsable: speechModels?.activeEngineUsable ?? true,
            aiConnectionMissing: modes.contains { connectionDangling(for: $0) },
            aiConnectionTestFailed: failedConnectionIds.isEmpty == false,
            aiConnectionMisconfigured: config.connections.connections.contains { $0.configIssue != nil },
            modeUsesFailedConnection: modes.contains { usesFailedConnection($0, failed: failedConnectionIds) },
            hotkeyConflict: shadowedHotkeyIds().contains {
                $0 == GlobalHotkey.dictionaryId || $0 == GlobalHotkey.replacementId
            })
    }

    // Mode wants AI but the named connection cannot be used right now — empty (not yet chosen) or
    // not found. Drives the menu's inert "needs an AI service" label; the empty case is the optional
    // "no AI yet" default, so it is *not* an error badge.
    private func connectionUnavailable(for mode: Mode) -> Bool {
        guard let rewrite = mode.aiRewrite else { return false }
        return rewrite.connection.isEmpty || config.connections.connection(id: rewrite.connection) == nil
    }

    // A *dangling* reference: the mode names a non-empty connection that does not exist (it was
    // deleted). Only a broken pointer is a misconfiguration — an empty connection is not.
    private func connectionDangling(for mode: Mode) -> Bool {
        guard let rewrite = mode.aiRewrite, !rewrite.connection.isEmpty else { return false }
        return config.connections.connection(id: rewrite.connection) == nil
    }

    // The mode is wired to an AI connection whose last Test Connection failed — the mode itself won't
    // rewrite, so the Modes pane is flagged in addition to AI Services.
    private func usesFailedConnection(_ mode: Mode, failed: Set<String>) -> Bool {
        guard let rewrite = mode.aiRewrite else { return false }
        return failed.contains(rewrite.connection)
    }
}
