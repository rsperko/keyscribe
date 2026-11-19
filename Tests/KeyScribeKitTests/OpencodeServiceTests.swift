import Foundation
import KeyScribeKit
import Testing

struct OpencodeServiceTests {
    @Test func aRegisteredServiceGivesItsAddressPasswordAndProcess() throws {
        let json = #"{"id":"b961","version":"2.3.2","url":"http://127.0.0.1:49374","pid":55174,"password":"secret"}"#
        let service = try #require(OpencodeService.parse(Data(json.utf8)))
        #expect(service.url == URL(string: "http://127.0.0.1:49374"))
        #expect(service.password == "secret")
        #expect(service.pid == 55174)
        #expect(service.version == "2.3.2")
    }

    @Test func aServiceWithoutAPasswordIsStillReachable() throws {
        let service = try #require(OpencodeService.parse(Data(#"{"url":"http://127.0.0.1:4096","pid":1}"#.utf8)))
        #expect(service.password == nil)
        #expect(service.authorization == nil)
    }

    @Test func thePasswordIsSentAsBasicAuthForTheOpencodeUser() throws {
        let service = try #require(OpencodeService.parse(Data(#"{"url":"http://127.0.0.1:1","pid":1,"password":"pw"}"#.utf8)))
        #expect(service.authorization == "Basic " + Data("opencode:pw".utf8).base64EncodedString())
    }

    @Test func aServiceOffThisMachineIsNeverTrusted() {
        #expect(OpencodeService.parse(Data(#"{"url":"http://example.com:4096","pid":1,"password":"pw"}"#.utf8)) == nil)
        #expect(OpencodeService.parse(Data(#"{"url":"http://10.0.0.5:4096","pid":1}"#.utf8)) == nil)
        #expect(OpencodeService.parse(Data(#"{"url":"http://localhost:4096","pid":1}"#.utf8)) != nil)
        #expect(OpencodeService.parse(Data(#"{"url":"http://[::1]:4096","pid":1}"#.utf8)) != nil)
    }

    @Test func aBrokenOrIncompleteRegistrationIsNoService() {
        #expect(OpencodeService.parse(Data("not json".utf8)) == nil)
        #expect(OpencodeService.parse(Data(#"{"pid":1}"#.utf8)) == nil)
        #expect(OpencodeService.parse(Data(#"{"url":"http://127.0.0.1:1"}"#.utf8)) == nil)
        #expect(OpencodeService.parse(Data(#"{"url":"file:///tmp/x","pid":1}"#.utf8)) == nil)
    }

    @Test func theRegistrationLivesInTheStateFolderUnlessXDGMovesIt() {
        #expect(OpencodeService.registration(home: "/Users/a", environment: [:]).path == "/Users/a/.local/state/opencode/service.json")
        #expect(
            OpencodeService.registration(home: "/Users/a", environment: ["XDG_STATE_HOME": "/s"]).path == "/s/opencode/service.json")
        #expect(OpencodeService.registration(home: "/Users/a", environment: ["XDG_STATE_HOME": ""]).path
            == "/Users/a/.local/state/opencode/service.json")
    }
}
