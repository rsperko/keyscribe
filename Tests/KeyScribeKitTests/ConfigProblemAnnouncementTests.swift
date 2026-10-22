import Testing
@testable import KeyScribeKit

struct ConfigProblemAnnouncementTests {
    @Test func announcesANewProblemOnceAndAgainOnlyAfterItChanges() {
        var announcement = ConfigProblemAnnouncement()
        #expect(announcement.next(current: []) == [])
        #expect(announcement.next(current: ["notes.toml — line 3"]) == ["notes.toml — line 3"])
        #expect(announcement.next(current: ["notes.toml — line 3"]) == [])
        #expect(announcement.next(current: ["notes.toml — line 9"]) == ["notes.toml — line 9"])
    }

    @Test func aFixedFileThatBreaksTheSameWayAgainIsAnnouncedAgain() {
        var announcement = ConfigProblemAnnouncement()
        _ = announcement.next(current: ["notes.toml — line 3"])
        #expect(announcement.next(current: []) == [])
        #expect(announcement.next(current: ["notes.toml — line 3"]) == ["notes.toml — line 3"])
    }

    @Test func fixingOneOfTwoProblemsDoesNotReannounceTheOther() {
        var announcement = ConfigProblemAnnouncement()
        _ = announcement.next(current: ["a.toml — line 1", "b.toml — line 2"])
        #expect(announcement.next(current: ["b.toml — line 2"]) == [])
    }

    @Test func onlyTheNewlyBrokenFileIsAnnounced() {
        var announcement = ConfigProblemAnnouncement()
        _ = announcement.next(current: ["a.toml — line 1"])
        #expect(announcement.next(current: ["a.toml — line 1", "b.toml — line 2"]) == ["b.toml — line 2"])
    }

    @Test func aProblemPresentAtLaunchIsNotAnnouncedOnlyRecorded() {
        var announcement = ConfigProblemAnnouncement(baseline: ["notes.toml — line 3"])
        #expect(announcement.next(current: ["notes.toml — line 3"]) == [])
    }
}
