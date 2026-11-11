import CoreServices
import Foundation

final class FolderWatcher {
    private final class Box: Sendable {
        let onChange: @Sendable () -> Void
        init(_ onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    }

    let folders: [URL]
    private var stream: FSEventStreamRef?
    private let box: Box

    init?(folders: [URL], latency: TimeInterval = 0.5, onChange: @escaping @Sendable () -> Void) {
        guard !folders.isEmpty else { return nil }
        self.folders = folders
        box = Box(onChange)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, folders.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
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
