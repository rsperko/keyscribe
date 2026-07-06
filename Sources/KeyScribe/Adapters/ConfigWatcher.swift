import CoreServices
import Foundation
import KeyScribeKit

// Watches the config tree (FSEvents) and fires `onChange` — coalesced — whenever a CONFIG file changes, so
// ConfigCache can invalidate. Event-driven, no polling. The callback filters event paths through
// ConfigWatchFilter so writes under `history/` (every dictation) and `lkg/` (normal saves) do NOT trigger
// a spurious full reload.
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
        // kFSEventStreamCreateFlagUseCFTypes makes `eventPaths` a readable CFArray of CFString; without it
        // they arrive as a raw C string array we can't filter.
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
