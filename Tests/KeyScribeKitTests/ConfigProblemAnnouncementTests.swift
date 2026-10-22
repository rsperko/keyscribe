import Testing
@testable import KeyScribeKit

struct ConfigProblemAnnouncementTests {
    private func unread(_ file: String, _ key: String) -> ConfigFileIssue {
        .unusedKeys(file, [UnknownConfigKey(path: key, suggestion: nil)])
    }

    @Test func announcesANewProblemOnceAndAgainOnlyAfterItChanges() {
        var announcement = ConfigProblemAnnouncement()
        #expect(announcement.next(current: []) == [])
        #expect(announcement.next(current: [unread("notes.toml", "a")]) == [unread("notes.toml", "a")])
        #expect(announcement.next(current: [unread("notes.toml", "a")]) == [])
        #expect(announcement.next(current: [unread("notes.toml", "b")]) == [unread("notes.toml", "b")])
    }

    @Test func aFixedFileThatBreaksTheSameWayAgainIsAnnouncedAgain() {
        var announcement = ConfigProblemAnnouncement()
        _ = announcement.next(current: [unread("notes.toml", "a")])
        #expect(announcement.next(current: []) == [])
        #expect(announcement.next(current: [unread("notes.toml", "a")]) == [unread("notes.toml", "a")])
    }

    @Test func fixingOneOfTwoProblemsDoesNotReannounceTheOther() {
        var announcement = ConfigProblemAnnouncement()
        _ = announcement.next(current: [unread("a.toml", "x"), unread("b.toml", "y")])
        #expect(announcement.next(current: [unread("b.toml", "y")]) == [])
    }

    @Test func onlyTheNewlyBrokenFileIsAnnounced() {
        var announcement = ConfigProblemAnnouncement()
        _ = announcement.next(current: [unread("a.toml", "x")])
        #expect(announcement.next(current: [unread("a.toml", "x"), unread("b.toml", "y")]) == [unread("b.toml", "y")])
    }

    @Test func aProblemPresentAtLaunchIsNotAnnouncedOnlyRecorded() {
        var announcement = ConfigProblemAnnouncement(baseline: [unread("notes.toml", "a")])
        #expect(announcement.next(current: [unread("notes.toml", "a")]) == [])
    }
}
