import Foundation
import KeyScribeKit

// Single path for the correction-surface config mutations (Add to Dictionary / Create Replacement
// from the menu, History detail, and standalone panel). It writes the file, then invalidates the
// ConfigCache immediately so the *next dictation* sees the change without waiting on the FSEvents
// watcher, and reports failure instead of swallowing it with `try?`. The watcher still fires for
// external edits; an extra invalidate from it is harmless (idempotent). `onChange` lets the host
// refresh dependent UI (menu status). Settings-pane editors still write through their own stores —
// folding those in is a larger migration tracked separately.
@MainActor
final class ConfigRepository {
    private let supportDir: URL
    private let config: ConfigCache
    var onChange: (() -> Void)?

    init(supportDir: URL, config: ConfigCache) {
        self.supportDir = supportDir
        self.config = config
    }

    @discardableResult
    func addDictionaryWord(_ word: String) -> Bool {
        let set = DictionaryStore.loadOrDefault(supportDir: supportDir).adding(word: word)
        return persist("dictionary word") { try DictionaryStore.write(set, to: supportDir) }
    }

    @discardableResult
    func addReplacement(heard: String, replace: String) -> Bool {
        let set = ReplacementsStore.loadOrDefault(supportDir: supportDir)
            .addingLiteral(heard: heard, replace: replace)
        return persist("replacement") { try ReplacementsStore.write(set, to: supportDir) }
    }

    private func persist(_ what: String, _ write: () throws -> Void) -> Bool {
        do {
            try write()
            config.invalidate()
            onChange?()
            return true
        } catch {
            Log.config.error("failed to write \(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
