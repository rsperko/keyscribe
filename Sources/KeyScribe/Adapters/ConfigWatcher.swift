import CoreServices
import Foundation
import KeyScribeKit

// Watches the config directory tree (FSEvents) and fires `onChange` — coalesced — whenever a
// CONFIG file changes, so the in-memory ConfigCache can invalidate. Event-driven: no polling, no
// hot-path I/O. External edits (and, later, the Settings UI's writes) are picked up automatically.
// The callback filters the delivered event paths through ConfigWatchFilter so writes under
// `history/` (every dictation) and `lkg/` (normal saves) do NOT trigger a spurious full reload.
final class ConfigWatcher {
    private final class Box: Sendable {
        let onChange: @Sendable () -> Void
        let supportDir: String
        init(supportDir: String, onChange: @escaping @Sendable () -> Void) {
            self.supportDir = supportDir
            self.onChange = onChange
        }
    }

    private var stream: FSEventStreamRef?
    private let box: Box

    init?(path: String, onChange: @escaping @Sendable () -> Void) {
        box = Box(supportDir: path, onChange: onChange)
        // kFSEventStreamCreateFlagUseCFTypes makes `eventPaths` a CFArray of CFString we can read;
        // without it the paths are delivered as a raw C string array and cannot be filtered.
        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            guard ConfigWatchFilter.batchIsConfigRelevant(changedPaths: paths, supportDir: box.supportDir)
            else { return }
            box.onChange()
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,  // coalescing latency (seconds)
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes))
        else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
