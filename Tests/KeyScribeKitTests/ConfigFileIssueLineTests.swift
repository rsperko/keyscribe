import Foundation
import Testing
@testable import KeyScribeKit

struct ConfigFileIssueLineTests {
    @Test func namesTheGivenPathOnceInPlaceOfTheFileName() {
        let issue = ConfigFileIssue.unreadable(
            "broken.toml", relativePath: "modes/broken.toml", error: .invalid("bad value"), recovery: .ignored)
        #expect(issue.line(naming: issue.relativePath) == "Couldn’t read modes/broken.toml — bad value — ignored until fixed")
        #expect(issue.oneLine == "Couldn’t read broken.toml — bad value — ignored until fixed")
    }
}
