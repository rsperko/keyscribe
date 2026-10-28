import Foundation

public struct ReplacementUsage: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public struct Entry: Codable, Equatable, Sendable {
        public var count: Int
        public var lastUsed: String?
        public var since: String?
        public var health: Health?

        public init(count: Int, lastUsed: String?, since: String?, health: Health? = nil) {
            self.count = count
            self.lastUsed = lastUsed
            self.since = since
            self.health = health
        }
    }

    // Dictations in which the rule did something the user probably did not mean, counted for one version of
    // the rule only: a repair changes the fingerprint and starts the count over, so an old problem never
    // sticks to the fixed rule.
    public struct Health: Codable, Equatable, Sendable {
        public var fingerprint: String
        public var insideWord: Int
        public var returnOmitted: Int
        public var editedOn: String?

        public init(fingerprint: String, insideWord: Int = 0, returnOmitted: Int = 0, editedOn: String? = nil) {
            self.fingerprint = fingerprint
            self.insideWord = insideWord
            self.returnOmitted = returnOmitted
            self.editedOn = editedOn
        }
    }

    public static func fingerprint(heard: String, replace: String, regex: Bool, wholeDictation: Bool) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(heard)\u{0}\(replace)\u{0}\(regex)\u{0}\(wholeDictation)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    public static func fingerprint(of rule: ReplacementRule) -> String {
        fingerprint(heard: rule.heard, replace: rule.replace, regex: rule.isRegex, wholeDictation: rule.wholeDictation)
    }

    public private(set) var rules: [String: Entry]
    public private(set) var trackingSince: String?
    private var schemaVersion = currentSchemaVersion

    public init(rules: [String: Entry] = [:], trackingSince: String? = nil) {
        self.rules = rules
        self.trackingSince = trackingSince
    }

    public init(decoding data: Data) {
        self = Self.decoded(from: data) ?? ReplacementUsage()
    }

    public static func decoded(from data: Data) -> ReplacementUsage? {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.schemaVersion == currentSchemaVersion
        else { return nil }
        return decoded
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? encoder.encode(self)) ?? Data()
    }

    public static func key(origin: ReplacementOrigin, heard: String, isRegex: Bool) -> String {
        let scope = switch origin {
        case .global: "global"
        case .mode(let id): "mode:\(id)"
        }
        return isRegex ? "\(scope)|r|\(heard)" : "\(scope)|l|\(heard.lowercased())"
    }

    public static func key(for rule: ReplacementRule) -> String? {
        rule.origin.map { key(origin: $0, heard: rule.heard, isRegex: rule.isRegex) }
    }

    public static func configuredKeys(global: ReplacementsSet, modes: [Mode]) -> Set<String> {
        var keys = Set(global.rules.map { key(origin: .global, heard: $0.heard, isRegex: $0.regex) })
        for mode in modes {
            for rule in mode.replacements.rules {
                keys.insert(key(origin: .mode(mode.id), heard: rule.heard, isRegex: rule.regex))
            }
        }
        return keys
    }

    public func entry(for rule: ReplacementsSet.Rule, in origin: ReplacementOrigin) -> Entry? {
        rules[Self.key(origin: origin, heard: rule.heard, isRegex: rule.regex)]
    }

    public func recording(_ fired: [ReplacementRule], on day: String) -> ReplacementUsage {
        var next = self
        for key in Set(fired.compactMap(Self.key(for:))) {
            guard var entry = next.rules[key] ?? (trackingSince == nil ? Entry(count: 0, lastUsed: nil, since: nil) : nil)
            else { continue }
            entry.count += 1
            entry.lastUsed = day
            next.rules[key] = entry
        }
        return next
    }

    // A use is a dictation the rule actually affected; a match that left the text and the behaviour as they
    // were is not one. Problems are recorded either way: a dropped Return can leave every word the same.
    public func recording(effects: [ReplacementEffect], on day: String) -> ReplacementUsage {
        var merged: [String: ReplacementEffect] = [:]
        var order: [String] = []
        for effect in effects {
            guard let key = Self.key(for: effect.rule) else { continue }
            if var existing = merged[key] {
                existing.changedText = existing.changedText || effect.changedText
                existing.ownsWholeDictation = existing.ownsWholeDictation || effect.ownsWholeDictation
                existing.insideWord = existing.insideWord || effect.insideWord
                existing.returnOmitted = existing.returnOmitted || effect.returnOmitted
                merged[key] = existing
            } else {
                merged[key] = effect
                order.append(key)
            }
        }
        var next = recording(order.compactMap { merged[$0] }.filter(\.isMeaningful).map(\.rule), on: day)
        for key in order {
            guard let effect = merged[key], effect.isMeaningful || effect.insideWord || effect.returnOmitted else { continue }
            guard var entry = next.rules[key] ?? (trackingSince == nil ? Entry(count: 0, lastUsed: nil, since: nil) : nil)
            else { continue }
            let fingerprint = Self.fingerprint(of: effect.rule)
            if entry.health?.fingerprint != fingerprint {
                entry.health = Health(fingerprint: fingerprint, editedOn: entry.health == nil ? nil : day)
            }
            if effect.insideWord { entry.health?.insideWord += 1 }
            if effect.returnOmitted { entry.health?.returnOmitted += 1 }
            next.rules[key] = entry
        }
        return next
    }

    public func reconciled(with configured: Set<String>, on day: String) -> ReplacementUsage {
        var next = self
        next.trackingSince = trackingSince ?? day
        next.rules = rules.filter { configured.contains($0.key) }
        for key in configured where next.rules[key] == nil {
            next.rules[key] = Entry(count: 0, lastUsed: nil, since: trackingSince == nil ? nil : day)
        }
        return next
    }

    public func renamingMode(_ oldId: String, to newId: String) -> ReplacementUsage {
        let oldPrefix = "mode:\(oldId)|"
        var next = self
        for (key, entry) in rules where key.hasPrefix(oldPrefix) {
            next.rules[key] = nil
            next.rules["mode:\(newId)|" + key.dropFirst(oldPrefix.count)] = entry
        }
        return next
    }
}

public final class ReplacementUsageStore: @unchecked Sendable {
    public static let directoryName = "usage"
    public static let fileName = "replacements.json"

    public let file: URL
    private let queue = DispatchQueue(label: "com.keyscribe.replacement-usage", qos: .utility)
    private var loaded: ReplacementUsage?
    private var unsaved = false
    private var keepsUnreadableFile = false
    private let renameLock = NSLock()
    private var renames: [(old: String, new: String)] = []
    private let onChange: (@Sendable () -> Void)?
    private let onWriteFailure: (@Sendable (Error) -> Void)?
    private let onUnreadableFile: (@Sendable (URL) -> Void)?

    public var unreadableFile: URL { file.appendingPathExtension("unreadable") }

    public init(
        supportDir: URL, onChange: (@Sendable () -> Void)? = nil,
        onWriteFailure: (@Sendable (Error) -> Void)? = nil,
        onUnreadableFile: (@Sendable (URL) -> Void)? = nil
    ) {
        file = supportDir
            .appendingPathComponent(Self.directoryName, isDirectory: true)
            .appendingPathComponent(Self.fileName)
        self.onChange = onChange
        self.onWriteFailure = onWriteFailure
        self.onUnreadableFile = onUnreadableFile
    }

    public func snapshot() -> ReplacementUsage {
        queue.sync { current() }
    }

    public func renameEpoch() -> Int {
        renameLock.withLock { renames.count }
    }

    public func record(
        _ fired: [ReplacementRule], capturedAt epoch: Int? = nil, today: String = HistoryStore.todayString()
    ) {
        guard fired.contains(where: { $0.origin != nil }) else { return }
        let later = renameLock.withLock { renames.dropFirst(epoch ?? renames.count) }
        let current = fired.map { rule in
            guard case .mode(var id)? = rule.origin else { return rule }
            for rename in later where rename.old == id { id = rename.new }
            return rule.from(.mode(id))
        }
        mutate { $0.recording(current, on: today) }
    }

    public func record(
        effects: [ReplacementEffect], capturedAt epoch: Int? = nil, today: String = HistoryStore.todayString()
    ) {
        guard effects.contains(where: { $0.rule.origin != nil && ($0.isMeaningful || $0.insideWord || $0.returnOmitted) })
        else { return }
        let later = renameLock.withLock { renames.dropFirst(epoch ?? renames.count) }
        let current = effects.map { effect in
            guard case .mode(var id)? = effect.rule.origin else { return effect }
            for rename in later where rename.old == id { id = rename.new }
            var moved = effect
            moved.rule = effect.rule.from(.mode(id))
            return moved
        }
        mutate { $0.recording(effects: current, on: today) }
    }

    public func reconcile(keys: Set<String>, today: String = HistoryStore.todayString()) {
        mutate { $0.reconciled(with: keys, on: today) }
    }

    public func renameMode(_ oldId: String, to newId: String) {
        renameLock.withLock { renames.append((oldId, newId)) }
        mutate { $0.renamingMode(oldId, to: newId) }
    }

    public func flush() {
        queue.sync {}
    }

    private func mutate(_ change: @escaping @Sendable (ReplacementUsage) -> ReplacementUsage) {
        queue.async { [self] in apply(change) }
    }

    private func apply(_ change: (ReplacementUsage) -> ReplacementUsage) {
        let before = current()
        let after = change(before)
        guard after != before || unsaved else { return }
        loaded = after
        guard !keepsUnreadableFile else {
            onChange?()
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try after.encoded().write(to: file, options: .atomic)
            unsaved = false
        } catch {
            unsaved = true
            onWriteFailure?(error)
        }
        onChange?()
    }

    private func current() -> ReplacementUsage {
        if let loaded { return loaded }
        let read = readFile()
        loaded = read
        return read
    }

    private func readFile() -> ReplacementUsage {
        guard let data = try? Data(contentsOf: file) else { return ReplacementUsage() }
        if let usage = ReplacementUsage.decoded(from: data) { return usage }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: unreadableFile)
        do {
            try fileManager.moveItem(at: file, to: unreadableFile)
        } catch {
            keepsUnreadableFile = true
        }
        onUnreadableFile?(unreadableFile)
        return ReplacementUsage()
    }
}
