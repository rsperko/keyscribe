import CoreServices
import Foundation

// Watches the config directory tree (FSEvents) and fires `onChange` — coalesced — whenever any
// file changes, so the in-memory ConfigCache can invalidate. Event-driven: no polling, no hot-path
// I/O. External edits (and, later, the Settings UI's writes) are picked up automatically.
final class ConfigWatcher {
    private final class Box: Sendable {
        let onChange: @Sendable () -> Void
        init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    }

    private var stream: FSEventStreamRef?
    private let box: Box

    init?(path: String, onChange: @escaping @Sendable () -> Void) {
        box = Box(onChange: onChange)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,  // coalescing latency (seconds)
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
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
