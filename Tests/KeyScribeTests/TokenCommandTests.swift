import Foundation
import Testing

@testable import KeyScribe

struct TokenCommandParseTests {
    @Test func rawTokenIsFirstLine() throws {
        let parsed = try TokenCommandOutput.parse(from: "abc123\nignored\n")
        #expect(parsed.token == "abc123")
        #expect(parsed.expiresAt == nil)
        #expect(parsed.expiresIn == nil)
    }

    @Test func stripsBearerPrefix() throws {
        let parsed = try TokenCommandOutput.parse(from: "Bearer abc123")
        #expect(parsed.token == "abc123")
    }

    @Test func jsonAccessTokenWithExpiresIn() throws {
        let parsed = try TokenCommandOutput.parse(from: #"{"access_token":"abc","expires_in":3600}"#)
        #expect(parsed.token == "abc")
        #expect(parsed.expiresIn == 3600)
        #expect(parsed.expiresAt == nil)
    }

    @Test func execCredentialStatusTokenWithExpirationTimestamp() throws {
        let json = #"{"kind":"ExecCredential","status":{"token":"k8stok","expirationTimestamp":"2030-01-02T03:04:05Z"}}"#
        let parsed = try TokenCommandOutput.parse(from: json)
        #expect(parsed.token == "k8stok")
        let expected = ISO8601DateFormatter().date(from: "2030-01-02T03:04:05Z")
        #expect(parsed.expiresAt == expected)
    }

    @Test func topLevelExpirationAsEpochSeconds() throws {
        let parsed = try TokenCommandOutput.parse(from: #"{"token":"abc","expiration":1893553445}"#)
        #expect(parsed.token == "abc")
        #expect(parsed.expiresAt == Date(timeIntervalSince1970: 1893553445))
    }

    @Test func emptyOutputThrows() {
        #expect(throws: TokenCommandError.self) { try TokenCommandOutput.parse(from: "   \n") }
    }
}

struct TokenCommandCacheTests {
    @Test func cachesTokenWithinTTLAndRunsOnce() async throws {
        let cache = TokenCommandCache()
        let runs = Counter()
        let base = Date(timeIntervalSince1970: 1_000_000)

        let first = try await cache.token(forKey: "cmd", now: base) {
            await runs.bump(); return #"{"access_token":"tok","expires_in":3600}"#
        }
        let second = try await cache.token(forKey: "cmd", now: base.addingTimeInterval(60)) {
            await runs.bump(); return #"{"access_token":"tok2","expires_in":3600}"#
        }

        #expect(first == "tok")
        #expect(second == "tok")
        #expect(await runs.value == 1)
    }

    @Test func refetchesAfterExpiry() async throws {
        let cache = TokenCommandCache()
        let runs = Counter()
        let base = Date(timeIntervalSince1970: 1_000_000)

        _ = try await cache.token(forKey: "cmd", now: base) {
            await runs.bump(); return #"{"access_token":"tok","expires_in":100}"#
        }
        let refreshed = try await cache.token(forKey: "cmd", now: base.addingTimeInterval(200)) {
            await runs.bump(); return #"{"access_token":"tok2","expires_in":100}"#
        }

        #expect(refreshed == "tok2")
        #expect(await runs.value == 2)
    }

    @Test func honorsExpirationTimestampForRefreshSkew() async throws {
        let cache = TokenCommandCache()
        let runs = Counter()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let expiry = ISO8601DateFormatter().string(from: now.addingTimeInterval(10))

        _ = try await cache.token(forKey: "cmd", now: now) {
            await runs.bump(); return #"{"status":{"token":"tok","expirationTimestamp":"\#(expiry)"}}"#
        }
        let again = try await cache.token(forKey: "cmd", now: now.addingTimeInterval(1)) {
            await runs.bump(); return #"{"status":{"token":"tok2","expirationTimestamp":"\#(expiry)"}}"#
        }

        #expect(again == "tok2")
        #expect(await runs.value == 2)
    }

    @Test func differentCommandsAreCachedSeparately() async throws {
        let cache = TokenCommandCache()
        let base = Date(timeIntervalSince1970: 1_000_000)

        let a = try await cache.token(forKey: "a", now: base) { "atok" }
        let b = try await cache.token(forKey: "b", now: base) { "btok" }

        #expect(a == "atok")
        #expect(b == "btok")
    }

    actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }
}

struct TokenCommandRunnerTests {
    @Test func returnsTokenWhenCommandWritesLargeStderr() async throws {
        let output = try await TokenCommandRunner.run(
            "for i in $(seq 1 5000); do echo noise-line-$i 1>&2; done; echo the-token")
        let token = try TokenCommandOutput.parse(from: output).token
        #expect(token == "the-token")
    }

    @Test func nonZeroExitSurfacesStderr() async {
        await #expect(throws: TokenCommandError.self) {
            do {
                _ = try await TokenCommandRunner.run("echo boom 1>&2; exit 7")
            } catch let error as TokenCommandError {
                #expect("\(error)".contains("boom"))
                throw error
            }
        }
    }

    @Test func timesOutWithoutHanging() async {
        await #expect(throws: TokenCommandError.self) {
            _ = try await TokenCommandRunner.run("sleep 30", timeout: 0.5)
        }
    }

    @Test func timesOutWhenCommandIgnoresTerminate() async {
        let start = Date()
        await #expect(throws: TokenCommandError.self) {
            _ = try await TokenCommandRunner.run("trap '' TERM; sleep 30", timeout: 0.2)
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }
}

struct TokenCommandOutcomeTests {
    @Test func cleanExitReturnsStdoutEvenWhenTheDeadlineFlagRaced() throws {
        let out = try TokenCommandRunner.outcome(
            terminationStatus: 0, timedOut: true,
            stdout: Data("the-token\n".utf8), stderr: Data())
        #expect(out == "the-token\n")
    }

    @Test func nonZeroExitWithTheTimeoutFlagReportsTimeout() {
        do {
            _ = try TokenCommandRunner.outcome(
                terminationStatus: 15, timedOut: true, stdout: Data(), stderr: Data())
            Issue.record("expected outcome to throw")
        } catch TokenCommandError.timedOut {
        } catch {
            Issue.record("expected .timedOut, got \(error)")
        }
    }

    @Test func nonZeroExitWithoutTimeoutSurfacesStderr() {
        do {
            _ = try TokenCommandRunner.outcome(
                terminationStatus: 7, timedOut: false,
                stdout: Data(), stderr: Data("boom\n".utf8))
            Issue.record("expected outcome to throw")
        } catch TokenCommandError.failed(let status, let message) {
            #expect(status == 7)
            #expect(message == "boom")
        } catch {
            Issue.record("expected .failed, got \(error)")
        }
    }
}
