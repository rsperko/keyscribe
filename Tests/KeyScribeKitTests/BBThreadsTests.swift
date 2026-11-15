import Foundation
import KeyScribeKit
import Testing

struct BBThreadsTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    private func thread(
        id: String = "thr_a1", status: String = "idle", title: String? = "Fix the build", path: String? = "/src/app",
        visibility: String = "visible", archived: String = "null", deleted: String = "null", pending: Bool = false, parent: String? = nil
    ) -> String {
        """
        {"id":"\(id)","providerId":"pi","title":\(title.map { "\"\($0)\"" } ?? "null"),"titleFallback":"first prompt",
         "status":"\(status)","visibility":"\(visibility)","archivedAt":\(archived),"deletedAt":\(deleted),
         "parentThreadId":\(parent.map { "\"\($0)\"" } ?? "null"),"environmentPath":\(path.map { "\"\($0)\"" } ?? "null"),"hasPendingInteraction":\(pending),
         "queuedWork":"none","runtime":{"displayStatus":"\(status)"}}
        """
    }

    @Test func anEmptyListIsNoThreads() {
        #expect(BBThreads.parse(data("[]")) == [])
    }

    @Test func aThreadKeepsTheTitleBbShowsAndOnlyWithoutOneTheOpeningWordsBbShowsInstead() {
        #expect(BBThreads.parse(data("[\(thread(title: nil))]")) == [BBThreads.Thread(id: "thr_a1", folder: "/src/app", state: .idle, shownInstead: "first prompt")])
        #expect(BBThreads.parse(data("[\(thread(title: "  "))]")) == [BBThreads.Thread(id: "thr_a1", folder: "/src/app", state: .idle, shownInstead: "first prompt")])
        #expect(
            BBThreads.parse(data("[\(thread(title: " Fix the build "))]"))
                == [BBThreads.Thread(id: "thr_a1", folder: "/src/app", state: .idle, title: "Fix the build")])
    }

    @Test func statusesMapToLiveStatesAndAnUnknownStatusIsNotWorking() {
        let json = "[" + [
            thread(id: "thr_1", status: "active"), thread(id: "thr_2", status: "starting"), thread(id: "thr_3", status: "idle"),
            thread(id: "thr_4", status: "something-new"), thread(id: "thr_5", status: "active", pending: true),
        ].joined(separator: ",") + "]"
        #expect(BBThreads.parse(data(json))?.map(\.state) == [.working, .working, .idle, .idle, .waitingQuestion])
    }

    @Test func archivedDeletedAndHiddenThreadsAreNotListed() {
        let json = "[" + [
            thread(id: "thr_1", archived: "1794629582057"), thread(id: "thr_2", deleted: "1794629582057"),
            thread(id: "thr_3", visibility: "hidden"), thread(id: "thr_4"),
        ].joined(separator: ",") + "]"
        #expect(BBThreads.parse(data(json))?.map(\.id) == ["thr_4"])
    }

    @Test func aThreadNestedUnderAnotherInBBsSidebarIsStillListed() {
        let json = "[" + [thread(id: "thr_1"), thread(id: "thr_2", parent: "thr_1")].joined(separator: ",") + "]"
        #expect(BBThreads.parse(data(json))?.map(\.id) == ["thr_1", "thr_2"])
    }

    @Test func aThreadKeepsBBsCreationTimeAsItsStart() {
        let json = #"[{"id":"thr_a1","status":"idle","createdAt":1794629582057},{"id":"thr_a2","status":"idle","createdAt":1.5}]"#
        #expect(BBThreads.parse(data(json))?.map(\.createdAt) == [1794629582057, nil])
    }

    @Test func aThreadWithoutAFolderIsListedWithAnEmptyFolder() {
        #expect(BBThreads.parse(data("[\(thread(path: nil))]"))?.first?.folder == "")
    }

    @Test func anErrorEnvelopeOrMalformedOutputIsUnreadable() {
        #expect(BBThreads.parse(data(#"{"ok":false,"error":{"code":"http_500","message":"HTTP 500"}}"#)) == nil)
        #expect(BBThreads.parse(data("not json")) == nil)
        #expect(BBThreads.parse(data(#"[{"title":"no id"}]"#)) == nil)
    }

    @Test func aThreadIdOutsideBBsShapeIsDropped() {
        let json = "[" + [thread(id: "thr_ok9"), thread(id: "--json"), thread(id: "thr_a b"), thread(id: ""), thread(id: "thr_é1"), thread(id: "thr_٣")]
            .joined(separator: ",") + "]"
        #expect(BBThreads.parse(data(json))?.map(\.id) == ["thr_ok9"])
    }

    @Test func deliveryReadsSentAndQueuedAndNothingElseAsSettled() {
        #expect(BBThreads.delivery(status: 0, stdout: data(#"{"threadId":"thr_1","ok":true,"delivery":"sent","mode":"queue"}"#)) == .sent)
        #expect(BBThreads.delivery(status: 0, stdout: data(#"{"threadId":"thr_1","ok":true,"delivery":"queued","mode":"queue"}"#)) == .queued)
        #expect(BBThreads.delivery(status: 0, stdout: data(#"{"threadId":"thr_1","ok":true,"delivery":"sent","mode":"steer"}"#)) == .sent)
        #expect(BBThreads.delivery(status: 0, stdout: data(#"{"threadId":"thr_1","ok":true,"delivery":"scheduled"}"#)) == .unclear)
        #expect(BBThreads.delivery(status: 0, stdout: data(#"{"threadId":"thr_1","ok":true}"#)) == .unclear)
        #expect(BBThreads.delivery(status: 0, stdout: data("garbage")) == .unclear)
        #expect(BBThreads.delivery(status: 1, stdout: data("")) == .unclear)
    }

    @Test func deliveryReadsAnErrorEnvelopeAsARefusalInPlainWordsKeepingBBsOwnForTheLog() {
        let missing = #"{"ok":false,"error":{"code":"thread_not_found","message":"HTTP 404: Thread not found"}}"#
        #expect(BBThreads.delivery(status: 1, stdout: data(missing))
            == .refused("bb no longer has this thread.", code: "thread_not_found", message: "HTTP 404: Thread not found"))
        let down = #"{"ok":false,"error":{"code":"error","message":"Cannot connect to BB server."}}"#
        #expect(BBThreads.delivery(status: 1, stdout: data(down)) == .refused("bb did not take it.", code: "error", message: "Cannot connect to BB server."))
        #expect(BBThreads.delivery(status: 1, stdout: data(#"{"ok":false,"error":{"code":"error"}}"#)) == .refused("bb did not take it.", code: "error", message: nil))
        #expect(BBThreads.delivery(status: 1, stdout: data(#"{"ok":false,"error":{"message":"odd"}}"#)) == .refused("bb did not take it.", code: nil, message: "odd"))
    }

    @Test func aSuccessfulAnswerWithAFailingExitIsUnclear() {
        #expect(BBThreads.delivery(status: 1, stdout: data(#"{"ok":true,"delivery":"sent"}"#)) == .unclear)
    }

    @Test func anAgentBBStartedNamesItsThreadOnlyWhenItsStorageIsThatThreadsFolderInThisBB() {
        let environment = ["BB_THREAD_ID": "thr_9e", "BB_THREAD_STORAGE": "/Users/a/.bb/thread-storage/thr_9e"]
        #expect(BBThreads.thread(in: environment, instance: "/Users/a/.bb") == "thr_9e")
        #expect(BBThreads.thread(in: environment, instance: "/Users/a/.bb/") == "thr_9e")
        #expect(BBThreads.thread(in: environment, instance: "/Users/b/.bb") == nil)
        #expect(BBThreads.thread(in: ["BB_THREAD_ID": "thr_9e"], instance: "/Users/a/.bb") == nil)
        #expect(BBThreads.thread(in: ["BB_THREAD_STORAGE": "/Users/a/.bb/thread-storage/thr_9e"], instance: "/Users/a/.bb") == nil)
        let other = ["BB_THREAD_ID": "thr_9e", "BB_THREAD_STORAGE": "/Users/a/.bb/thread-storage/thr_1"]
        #expect(BBThreads.thread(in: other, instance: "/Users/a/.bb") == nil)
        let odd = ["BB_THREAD_ID": "--split", "BB_THREAD_STORAGE": "/Users/a/.bb/thread-storage/--split"]
        #expect(BBThreads.thread(in: odd, instance: "/Users/a/.bb") == nil)
        let climbing = ["BB_THREAD_ID": "thr_9e", "BB_THREAD_STORAGE": "/Users/a/x/../.bb/thread-storage/thr_9e"]
        #expect(BBThreads.thread(in: climbing, instance: "/Users/a/.bb") == nil)
    }

    @Test func openCountsTheWindowsBBReached() {
        #expect(BBThreads.openedWindows(status: 0, stdout: data(#"{"threadId":"thr_1","split":"replace","file":null,"delivered":2,"inputPath":null}"#)) == 2)
        #expect(BBThreads.openedWindows(status: 0, stdout: data(#"{"threadId":"thr_1","delivered":0}"#)) == 0)
        #expect(BBThreads.openedWindows(status: 0, stdout: data(#"{"threadId":"thr_1"}"#)) == nil)
        #expect(BBThreads.openedWindows(status: 1, stdout: data(#"{"ok":false,"error":{"code":"thread_not_found","message":"x"}}"#)) == nil)
    }
}
