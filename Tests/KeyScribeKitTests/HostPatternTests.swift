import Foundation
import Testing
@testable import KeyScribeKit

struct HostPatternTests {
    private func matches(_ pattern: String, _ url: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }

    @Test func acceptsHostExactAndSubdomainURLs() throws {
        let p = try #require(HostPattern.regex(forDomain: "github.com"))
        #expect(matches(p, "https://github.com/foo"))
        #expect(matches(p, "https://gist.github.com/x"))
        #expect(matches(p, "http://github.com"))
        #expect(matches(p, "https://github.com:443/foo"))
    }

    @Test func rejectsLookalikeAndSubstringHosts() throws {
        let p = try #require(HostPattern.regex(forDomain: "github.com"))
        #expect(!matches(p, "https://notgithub.com/"))
        #expect(!matches(p, "https://github.com.evil.example/"))
        #expect(!matches(p, "https://example.com/github.com"))
    }

    @Test func caseInsensitiveHost() throws {
        let p = try #require(HostPattern.regex(forDomain: "GitHub.com"))
        #expect(matches(p, "https://GITHUB.COM/foo"))
    }

    // A domain with regex metacharacters is escaped, not interpreted, so a `.` matches only a literal dot.
    @Test func domainMetacharactersAreEscaped() throws {
        let p = try #require(HostPattern.regex(forDomain: "a.b.com"))
        #expect(matches(p, "https://a.b.com/x"))
        #expect(!matches(p, "https://axbxcom/x"))     // the dots are literal, not wildcards
    }

    @Test func rejectsNonDomainInput() {
        #expect(HostPattern.regex(forDomain: "") == nil)
        #expect(HostPattern.regex(forDomain: "   ") == nil)
        #expect(HostPattern.regex(forDomain: "localhost") == nil)      // no dot
        #expect(HostPattern.regex(forDomain: "github.com/foo") == nil) // contains a slash (a path, not a domain)
    }

    // Shapes the old `contains(".")` guard let through — each escaped into a regex that can never match a
    // real URL host, yet still displayed as a valid rule. They must be rejected outright.
    @Test func rejectsDomainsThatCanNeverMatchAHost() {
        #expect(HostPattern.regex(forDomain: "*.github.com") == nil) // wildcard label
        #expect(HostPattern.regex(forDomain: ".github.com") == nil)  // leading dot / empty label
        #expect(HostPattern.regex(forDomain: "github.com.") == nil)  // trailing dot / empty label
        #expect(HostPattern.regex(forDomain: "git hub.com") == nil)  // space in a label
        #expect(HostPattern.regex(forDomain: "-github.com") == nil)  // leading hyphen
        #expect(HostPattern.regex(forDomain: "github-.com") == nil)  // trailing hyphen
        #expect(HostPattern.regex(forDomain: "foo..bar.com") == nil) // empty middle label
    }

    // Pin the generated pattern to the verified full-URL matching context (ModeResolver.regexFound matches
    // unanchored over the whole URL string, so the `^` anchor is load-bearing).
    @Test func generatedPatternIsHostAnchoredFromTheStart() throws {
        let p = try #require(HostPattern.regex(forDomain: "github.com"))
        #expect(p.hasPrefix("(?i)^"))
        #expect(p.contains("github\\.com"))
    }

    @Test func recoversDomainRoundTrip() throws {
        for d in ["github.com", "gist.github.com", "a.b.com", "example.co.uk"] {
            let p = try #require(HostPattern.regex(forDomain: d))
            #expect(HostPattern.domain(fromRegex: p) == d)
        }
    }

    @Test func recoveredDomainIsLowercased() throws {
        let p = try #require(HostPattern.regex(forDomain: "GitHub.com"))
        #expect(HostPattern.domain(fromRegex: p) == "github.com")
    }

    @Test func handWrittenPatternIsNotRecognizedAsADomain() {
        #expect(HostPattern.domain(fromRegex: "github\\.com") == nil)
        #expect(HostPattern.domain(fromRegex: "(?i)pull request") == nil)
        #expect(HostPattern.domain(fromRegex: "") == nil)
        // Right shell, but the middle isn't what our escaper would emit (a bare unescaped dot).
        #expect(HostPattern.domain(fromRegex: "(?i)^[a-z][a-z0-9+.-]*://([^/?#]*\\.)?github.com([/:?#]|$)") == nil)
    }

    @Test func recoversDomainContainingMetacharacters() throws {
        let p = try #require(HostPattern.regex(forDomain: "a.b.com"))
        #expect(HostPattern.domain(fromRegex: p) == "a.b.com")
    }
}
