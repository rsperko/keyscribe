import AppKit
import Testing
@testable import KeyScribeApp

private final class BundleMarker {}

final class SlowPasteboardSource: @unchecked Sendable {
    static let slowType = NSPasteboard.PasteboardType("com.keyscribe.test.slow")
    private let process = Process()
    private let lock = NSLock()
    private var lines: [String] = []

    @MainActor init(on pb: NSPasteboard, delay: Double, slowText: Bool = false, textOnly: Bool = false) async throws {
        let eager = textOnly ? "" : "item.setStringForType($('eager'), 'com.keyscribe.test.eager');"
        let text = slowText
            ? "\(eager) item.setDataProviderForTypes(provider, $(['public.utf8-plain-text']));"
            : "item.setStringForType($('plain fallback'), 'public.utf8-plain-text'); item.setDataProviderForTypes(provider, $(['com.keyscribe.test.slow']));"
        let script = """
        ObjC.import('AppKit');
        function say(line) { $.NSFileHandle.fileHandleWithStandardOutput.writeData($(line + '\\n').dataUsingEncoding(4)); }
        function run(argv) {
          ObjC.registerSubclass({
            name: 'KeyScribeTestSlowProvider', protocols: ['NSPasteboardItemDataProvider'],
            methods: { 'pasteboard:item:provideDataForType:': { types: ['void', ['id', 'id', 'id']],
              implementation: function (pb, item, type) {
                say('rendering');
                $.NSThread.sleepForTimeInterval(\(delay));
                item.setDataForType($('slow bytes').dataUsingEncoding(4), type);
                say('rendered');
              } } }
          });
          const pb = $.NSPasteboard.pasteboardWithName(argv[0]);
          pb.clearContents;
          const item = $.NSPasteboardItem.alloc.init;
          const provider = $.KeyScribeTestSlowProvider.alloc.init;
          \(text)
          pb.writeObjects($([item]));
          say('ready');
          $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(60));
        }
        """
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script, pb.name.rawValue]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let reader = out.fileHandleForReading
        DispatchQueue.global().async { [self] in
            while case let chunk = reader.availableData, !chunk.isEmpty {
                let said = String(decoding: chunk, as: UTF8.self).split(separator: "\n").map(String.init)
                lock.withLock { lines += said }
            }
        }
        try await until("ready")
    }

    func said(_ line: String) -> Bool { lock.withLock { lines.contains(line) } }

    func until(_ line: String) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !said(line) {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func stop() { process.terminate() }
}

@MainActor
struct PasteboardReaderTests {
    static let helper = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("KeyScribe")

    private func read(_ pb: NSPasteboard, within seconds: Double = 5) async -> TextInserter.PasteboardSnapshot? {
        await TextInserter.PasteboardSnapshot.read(
            from: pb, deadline: .now.advanced(by: .seconds(seconds)), helper: Self.helper)
    }

    private func pasteboard(_ fill: (NSPasteboard) -> Void = { $0.clearContents() }) -> NSPasteboard {
        let pb = NSPasteboard.withUniqueName()
        fill(pb)
        return pb
    }

    private func restored(_ snapshot: TextInserter.PasteboardSnapshot?, to pb: NSPasteboard) {
        pb.clearContents()
        pb.setString("scratch", forType: .string)
        snapshot?.restore(to: pb)
    }

    @Test func theHelperIsBuiltBesideTheTests() {
        #expect(FileManager.default.isExecutableFile(atPath: Self.helper.path))
    }

    @Test func aRichClipboardIsReadInTheChildWithEveryFlavor() async {
        let binaryType = NSPasteboard.PasteboardType("com.keyscribe.test.binary")
        let pb = pasteboard {
            let item = NSPasteboardItem()
            item.setString("the user's note", forType: .string)
            item.setData(Data([0xDE, 0xAD, 0xBE, 0xEF]), forType: binaryType)
            $0.clearContents()
            $0.writeObjects([item])
        }
        defer { pb.releaseGlobally() }
        let before = pb.changeCount

        let snapshot = await read(pb)
        restored(snapshot, to: pb)

        #expect(snapshot?.readInChild == true)
        #expect(snapshot?.changeCount == before)
        #expect(pb.string(forType: .string) == "the user's note")
        #expect(pb.data(forType: binaryType) == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test func aSlowPlainTextOnlyClipboardIsReadInTheChildToo() async throws {
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let source = try await SlowPasteboardSource(on: pb, delay: 30, slowText: true, textOnly: true)
        defer { source.stop() }

        let snapshot = await read(pb, within: 8)

        #expect(snapshot == nil)
    }

    @Test func anOversizedClipboardKeepsItsPlainText() async {
        let largeType = NSPasteboard.PasteboardType("com.keyscribe.test.large")
        let pb = pasteboard {
            let item = NSPasteboardItem()
            item.setString("plain fallback", forType: .string)
            item.setData(Data(repeating: 7, count: 9 * 1024 * 1024), forType: largeType)
            $0.clearContents()
            $0.writeObjects([item])
        }
        defer { pb.releaseGlobally() }

        let snapshot = await read(pb)
        restored(snapshot, to: pb)

        #expect(snapshot?.readInChild == true)
        #expect(pb.string(forType: .string) == "plain fallback")
        #expect(pb.data(forType: largeType) == nil)
    }

    @Test func aSlowImageInAnotherAppIsRenderedForTheChild() async throws {
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let source = try await SlowPasteboardSource(on: pb, delay: 1)
        defer { source.stop() }

        let snapshot = await read(pb, within: 30)
        restored(snapshot, to: pb)

        #expect(snapshot?.readInChild == true)
        #expect(pb.data(forType: SlowPasteboardSource.slowType) == Data("slow bytes".utf8))
        #expect(pb.string(forType: .string) == "plain fallback")
    }

    @Test func aSourceSlowerThanTheDeadlineKeepsOnlyItsPlainText() async throws {
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let source = try await SlowPasteboardSource(on: pb, delay: 30)
        defer { source.stop() }

        let started = ContinuousClock.now
        let snapshot = await read(pb, within: 8)
        let elapsed = ContinuousClock.now - started
        restored(snapshot, to: pb)

        #expect(elapsed < .seconds(25))
        #expect(pb.string(forType: .string) == "plain fallback")
        #expect(pb.data(forType: SlowPasteboardSource.slowType) == nil)
    }

    @Test func aSlowPlainTextGivesNothingToRestore() async throws {
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let source = try await SlowPasteboardSource(on: pb, delay: 30, slowText: true)
        defer { source.stop() }

        let started = ContinuousClock.now
        let snapshot = await read(pb, within: 8)

        #expect(snapshot == nil)
        #expect(ContinuousClock.now - started < .seconds(25))
    }

    @Test func aSpentDeadlineReadsNothing() async {
        let pb = pasteboard {
            $0.clearContents()
            $0.setString("keepme", forType: .string)
        }
        defer { pb.releaseGlobally() }

        let snapshot = await TextInserter.PasteboardSnapshot.read(from: pb, deadline: .now, helper: Self.helper)

        #expect(snapshot == nil)
    }

    @Test func aHelperThatCannotStartReadsInThisProcess() async {
        let binaryType = NSPasteboard.PasteboardType("com.keyscribe.test.binary")
        let pb = pasteboard {
            let item = NSPasteboardItem()
            item.setData(Data([1, 2]), forType: binaryType)
            $0.clearContents()
            $0.writeObjects([item])
        }
        defer { pb.releaseGlobally() }

        let snapshot = await TextInserter.PasteboardSnapshot.read(
            from: pb, deadline: .now.advanced(by: .seconds(30)), helper: URL(fileURLWithPath: "/nonexistent/KeyScribe"))
        restored(snapshot, to: pb)

        #expect(snapshot?.readInChild == false)
        #expect(pb.data(forType: binaryType) == Data([1, 2]))
    }
}
