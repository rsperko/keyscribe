import Foundation

// The configured endpoint is a privacy boundary: a rewrite body carries the prompt and the tokenized
// transcript, and PRIVACY.md promises it goes only to the endpoint that mode is wired to. URLSession
// follows redirects by default, and 307/308 preserve the method AND the body — so without a policy a
// redirect can replay that body to another host. This is the comparison behind that policy.
//
// Pure and standalone so redirect rules are unit-testable: proving an HTTPS→HTTP refusal end to end
// would otherwise need local TLS trust machinery.
public struct RequestOrigin: Equatable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int

    // nil for a URL with no scheme/host, or one carrying userinfo — `https://evil@host/` reads as a
    // different server than it resolves to, so it is never treated as a comparable origin.
    public init?(_ url: URL?) {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty,
              url.user == nil, url.password == nil
        else { return nil }
        guard let port = url.port ?? Self.defaultPort(for: scheme) else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "https": 443
        case "http": 80
        default: nil
        }
    }

    // Every hop is compared against the ORIGINAL pinned origin, never the previous hop — otherwise a
    // same-origin → same-origin → cross-origin chain walks off the pin one redirect at a time. Scheme
    // equality also refuses an HTTPS→HTTP downgrade for free.
    public static func redirectIsPermitted(from pinned: RequestOrigin?, to candidate: URL?) -> Bool {
        guard let pinned, let candidate = RequestOrigin(candidate) else { return false }
        return pinned == candidate
    }
}
