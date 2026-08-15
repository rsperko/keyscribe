import Foundation
import Testing
@testable import KeyScribeKit

struct RequestOriginTests {
    private func pinned(_ s: String) -> RequestOrigin? { RequestOrigin(URL(string: s)) }
    private func allows(_ from: String, _ to: String) -> Bool {
        RequestOrigin.redirectIsPermitted(from: pinned(from), to: URL(string: to))
    }

    @Test func sameOriginRedirectsArePermitted() {
        #expect(allows("https://api.example.com/v1", "https://api.example.com/v2/chat"))
        #expect(allows("https://api.example.com/v1", "https://API.EXAMPLE.COM/v1"))
        #expect(allows("https://api.example.com:443/v1", "https://api.example.com/v1"))
        #expect(allows("http://127.0.0.1:11234/v1", "http://127.0.0.1:11234/v1/chat"))
    }

    @Test func differentHostSchemeOrPortIsRefused() {
        #expect(!allows("https://api.example.com/v1", "https://evil.example.com/v1"))
        #expect(!allows("https://api.example.com/v1", "https://api.example.com.evil.com/v1"))
        #expect(!allows("https://api.example.com/v1", "http://api.example.com/v1"))
        #expect(!allows("https://api.example.com/v1", "https://api.example.com:8443/v1"))
        #expect(!allows("http://127.0.0.1:11234/v1", "http://127.0.0.1:9999/v1"))
    }

    // `https://user@host/` reads as one server and resolves to another, so it never counts as a
    // comparable origin — on either side of the comparison.
    @Test func userinfoIsNeverAComparableOrigin() {
        #expect(RequestOrigin(URL(string: "https://evil@api.example.com/v1")) == nil)
        #expect(RequestOrigin(URL(string: "https://u:p@api.example.com/v1")) == nil)
        #expect(!allows("https://api.example.com/v1", "https://evil@api.example.com/v1"))
        #expect(!allows("https://evil@api.example.com/v1", "https://api.example.com/v1"))
    }

    @Test func unusableURLsAreRefused() {
        #expect(RequestOrigin(URL(string: "ftp://api.example.com/v1")) == nil)
        #expect(RequestOrigin(nil) == nil)
        #expect(!RequestOrigin.redirectIsPermitted(from: pinned("https://api.example.com/v1"), to: nil))
        #expect(!RequestOrigin.redirectIsPermitted(from: nil, to: URL(string: "https://api.example.com/v1")))
    }

    // The chain case: each hop is compared to the ORIGINAL pin, so a same-origin first hop cannot be
    // used to launder a cross-origin second hop.
    @Test func everyHopIsComparedToTheOriginalPinNotThePreviousHop() {
        let origin = pinned("https://api.example.com/v1")
        #expect(RequestOrigin.redirectIsPermitted(from: origin, to: URL(string: "https://api.example.com/hop1")))
        #expect(!RequestOrigin.redirectIsPermitted(from: origin, to: URL(string: "https://elsewhere.example.com/hop2")))
    }
}
