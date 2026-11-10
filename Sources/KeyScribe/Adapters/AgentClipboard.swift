import AppKit
import KeyScribeKit

@MainActor
final class AgentClipboard {
    nonisolated static let keptFor: TimeInterval = 24 * 60 * 60
    nonisolated static let pruneEvery: Duration = .seconds(60 * 60)
    nonisolated static let defaultFolder = folder(in: FileManager.default.temporaryDirectory)

    nonisolated static func folder(in temporary: URL) -> URL {
        temporary.appendingPathComponent("clipboard-for-agents", isDirectory: true)
    }

    @discardableResult
    nonisolated static func removeExpired(in folder: URL, now: Date = Date()) -> Int {
        let files = FileManager.default
        let entries = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var removed = 0
        for entry in entries {
            guard let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) > keptFor, (try? files.removeItem(at: entry)) != nil else { continue }
            removed += 1
        }
        return removed
    }
    private static let rememberedFiles = 16

    private let pasteboard: NSPasteboard
    let folder: URL
    private let now: () -> Date
    private let restorePending: @MainActor () -> Void
    private var saved: [(path: String, isImage: Bool)] = []
    private var lastSaved: (changeCount: Int, path: String, clip: ClipboardTokenizer.Clip)?
    private var missed = false

    init(
        pasteboard: NSPasteboard = .general, folder: URL = AgentClipboard.defaultFolder, now: @escaping () -> Date = Date.init,
        restorePending: @escaping @MainActor () -> Void = TextInserter.drainPendingRestoreNow
    ) {
        self.pasteboard = pasteboard
        self.folder = folder
        self.now = now
        self.restorePending = restorePending
    }

    func beginTake() { missed = false }

    func read() -> ClipboardTokenizer.Clip? {
        restorePending()
        let clip = contents()
        missed = clip == nil
        return clip
    }

    func images(in text: String) -> [String] {
        saved.filter { $0.isImage && text.contains($0.path) }.map(\.path)
    }

    func note(for text: String, attached: Bool) -> AgentOutput.ClipboardNote {
        let named = saved.filter { text.contains($0.path) }
        return AgentOutput.ClipboardNote(
            images: named.filter(\.isImage).count, files: named.filter { !$0.isImage }.count, attached: attached, missed: missed)
    }

    private func contents() -> ClipboardTokenizer.Clip? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return .files(urls.map(\.path))
        }
        if let last = lastSaved, last.changeCount == pasteboard.changeCount, FileManager.default.fileExists(atPath: last.path) {
            return last.clip
        }
        let text = pasteboard.string(forType: .string)
        if let text, !text.isEmpty, !Self.isAddress(text) { return ClipboardTokenizer.Clip(text: text) }
        if let png = imageAsPNG(), let path = save(png, as: "png") { return kept(path, isImage: true) }
        if let text, !text.isEmpty { return ClipboardTokenizer.Clip(text: text) }
        if let pdf = pasteboard.data(forType: .pdf), let path = save(pdf, as: "pdf") { return kept(path, isImage: false) }
        return TextInserter.attributedText(on: pasteboard).map { ClipboardTokenizer.Clip(text: $0) }
    }

    private static func isAddress(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let scheme = URL(string: trimmed)?.scheme?.lowercased() else { return false }
        return ["http", "https", "data", "file"].contains(scheme)
    }

    private func kept(_ path: String, isImage: Bool) -> ClipboardTokenizer.Clip {
        let clip = ClipboardTokenizer.Clip.files([path])
        lastSaved = (pasteboard.changeCount, path, clip)
        saved.append((path, isImage))
        if saved.count > Self.rememberedFiles { saved.removeFirst(saved.count - Self.rememberedFiles) }
        return clip
    }

    private func imageAsPNG() -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        let types: [NSPasteboard.PasteboardType] = [.tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]
        guard let data = types.lazy.compactMap({ self.pasteboard.data(forType: $0) }).first,
              let image = NSBitmapImageRep(data: data) else { return nil }
        return image.representation(using: .png, properties: [:])
    }

    private func save(_ data: Data, as fileExtension: String) -> String? {
        let files = FileManager.default
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            Self.removeExpired(in: folder, now: now())
            let stamp = Int(now().timeIntervalSince1970)
            let url = folder.appendingPathComponent("clipboard-\(stamp)-\(UUID().uuidString.prefix(8).lowercased()).\(fileExtension)")
            try data.write(to: url, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600, .modificationDate: now()], ofItemAtPath: url.path)
            return url.path
        } catch {
            Log.agents.error("couldn't save the clipboard for a coding agent: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

}
