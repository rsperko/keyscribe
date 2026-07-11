import Foundation

enum AccessibilityID {
    enum Settings {
        enum Sidebar {
            static let general = "settings.sidebar.general"
            static let speechModels = "settings.sidebar.speechModels"
            static let vocabulary = "settings.sidebar.vocabulary"
            static let aiServices = "settings.sidebar.aiServices"
            static let modes = "settings.sidebar.modes"
            static let history = "settings.sidebar.history"
            static let permissions = "settings.sidebar.permissions"
            static let advanced = "settings.sidebar.advanced"

            static func id(for destination: SettingsDestination) -> String {
                switch destination {
                case .general: return general
                case .speechModels: return speechModels
                case .vocabulary: return vocabulary
                case .aiServices: return aiServices
                case .modes: return modes
                case .history: return history
                case .permissions: return permissions
                case .advanced: return advanced
                }
            }
        }

        enum General {
            static let sounds = "settings.general.sounds"
            static let keepDisplayAwake = "settings.general.keepDisplayAwake"
            static let muteSystemAudio = "settings.general.muteSystemAudio"
            static let inputDevice = "settings.general.inputDevice"
            static let loadOnLogin = "settings.general.loadOnLogin"
            static let addVocabularyShortcut = "settings.general.addVocabularyShortcut"
            static let pasteLastShortcut = "settings.general.pasteLastShortcut"
            static let historyEnabled = "settings.general.historyEnabled"
            static let retentionDays = "settings.general.retentionDays"
            static let eviction = "settings.general.eviction"
            static let advancedModelBehavior = "settings.general.advancedModelBehavior"
            static let dictationTrigger = "settings.general.dictationTrigger"
            static let changeDictationTrigger = "settings.general.changeDictationTrigger"
        }

        enum Speech {
            static let list = "settings.speech.list"
            static let change = "settings.speech.change"
            static let back = "settings.speech.back"
            static let eviction = "settings.speech.eviction"
            static let advancedModelBehavior = "settings.speech.advancedModelBehavior"
            static let deleteConfirmConfirm = "settings.speech.deleteConfirm.confirm"
            static let deleteConfirmCancel = "settings.speech.deleteConfirm.cancel"
            static func row(_ engineID: String) -> String { "settings.speech.row.\(engineID)" }
            static func primaryAction(_ engineID: String) -> String { "settings.speech.row.\(engineID).primaryAction" }
            static func test(_ engineID: String) -> String { "settings.speech.row.\(engineID).test" }
            static func testAgain(_ engineID: String) -> String { "settings.speech.row.\(engineID).testAgain" }
            static func reinstall(_ engineID: String) -> String { "settings.speech.row.\(engineID).reinstall" }
            static func delete(_ engineID: String) -> String { "settings.speech.row.\(engineID).delete" }
            static func recognitionBias(_ engineID: String) -> String { "settings.speech.row.\(engineID).recognitionBias" }
            static func sizeStatus(_ engineID: String) -> String { "settings.speech.row.\(engineID).sizeStatus" }
        }

        enum Vocabulary {
            static let composerTerm = "settings.vocabulary.composer.term"
            static let composerUseInstead = "settings.vocabulary.composer.useInstead"
            static let composerRegexToggle = "settings.vocabulary.composer.regexToggle"
            static let composerAdvanced = "settings.vocabulary.composer.advanced"
            static let composerAdd = "settings.vocabulary.composer.add"
            static let dictionaryList = "settings.vocabulary.dictionary.list"
            static let replacementsList = "settings.vocabulary.replacements.list"
        }

        enum AI {
            static let list = "settings.ai.list"
            static let add = "settings.ai.list.add"
            static func row(_ connectionID: String) -> String { "settings.ai.list.row.\(connectionID)" }

            enum Editor {
                static let name = "settings.ai.editor.name"
                static let provider = "settings.ai.editor.provider"
                static let baseURL = "settings.ai.editor.baseURL"
                static let auth = "settings.ai.editor.auth"
                static let apiKey = "settings.ai.editor.apiKey"
                static let saveKey = "settings.ai.editor.saveKey"
                static let tokenCommand = "settings.ai.editor.tokenCommand"
                static let model = "settings.ai.editor.model"
                static let fetchModels = "settings.ai.editor.fetchModels"
                static let foundModel = "settings.ai.editor.foundModel"
                static let testConnection = "settings.ai.editor.testConnection"
                static let delete = "settings.ai.editor.delete"
                static let done = "settings.ai.editor.done"
            }

            enum Summary {
                static let edit = "settings.ai.summary.edit"
                static let test = "settings.ai.summary.test"
                static let createMode = "settings.ai.summary.createMode"
            }

            enum Draft {
                static let connect = "settings.ai.draft.connect"
                static let cancel = "settings.ai.draft.cancel"
            }
        }

        enum Permissions {
            static let list = "settings.permissions.list"
            static func row(_ permID: String) -> String { "settings.permissions.row.\(permID)" }
            static func allow(_ permID: String) -> String { "settings.permissions.row.\(permID).allow" }
            static func openSettings(_ permID: String) -> String { "settings.permissions.row.\(permID).openSettings" }
            static func relaunch(_ permID: String) -> String { "settings.permissions.row.\(permID).relaunch" }
        }

        enum Advanced {
            static let revealConfig = "settings.advanced.revealConfig"
            static let reloadConfig = "settings.advanced.reloadConfig"
            static let resetHUDPosition = "settings.advanced.resetHUDPosition"
            static let eraseAllData = "settings.advanced.eraseAllData"
            static let eraseConfirmConfirm = "settings.advanced.eraseConfirm.confirm"
            static let eraseConfirmCancel = "settings.advanced.eraseConfirm.cancel"
            static func feature(_ featureID: String) -> String { "settings.advanced.feature.\(featureID)" }
        }
    }

    enum Mode {
        enum List {
            static let list = "mode.list"
            static let add = "mode.list.add"
            static let addBlank = "mode.list.add.blank"
            static func addTemplate(_ seedID: String) -> String { "mode.list.add.template.\(seedID)" }
            static func row(_ modeID: String) -> String { "mode.list.row.\(modeID)" }
        }

        enum Gallery {
            static func add(_ seedID: String) -> String { "mode.gallery.add.\(seedID)" }
        }

        enum Editor {
            static let name = "mode.editor.name"
            static let enabled = "mode.editor.enabled"
            static let shortcutWell = "mode.editor.shortcutWell"
            static let pressStyle = "mode.editor.pressStyle"
            static let rewriteSelection = "mode.editor.rewriteSelection"
            static let liveEdits = "mode.editor.liveEdits"
            static let aiService = "mode.editor.aiService"
            static let instruction = "mode.editor.instruction"
            static let addInstruction = "mode.editor.addInstruction"
            static let privacy = "mode.editor.privacy"
            static let excludeFromHistory = "mode.editor.excludeFromHistory"
            static let trimTrailingPunctuation = "mode.editor.trimTrailingPunctuation"
            static let trailing = "mode.editor.trailing"
            static let duplicate = "mode.editor.duplicate"
            static let delete = "mode.editor.delete"

            enum Context {
                static let app = "mode.editor.context.app"
                static let precedingText = "mode.editor.context.precedingText"
            }

            enum Routing {
                static let disclosure = "mode.editor.routing.disclosure"
                static let addAppRule = "mode.editor.routing.addAppRule"
                static let bundleID = "mode.editor.routing.bundleId"
                static let bundleIDAdd = "mode.editor.routing.bundleId.add"
                static let urlPattern = "mode.editor.routing.urlPattern"
                static let urlPatternAdd = "mode.editor.routing.urlPattern.add"
                static let windowTitle = "mode.editor.routing.windowTitle"
                static let windowTitleAdd = "mode.editor.routing.windowTitle.add"
                static let phrase = "mode.editor.routing.phrase"
                static let phraseAdd = "mode.editor.routing.phrase.add"
                static let websitePattern = "mode.editor.routing.websitePattern"
                static let websitePatternAdd = "mode.editor.routing.websitePattern.add"
            }

            enum Recognition {
                static let disclosure = "mode.editor.recognition.disclosure"
            }
        }
    }

    enum FirstRun {
        enum Intro {
            static let getStarted = "firstrun.intro.getStarted"
        }

        enum Model {
            static let advancedDisclosure = "firstrun.model.advancedDisclosure"
            static let enginePicker = "firstrun.model.enginePicker"
            static let progress = "firstrun.model.progress"
            static let useAppleSpeech = "firstrun.model.useAppleSpeech"
            static let download = "firstrun.model.download"
        }

        enum Permissions {
            static let skip = "firstrun.permissions.skip"
            static let done = "firstrun.permissions.done"
            static let relaunch = "firstrun.permissions.relaunch"
            static let `continue` = "firstrun.permissions.continue"
            static func row(_ permID: String) -> String { "firstrun.permissions.row.\(permID)" }
            static func grant(_ permID: String) -> String { "firstrun.permissions.row.\(permID).grant" }
            static func openSettings(_ permID: String) -> String { "firstrun.permissions.row.\(permID).openSettings" }
        }

        enum TryIt {
            static let field = "firstrun.tryit.field"
            static let skip = "firstrun.tryit.skip"
            static let done = "firstrun.tryit.done"
            static let changeTrigger = "firstrun.tryit.changeTrigger"
            static let shortcutWell = "firstrun.tryit.shortcutWell"
        }

        enum AI {
            static let connectionEditor = "firstrun.ai.connectionEditor"
            static let connect = "firstrun.ai.connect"
            static let skip = "firstrun.ai.skip"
            static let offerConnect = "firstrun.ai.offerConnect"
        }

        enum Playground {
            static let field = "firstrun.playground.field"
            static let next = "firstrun.playground.next"
            static let done = "firstrun.playground.done"
            static func lesson(_ modeID: String) -> String { "firstrun.playground.lesson.\(modeID)" }
        }
    }

    enum HUD {
        static let panel = "hud.panel"
        static let insertWithoutRewriting = "hud.action.insertWithoutRewriting"
        static let pasteLast = "hud.action.pasteLast"
        static let repairAction = "hud.action.repair"
    }

    enum History {
        static let list = "history.list"
        static let row = "history.list.row"
        static let search = "history.search"
        static let export = "history.action.export"
        static let stagePicker = "history.detail.stagePicker"
        static let comparisonPicker = "history.detail.comparisonPicker"
        static let promptDisclosure = "history.detail.promptDisclosure"
        static let copyResult = "history.action.copyResult"
        static let pasteResult = "history.action.pasteResult"
        static let copyHeard = "history.action.copyHeard"
        static let delete = "history.action.delete"
        static let manageVocabulary = "history.action.manageVocabulary"
        static let createReplacement = "history.action.createReplacement"
        static let addToDictionary = "history.action.addToDictionary"

        enum ReplacementSheet {
            static let source = "history.replacementSheet.source"
            static let replace = "history.replacementSheet.replace"
            static let save = "history.replacementSheet.save"
        }

        enum DictionarySheet {
            static let term = "history.dictionarySheet.term"
            static let save = "history.dictionarySheet.save"
        }
    }

    enum Correction {
        static let term = "correction.term"
        static let useInstead = "correction.useInstead"
        static let regexToggle = "correction.regexToggle"
        static let destination = "correction.destination"
        static let add = "correction.add"
        static let addAndReplace = "correction.addAndReplace"
        static let cancel = "correction.cancel"
    }

    // The status menu is pure AppKit (NSMenu / NSMenuItem / NSStatusBarButton). Empirically, macOS does
    // NOT surface a custom accessibilityIdentifier for these: AppKit derives a menu item's AXIdentifier
    // from its action selector (e.g. "openSettings"), and the status button's AXMenuBarItem exposes no
    // identifier at all. So the menu bar has no entries here — items are addressed by title (or by their
    // action-derived id / representedObject for dynamic rows). See a11y-worklist.md for the finding.

    static let all: [String] = [
        Settings.Sidebar.general, Settings.Sidebar.speechModels, Settings.Sidebar.vocabulary,
        Settings.Sidebar.aiServices, Settings.Sidebar.modes, Settings.Sidebar.history, Settings.Sidebar.permissions,
        Settings.Sidebar.advanced,
        Settings.General.sounds, Settings.General.keepDisplayAwake, Settings.General.muteSystemAudio,
        Settings.General.inputDevice, Settings.General.loadOnLogin, Settings.General.addVocabularyShortcut,
        Settings.General.pasteLastShortcut, Settings.General.historyEnabled, Settings.General.retentionDays,
        Settings.General.dictationTrigger, Settings.General.changeDictationTrigger,
        Settings.Speech.list, Settings.Speech.deleteConfirmConfirm, Settings.Speech.deleteConfirmCancel,
        Settings.Speech.change, Settings.Speech.back,
        Settings.Speech.eviction, Settings.Speech.advancedModelBehavior,
        Settings.Vocabulary.composerTerm, Settings.Vocabulary.composerUseInstead,
        Settings.Vocabulary.composerRegexToggle, Settings.Vocabulary.composerAdvanced, Settings.Vocabulary.composerAdd,
        Settings.Vocabulary.dictionaryList, Settings.Vocabulary.replacementsList,
        Settings.AI.list, Settings.AI.add,
        Settings.AI.Editor.name, Settings.AI.Editor.provider, Settings.AI.Editor.baseURL,
        Settings.AI.Editor.auth, Settings.AI.Editor.apiKey, Settings.AI.Editor.saveKey,
        Settings.AI.Editor.tokenCommand, Settings.AI.Editor.model, Settings.AI.Editor.fetchModels,
        Settings.AI.Editor.foundModel, Settings.AI.Editor.testConnection, Settings.AI.Editor.delete,
        Settings.AI.Editor.done,
        Settings.AI.Summary.edit, Settings.AI.Summary.test, Settings.AI.Summary.createMode,
        Settings.AI.Draft.connect, Settings.AI.Draft.cancel,
        Settings.Permissions.list,
        Settings.Advanced.revealConfig, Settings.Advanced.reloadConfig, Settings.Advanced.resetHUDPosition,
        Settings.Advanced.eraseAllData, Settings.Advanced.eraseConfirmConfirm, Settings.Advanced.eraseConfirmCancel,
        Mode.List.list, Mode.List.add, Mode.List.addBlank,
        Mode.Editor.name, Mode.Editor.enabled, Mode.Editor.shortcutWell, Mode.Editor.pressStyle,
        Mode.Editor.rewriteSelection, Mode.Editor.liveEdits, Mode.Editor.aiService, Mode.Editor.instruction,
        Mode.Editor.addInstruction, Mode.Editor.privacy, Mode.Editor.excludeFromHistory,
        Mode.Editor.trimTrailingPunctuation, Mode.Editor.trailing, Mode.Editor.duplicate, Mode.Editor.delete,
        Mode.Editor.Context.app, Mode.Editor.Context.precedingText,
        Mode.Editor.Routing.disclosure, Mode.Editor.Routing.addAppRule, Mode.Editor.Routing.bundleID,
        Mode.Editor.Routing.bundleIDAdd, Mode.Editor.Routing.urlPattern, Mode.Editor.Routing.urlPatternAdd,
        Mode.Editor.Routing.windowTitle, Mode.Editor.Routing.windowTitleAdd, Mode.Editor.Routing.phrase,
        Mode.Editor.Routing.phraseAdd, Mode.Editor.Routing.websitePattern, Mode.Editor.Routing.websitePatternAdd,
        Mode.Editor.Recognition.disclosure,
        FirstRun.Intro.getStarted,
        FirstRun.Model.advancedDisclosure, FirstRun.Model.enginePicker, FirstRun.Model.progress,
        FirstRun.Model.useAppleSpeech, FirstRun.Model.download,
        FirstRun.Permissions.skip, FirstRun.Permissions.done, FirstRun.Permissions.relaunch,
        FirstRun.Permissions.continue,
        FirstRun.TryIt.field, FirstRun.TryIt.skip, FirstRun.TryIt.done,
        FirstRun.TryIt.changeTrigger, FirstRun.TryIt.shortcutWell,
        FirstRun.AI.connectionEditor, FirstRun.AI.connect, FirstRun.AI.skip, FirstRun.AI.offerConnect,
        FirstRun.Playground.field, FirstRun.Playground.next, FirstRun.Playground.done,
        HUD.panel, HUD.insertWithoutRewriting, HUD.pasteLast, HUD.repairAction,
        History.list, History.search, History.export, History.stagePicker, History.comparisonPicker,
        History.promptDisclosure, History.copyResult, History.pasteResult, History.copyHeard, History.delete,
        History.manageVocabulary, History.createReplacement, History.addToDictionary,
        History.ReplacementSheet.source, History.ReplacementSheet.replace, History.ReplacementSheet.save,
        History.DictionarySheet.term, History.DictionarySheet.save,
        Correction.term, Correction.useInstead, Correction.regexToggle, Correction.destination,
        Correction.add, Correction.addAndReplace, Correction.cancel,
    ]
}
