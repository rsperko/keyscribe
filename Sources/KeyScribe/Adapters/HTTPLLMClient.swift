import Foundation
import KeyScribeKit

// Thin BYOK transport over the OpenAI / Anthropic / Gemini HTTP APIs (design.md §5). Key fetched from
// Keychain by the connection's key_ref. Provider-agnostic orchestration (assemble → gate → retry/fallback)
// lives in KeyScribeKit.RewriteService.
struct HTTPLLMClient: LLMClient {
    // Bounded session, not URLSession.shared (60s default, doubled by the gate's stricter-retry). A hung
    // BYOK endpoint must fall back to the local transcript promptly, so cap each attempt.
    var session: URLSession = ProviderTransport.makeSession(requestTimeout: 30, resourceTimeout: 45)
    var keyProvider: @Sendable (String) -> SecretLookup = { KeychainStore.lookup($0) }
    var tokenCommandRunner: @Sendable (String) async throws -> String = { try await TokenCommandRunner.run($0) }
    var tokenCache: TokenCommandCache = .shared
    var adaptationCache: RequestAdaptationCache = .shared
    var wireOverrideCache: WireAPIOverrideCache = .shared
    var now: @Sendable () -> Date = { Date() }

    private static let maxRemediations = 4

    private var transport: ProviderTransport {
        ProviderTransport(session: session, keyProvider: keyProvider,
                          tokenCommandRunner: tokenCommandRunner, tokenCache: tokenCache, now: now)
    }

    // Bodyless, auth-less HEAD warm-up — carries no user content — so a rewrite moments later reuses the
    // pooled connection.
    func preconnect(connection: Connection) async {
        guard let url = preconnectURL(for: connection) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        _ = try? await session.data(for: req)
    }

    private func preconnectURL(for connection: Connection) -> URL? {
        switch connection.provider {
        case .openai, .openaiCompatible:
            let base = connection.baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines).removingTrailingSlash
                ?? (connection.provider == .openai ? "https://api.openai.com/v1" : nil)
            return base.flatMap { URL(string: $0) }
        case .anthropic:
            return URL(string: "https://api.anthropic.com")
        case .gemini:
            return URL(string: "https://generativelanguage.googleapis.com")
        }
    }

    func complete(system: String, user: String, connection: Connection) async throws -> String {
        let key = try await transport.credential(for: connection)
        if connection.provider != .openaiCompatible, key?.isEmpty != false {
            throw ProviderTransportError.missingKey(connection.keyRef)
        }
        switch connection.provider {
        case .openai, .openaiCompatible:
            return try await completeOpenAICompatible(system: system, user: user, connection: connection, key: key)
        case .anthropic:
            let request = try buildRequest(
                system: system, user: user, connection: connection, key: key,
                adaptations: .default(for: .anthropic))
            let data = try await transport.send(request)
            return try parse(data, provider: .anthropic)
        case .gemini:
            return try await completeGemini(system: system, user: user, connection: connection, key: key)
        }
    }

    // Gemini has no structured unsupported-parameter error to key a remediation loop on, but a model that
    // rejects thinkingConfig (e.g. one that takes thinkingBudget instead of thinkingLevel) must not break
    // every rewrite permanently. On a 400 with thinkingConfig in the payload, retry once without it and
    // remember only if the retry succeeds — a 400 with an unrelated cause fails again identically and
    // caches nothing.
    private func completeGemini(system: String, user: String, connection: Connection, key: String?) async throws -> String {
        let cacheKey = adaptationCacheKey(for: connection)
        let adaptations = await adaptationCache.lookup(cacheKey) ?? .default(for: .gemini)
        let request = try buildRequest(
            system: system, user: user, connection: connection, key: key, adaptations: adaptations)
        do {
            return try parse(try await transport.send(request), provider: .gemini)
        } catch let ProviderTransportError.http(status, body) where status == 400 {
            guard adaptations.includeThinkingConfig, connection.params.geminiThinkingLevel != nil else {
                throw ProviderTransportError.http(status, body: body)
            }
            var next = adaptations
            next.includeThinkingConfig = false
            let retry = try buildRequest(
                system: system, user: user, connection: connection, key: key, adaptations: next)
            let output = try parse(try await transport.send(retry), provider: .gemini)
            await adaptationCache.remember(next, for: cacheKey)
            return output
        }
    }

    // The configured wireAPI is a starting hint; the SERVER is authoritative about which wire a model
    // speaks. Once an endpoint has redirected us, later rewrites start at the wire that actually worked —
    // for explicitly configured connections too, which otherwise repeat the known-failing round trip on
    // every dictation despite having already recorded the fallback.
    private func completeOpenAICompatible(
        system: String, user: String, connection: Connection, key: String?
    ) async throws -> String {
        do {
            return try await routedComplete(system: system, user: user, connection: connection, key: key)
        } catch let redirected as RedirectedWireFailure {
            throw redirected.underlying
        }
    }

    // A failure from a wire we were REDIRECTED to. It carries the real error but marks that the cross-wire
    // correction has already run, so the stale-override fallback below must not repeat the very same
    // request — with two wires, a redirect's target and that fallback's target are the same endpoint.
    private struct RedirectedWireFailure: Error {
        let underlying: Error
    }

    private func routedComplete(
        system: String, user: String, connection: Connection, key: String?
    ) async throws -> String {
        let hostKey = Self.hostKey(for: connection)
        let override = await wireOverrideCache.lookup(hostKey)
        let configured = Self.startingWire(for: connection)
        do {
            return try await completeWire(
                override ?? configured, system: system, user: user, connection: connection, key: key,
                allowRedirect: true)
        } catch let ProviderTransportError.http(status, body) where Self.wireMismatchStatuses.contains(status) {
            // The remembered wire isn't there any more — e.g. the host behind an unchanged base URL was
            // swapped for one that doesn't serve it, and a bare 404 body carries nothing the error itself
            // could correct the override with. Forget it and probe the configured wire once, so a dead
            // endpoint can't pin every later rewrite until restart.
            //
            // Only the endpoint-mismatch statuses qualify. Everything else the endpoint can return — 401,
            // 429, an exhausted 5xx, a 400 about the prompt — says the wire was found and answered, so it
            // is not evidence against the override; resending through the other wire would just multiply
            // requests (and re-send the prompt) on a connection that is merely unauthorized or throttled.
            // A parse or truncation failure is likewise not evidence: the wire was spoken correctly.
            //
            // Nor is every 404: a structured missing-MODEL error is the endpoint answering about the model
            // id (which is itself part of this cache key), not about the wire. Only an unexplained 404/405
            // implicates the endpoint.
            guard OpenAIAPIError.parse(body: body)?.indicatesMissingModel != true,
                  let override, override != configured else {
                throw ProviderTransportError.http(status, body: body)
            }
            await wireOverrideCache.forget(hostKey)
            return try await completeWire(
                configured, system: system, user: user, connection: connection, key: key, allowRedirect: true)
        }
    }

    // One remediation loop for both OpenAI wires: they differ only in which wire a redirect points at, and
    // `buildRequest`/`parse` already key their envelope off the wire.
    private func completeWire(
        _ wire: Connection.WireAPI, system: String, user: String, connection: Connection, key: String?,
        allowRedirect: Bool
    ) async throws -> String {
        var wired = connection
        wired.wireAPI = wire
        let cacheKey = adaptationCacheKey(for: wired)
        let initial = await adaptationCache.lookup(cacheKey) ?? .default(for: connection.provider)
        var adaptations = initial
        var attempts = 0
        while true {
            let request = try buildRequest(
                system: system, user: user, connection: wired, key: key, adaptations: adaptations)
            do {
                let output = try parse(
                    try await transport.send(request), provider: connection.provider, wireAPI: wire)
                // Remember only a remediation the server actually accepted (as completeGemini does).
                // Caching before the retry proves it lets one 400 with an unrelated cause pin a wrong
                // remediation for the process lifetime — a max_tokens VALUE error, for instance, message-
                // scans to a max_completion_tokens FIELD remap that no reverse remediation can undo.
                if adaptations != initial { await adaptationCache.remember(adaptations, for: cacheKey) }
                return output
            } catch let ProviderTransportError.http(status, body) where Self.adaptableStatuses.contains(status) {
                let apiError = OpenAIAPIError.parse(body: body)
                let other = Self.otherWire(than: wire)
                if allowRedirect, apiError?.indicatesRequires(other) == true {
                    // The endpoint has just disowned this wire, so a remembered override naming it is
                    // proven stale whether or not the redirect target then works — drop it now. (A redirect
                    // only ever fires from the wire this call started at, which is the override when one
                    // exists, so this clears exactly that entry.) Leaving it would make every later rewrite
                    // repeat the same doomed pair of requests.
                    await wireOverrideCache.forget(Self.hostKey(for: connection))
                    let output: String
                    do {
                        output = try await completeWire(
                            other, system: system, user: user, connection: connection, key: key,
                            allowRedirect: false)
                    } catch {
                        throw RedirectedWireFailure(underlying: error)
                    }
                    // The target earns its own entry only once it has actually produced a reply — the same
                    // rule the adaptation cache above follows.
                    await wireOverrideCache.remember(other, for: Self.hostKey(for: connection))
                    return output
                }
                guard status == 400, attempts < Self.maxRemediations,
                      let apiError, let next = remediatedAdaptations(adaptations, for: apiError) else {
                    throw ProviderTransportError.http(status, body: body)
                }
                adaptations = next
                attempts += 1
            }
        }
    }

    private static let adaptableStatuses: Set<Int> = [400, 404, 405, 422]

    // The endpoint isn't there / won't take a POST: the only answers that speak to the WIRE rather than to
    // the request, the key, or the model behind it.
    private static let wireMismatchStatuses: Set<Int> = [404, 405]

    private static func startingWire(for connection: Connection) -> Connection.WireAPI {
        connection.wireAPI == .responses ? .responses : .chatCompletions
    }

    private static func otherWire(than wire: Connection.WireAPI) -> Connection.WireAPI {
        wire == .responses ? .chatCompletions : .responses
    }

    // Adaptations are what a specific SERVER accepts (temperature support, token-limit field name,
    // system-fold). Editing a connection's base URL points it at a different server, so the base URL is
    // part of the identity — keying on id+model alone would replay adaptations learned from the old host.
    private func adaptationCacheKey(for connection: Connection) -> String {
        [connection.id, connection.model, connection.baseUrl ?? "", connection.wireAPI.rawValue]
            .joined(separator: "\n")
    }

    static func hostKey(for connection: Connection) -> String {
        WireAPIOverrideCache.key(for: connection)
    }

    private func buildRequest(
        system: String, user: String, connection: Connection, key: String?, adaptations: RequestAdaptations
    ) throws -> URLRequest {
        let temp = connection.params.temperature
        let maxTokens = connection.params.maxTokens

        switch connection.provider {
        case .openai, .openaiCompatible:
            let base = connection.baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines).removingTrailingSlash
                ?? (connection.provider == .openai ? "https://api.openai.com/v1" : nil)
            let endpoint = connection.wireAPI == .responses ? "/responses" : "/chat/completions"
            guard let base, !base.isEmpty, let url = URL(string: base + endpoint) else {
                throw ProviderTransportError.missingBaseURL
            }
            var req = jsonRequest(url)
            transport.applyAuth(key, for: connection.provider, to: &req)
            applyOpenRouterHeaders(to: &req, host: url.host())
            if connection.wireAPI == .responses {
                let reasoningEffort = adaptations.includeReasoningEffort ? connection.params.reasoningEffort : nil
                // Reasoning tokens are billed against max_output_tokens on Responses, so a reasoning model
                // needs the same safety floor the Chat path applies — otherwise reasoning can consume the
                // whole budget and the reply comes back status:"incomplete".
                let usesReasoning = reasoningEffort.map { $0.lowercased() != "none" } ?? false
                let reasoningModel = adaptations.indicatesReasoningModel || usesReasoning
                let sizedTokens = reasoningModel ? reasoningSafeMaxTokens(maxTokens) : maxTokens
                var payload: [String: Any] = [
                    "model": connection.model,
                    "instructions": system,
                    "input": user,
                    "max_output_tokens": sizedTokens,
                ]
                payload["store"] = false
                // Responses lists temperature as an optional request parameter, so a connection's
                // configured value must be honored on both wires — the auto-upgrade can flip wires
                // mid-lifetime, and sampling must not change with it. A server that rejects it self-heals
                // through the same remediation loop the chat payload relies on.
                if adaptations.includeTemperature { payload["temperature"] = temp }
                if let reasoningEffort { payload["reasoning"] = ["effort": reasoningEffort] }
                req.httpBody = try body(payload)
                return req
            }
            let sizedTokens = adaptations.indicatesReasoningModel ? reasoningSafeMaxTokens(maxTokens) : maxTokens
            var payload: [String: Any] = [
                "model": connection.model,
                adaptations.tokenLimitField.jsonKey: sizedTokens,
                "messages": chatMessages(system: system, user: user, fold: adaptations.foldSystemIntoUser),
            ]
            if adaptations.includeTemperature { payload["temperature"] = temp }
            if adaptations.includeReasoningEffort, let reasoningEffort = connection.params.reasoningEffort {
                payload["reasoning_effort"] = reasoningEffort
            }
            req.httpBody = try body(payload)
            return req

        case .anthropic:
            guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw ProviderTransportError.badResponse }
            var req = jsonRequest(url)
            transport.applyAuth(key, for: connection.provider, to: &req)
            req.httpBody = try body([
                "model": connection.model,
                "max_tokens": maxTokens,
                "temperature": temp,
                "system": system,
                "messages": [["role": "user", "content": user]],
            ])
            return req

        case .gemini:
            let base = "https://generativelanguage.googleapis.com/v1beta/models"
            guard let key, let url = URL(string: "\(base)/\(connection.model):generateContent") else {
                throw ProviderTransportError.badResponse
            }
            var req = jsonRequest(url)
            transport.applyAuth(key, for: connection.provider, to: &req)
            var generationConfig: [String: Any] = [
                "temperature": temp,
                "maxOutputTokens": maxTokens,
            ]
            if adaptations.includeThinkingConfig, let thinkingLevel = connection.params.geminiThinkingLevel {
                generationConfig["thinkingConfig"] = ["thinkingLevel": thinkingLevel]
            }
            req.httpBody = try body([
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["role": "user", "parts": [["text": user]]]],
                "generationConfig": generationConfig,
            ])
            return req
        }
    }

    private func chatMessages(system: String, user: String, fold: Bool) -> [[String: String]] {
        guard fold else {
            return [["role": "system", "content": system], ["role": "user", "content": user]]
        }
        let combined = system.isEmpty ? user : system + "\n\n" + user
        return [["role": "user", "content": combined]]
    }

    private func applyOpenRouterHeaders(to req: inout URLRequest, host: String?) {
        guard let host = host?.lowercased(),
              host == "openrouter.ai" || host.hasSuffix(".openrouter.ai") else { return }
        req.setValue(Self.openRouterReferer, forHTTPHeaderField: "HTTP-Referer")
        req.setValue(Branding.appName, forHTTPHeaderField: "X-Title")
    }

    private static let openRouterReferer = "https://keyscribe.app"

    private func parse(
        _ data: Data, provider: Connection.Provider, wireAPI: Connection.WireAPI = .chatCompletions
    ) throws -> String {
        // A proxy fronting another backend can wrap the whole payload in a single-element top-level array
        // (`[{...}]`), the same shape it uses for errors. Unwrap it so a success body is read, not rejected.
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let json = Self.responseObject(root) else {
            throw ProviderTransportError.badResponse
        }
        switch provider {
        case .openai, .openaiCompatible:
            if json["error"] is [String: Any] {
                throw ProviderTransportError.http(400, body: String(data: data, encoding: .utf8))
            }
            if wireAPI == .responses {
                return try responsesText(from: json)
            }
            guard let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first,
                  let message = choice["message"] as? [String: Any],
                  let content = Self.messageText(message["content"]) else { throw ProviderTransportError.badResponse }
            // A response cut off at max_tokens passes the gate when no sentinels were issued (common
            // privacy-off case), pasting half a sentence. Treat truncation as an error → local fallback.
            if (choice["finish_reason"] as? String) == "length" { throw ProviderTransportError.truncated }
            guard let cleaned = ReasoningOutput.clean(content) else { throw ProviderTransportError.badResponse }
            return cleaned
        case .anthropic:
            if (json["stop_reason"] as? String) == "max_tokens" { throw ProviderTransportError.truncated }
            guard let content = json["content"] as? [[String: Any]],
                  let text = anthropicText(from: content) else { throw ProviderTransportError.badResponse }
            return text
        case .gemini:
            guard let candidates = json["candidates"] as? [[String: Any]],
                  let candidate = candidates.first,
                  let content = candidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { throw ProviderTransportError.badResponse }
            // Join every text part, not just the first — Gemini can split the reply across parts (or lead
            // with a non-text part), and reading `parts.first` alone would drop or miss the answer.
            let text = parts.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw ProviderTransportError.badResponse }
            if (candidate["finishReason"] as? String) == "MAX_TOKENS" { throw ProviderTransportError.truncated }
            return text
        }
    }

    // The response object, whether the body is a plain `{...}` or wrapped in a single-element top-level
    // array `[{...}]` (a proxy normalizing another backend). Mirrors OpenAIAPIError's error-object unwrap.
    private static func responseObject(_ root: Any) -> [String: Any]? {
        if let object = root as? [String: Any] { return object }
        if let array = root as? [Any], let first = array.first { return responseObject(first) }
        return nil
    }

    // OpenAI `content` is normally a string, but some compatible servers and proxies (normalizing from
    // Anthropic/Gemini) return it as an array of typed parts — `[{"type":"text","text":"…"}]`. Accept both,
    // so a parts-shaped reply isn't rejected as a bad response and silently dropped to local.
    private static func messageText(_ content: Any?) -> String? {
        if let string = content as? String { return string }
        if let parts = content as? [[String: Any]] {
            let joined = parts.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private func responsesText(from json: [String: Any]) throws -> String {
        let status = json["status"] as? String
        if status == "incomplete" { throw ProviderTransportError.truncated }
        // A minimal proxy can implement /responses without the `status` field at all. Accept that when the
        // output itself is well-formed rather than dropping a good reply to local. A status that IS present
        // must still say completed, so a genuinely unfinished reply is never inserted.
        guard status == nil || status == "completed",
              let output = json["output"] as? [[String: Any]] else {
            throw ProviderTransportError.badResponse
        }
        let text = output
            .filter { ($0["type"] as? String) == "message" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { ($0["type"] as? String) == "output_text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard let cleaned = ReasoningOutput.clean(text) else { throw ProviderTransportError.badResponse }
        return cleaned
    }

    private func anthropicText(from blocks: [[String: Any]]) -> String? {
        let joined = blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        if !joined.isEmpty { return joined }
        return blocks.compactMap { $0["text"] as? String }.first
    }

    private func jsonRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    private func body(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict)
    }
}
