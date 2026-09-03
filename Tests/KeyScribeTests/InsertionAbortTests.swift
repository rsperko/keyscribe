import AppKit
import Foundation
import Testing

@testable import KeyScribeApp

// `insertViaPaste` suspends while it settles the clipboard and `insertViaTyping` suspends between every
// character, so a capture loss arriving after the caller's gate still has chances to land mid-insert.
// Typing is the case that matters: it is not a single undo.
//
// Typing goes through `typedCharacterSink` — the real path posts to `.cghidEventTap`, which would type into
// whatever app the developer running the suite has focused.
@MainActor
struct InsertionAbortTests {
    private func typing(
        _ text: String, abort: @escaping @Sendable () -> Bool
    ) async -> (acted: Bool, typed: String) {
        let recorder = Recorder()
        let acted = await TextInserter.$shouldAbortInsertion.withValue(abort) {
            await TextInserter.$typedCharacterSink.withValue({ recorder.append($0) }) {
                await TextInserter.insertViaTyping(text)
            }
        }
        return (acted, recorder.text)
    }

    @Test func typingStopsImmediatelyWhenTheCaptureIsAlreadyLost() async {
        let (acted, typed) = await typing("hello world", abort: { true })

        #expect(acted == false)
        #expect(typed.isEmpty)
    }

    // Proves the check runs per character rather than once up front.
    @Test func typingStopsPartwayWhenTheLossArrivesMidInsert() async {
        let calls = Counter()
        let (acted, typed) = await typing("abcdefghijklmnop", abort: { calls.bump() > 3 })

        #expect(acted)
        #expect(typed == "abc")
    }

    @Test func typingRunsToCompletionWhenNothingAborts() async {
        let (acted, typed) = await typing("ok", abort: { false })

        #expect(acted)
        #expect(typed == "ok")
    }

    // Absent a hook, Paste Last and the correction panel are unaffected.
    @Test func noHookMeansNoAbort() async {
        let recorder = Recorder()
        let acted = await TextInserter.$typedCharacterSink.withValue({ recorder.append($0) }) {
            await TextInserter.insertViaTyping("xy")
        }

        #expect(acted)
        #expect(recorder.text == "xy")
    }

    // Asserted WITHOUT draining: the restore must already have happened, not be deferred behind the
    // post-paste restore window, which exists to let a target consume a ⌘V that here never happened.
    @Test func anAbortedPasteRestoresTheClipboardImmediately() async {
        let pb = NSPasteboard(name: NSPasteboard.Name("keyscribe-abort-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        var acted = true
        await TextInserter.$shouldAbortInsertion.withValue({ true }) {
            acted = await TextInserter.insertViaPaste("truncated dictation", awaitSettle: false, on: pb)
        }

        #expect(acted == false)
        #expect(pb.string(forType: .string) == "USER_ORIGINAL")
    }

    // Set on a background thread and observed with no actor hop — the property actuation relies on.
    @Test func lossIsRecordedSynchronouslyAcrossThreads() async {
        let flag = DictationController.CaptureLossFlag()
        #expect(flag.isLost == false)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                flag.markLost()
                c.resume()
            }
        }
        #expect(flag.isLost)
    }

    // Fidelity guard for the seam itself: the sink replaces the event post but must not skip the loop's
    // per-character suspension. Only a real suspension lets this separately-scheduled task run before typing
    // finishes, so if the seam short-circuited the sleep the whole string would be typed.
    @Test func theSinkPathStillSuspendsBetweenCharacters() async {
        let stop = Flag()
        Task { @MainActor in stop.set() }
        let (_, typed) = await typing("abcdefghij", abort: { stop.isSet })

        #expect(typed.count < 10)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var chars: [Character] = []
        var text: String { lock.withLock { String(chars) } }
        func append(_ c: Character) { lock.withLock { chars.append(c) } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() -> Int { lock.withLock { count += 1; return count } }
    }
}
