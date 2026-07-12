import Foundation

// Shared by HTTPLLMClient (rewrite), HTTPModelLister (connection test), and ConnectionPreset
// (service recovery). A user who enters "http://host/v1/" would otherwise pass the connection test
// (lister strips the slash) but 404 on every rewrite (the client concatenated "/chat/completions"
// onto the trailing slash → "/v1//…").
extension String {
    public var removingTrailingSlash: String {
        var s = Substring(self)
        while s.hasSuffix("/") { s = s.dropLast() }
        return String(s)
    }
}
