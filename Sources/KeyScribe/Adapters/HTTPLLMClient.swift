import Foundation
import KeyScribeKit

// Thin BYOK transport over the OpenAI / Anthropic / Gemini HTTP APIs (design.md §5). Key fetched from
// Keychain by the connection's key_ref. Provider-agnostic orchestration (assemble → gate → retry/fallback)
// lives in KeyScribeKit.RewriteService.
struct HTTPLLMClient: LLMClient {
    // As long as RewriteService's whole-rewrite deadline, so that deadline is the only limit a slow model
    // meets; a shorter per-request timeout here would quietly cut it off first. Anything a person waits on
    // in Settings passes its own short session.
    var session: URLSession = ProviderTransport.makeSession(
        requestTimeout: RewriteService.defaultDeadlineSeconds, resourceTimeout: RewriteService.defaultDeadlineSeconds)
    static func settingsSession() -> URLSession {
        ProviderTransport.makeSession(requestTimeout: 30, resourceTimeout: 45)
    }
    var keyProvider: @Sendable (String) -> SecretLookup = { KeychainStore.lookup($0) }
    var tokenCommandRunner: @Sendable (String) async throws -> String = { try await TokenCommandRunner.run($0) }
    var tokenCache: TokenCommandCache = .shared
    var adaptationCache: RequestAdaptationCache = .shared
    var wireOverrideCache: WireAPIOverrideCache = .shared
    var now: @Sendable () -> Date = { Date() }

    private static let maxRemediations = 7
    static let preconnectTimeout: TimeInterval = 10

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
        req.timeoutInterval = Self.preconnectTimeout
        _ = try? await session.data(for: req, delegate: OriginPinnedRedirects(req.url))
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
        case .anthropic, .gemini:
            return try await completeNegotiated(system: system, user: user, connection: connection, key: key)
        }
    }

    func reasoningOutcome(for connection: Connection) async -> ReasoningOutcome? {
        var wired = connection
        if connection.provider == .openai || connection.provider == .openaiCompatible {
            wired.wireAPI = await wireOverrideCache.lookup(Self.hostKey(for: connection)) ?? Self.startingWire(for: connection)
        }
        let adaptations = await adaptationCache.lookup(adaptationCacheKey(for: wired)) ?? .initial(for: wired)
        return adaptations.outcome(for: connection.params.reasoning)
    }

    // Anthropic and Gemini have no structured unsupported-parameter error, so only a 400 whose message names
    // the reasoning control, a too-large token value, or temperature is remediated; any other 400 fails once
    // and caches nothing.
    private func completeNegotiated(system: String, user: String, connection: Connection, key: String?) async throws -> String {
        let cacheKey = adaptationCacheKey(for: connection)
        let initial = await adaptationCache.lookup(cacheKey) ?? .initial(for: connection)
        var adaptations = initial
        var attempts = 0
        while true {
            let request = try buildRequest(
                system: system, user: user, connection: connection, key: key, adaptations: adaptations)
            do {
                let reply = try parse(try await transport.send(request), provider: connection.provider)
                await settle(adaptations, initial: initial, reply: reply, cacheKey: cacheKey, connection: connection)
                return reply.text
            } catch let ProviderTransportError.http(status, body) where status == 400 {
                guard attempts < Self.maxRemediations, let apiError = OpenAIAPIError.parse(body: body),
                      let next = try remediate(adaptations, for: apiError, connection: connection, status: status)
                else { throw ProviderTransportError.http(status, body: body) }
                adaptations = next
                attempts += 1
            }
        }
    }

    private func remediate(
        _ adaptations: RequestAdaptations, for apiError: OpenAIAPIError, connection: Connection, status: Int
    ) throws -> RequestAdaptations? {
        let sent = adaptations.outputTokens(base: connection.params.maxTokens, ceiling: connection.params.outputCeiling)
        switch remediation(
            adaptations, for: apiError, preference: connection.params.reasoning, provider: connection.provider,
            sentTokenLimit: sent) {
        case .refuse(let level):
            Log.models.notice(
                "rewrite reasoning level refused connection=\(connection.id, privacy: .public) model=\(connection.model, privacy: .public) level=\(level, privacy: .public) status=\(status)")
            throw ProviderTransportError.reasoningLevelRefused(level)
        case .retry(let next):
            Log.models.notice(
                "rewrite request adapted connection=\(connection.id, privacy: .public) model=\(connection.model, privacy: .public) reasoning=\(adaptations.reasoning.logDescription, privacy: .public)->\(next.reasoning.logDescription, privacy: .public) cap=\(next.tokenLimitCap.map(String.init) ?? "none", privacy: .public) status=\(status) cause=\(apiError.code ?? "message-scan", privacy: .public)")
            return next
        case nil:
            return nil
        }
    }

    // Remember only what the server actually accepted. When the request asked for no reasoning, or the
    // service would not take a reasoning setting at all, the reply's usage is the only evidence of what the
    // model did: a reply that reasoned anyway is worth telling the person about and keeps the extra output
    // room on, and a reply without a reasoning count leaves the setting unconfirmed rather than proven.
    private func settle(
        _ adaptations: RequestAdaptations, initial: RequestAdaptations, reply: ParsedReply, cacheKey: String,
        connection: Connection
    ) async {
        var accepted = adaptations
        let expectedNone = accepted.reasoning.request?.disablesReasoning == true || accepted.reasoning == .unknown
        if expectedNone || !accepted.requireAllParameters {
            let merged = accepted.reasoningEvidence.merged(with: reply.usage.evidence)
            if merged == .reasoned, accepted.reasoningEvidence != .reasoned {
                Log.models.notice(
                    "rewrite reasoning not honored connection=\(connection.id, privacy: .public) model=\(connection.model, privacy: .public) reasoning=\(accepted.reasoning.logDescription, privacy: .public) reasoningTokens=\(reply.usage.reasoningTokens ?? -1)")
            }
            accepted.reasoningEvidence = merged
        }
        if accepted != initial { await adaptationCache.remember(accepted, for: cacheKey) }
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
        let initial = await adaptationCache.lookup(cacheKey) ?? .initial(for: wired)
        var adaptations = initial
        var attempts = 0
        while true {
            let request = try buildRequest(
                system: system, user: user, connection: wired, key: key, adaptations: adaptations)
            do {
                let reply = try parse(
                    try await transport.send(request), provider: connection.provider, wireAPI: wire)
                // Remember only a remediation the server actually accepted. Caching before the retry proves it
                // lets one 400 with an unrelated cause pin a wrong remediation for the process lifetime — a
                // max_tokens VALUE error, for instance, message-scans to a max_completion_tokens FIELD remap
                // that no reverse remediation can undo.
                await settle(adaptations, initial: initial, reply: reply, cacheKey: cacheKey, connection: wired)
                return reply.text
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
                if attempts < Self.maxRemediations, adaptations.requireAllParameters,
                   Self.indicatesNoRouteForParameters(apiError, url: request.url) {
                    adaptations = try relaxedRoute(adaptations, connection: wired, status: status)
                    attempts += 1
                    continue
                }
                guard attempts < Self.maxRemediations, let apiError, status == 400,
                      let next = try remediate(adaptations, for: apiError, connection: wired, status: status)
                else { throw ProviderTransportError.http(status, body: body) }
                adaptations = next
                attempts += 1
            }
        }
    }

    // A router asked to honor every parameter answers with a missing-route error when no provider behind the
    // model takes ALL of them, and it does not say which one. Temperature goes first, keeping the reasoning
    // setting enforced. A level the person chose is never sent unenforced: past that point the honest answer
    // is that no route takes it. Lowest available may stop requiring every parameter, and is then reported as
    // not guaranteed rather than as applied. A bare "no endpoints" (the model is unavailable) is not a
    // parameter problem and fails as it is.
    private func relaxedRoute(
        _ adaptations: RequestAdaptations, connection: Connection, status: Int
    ) throws -> RequestAdaptations {
        var next = adaptations
        if next.includeTemperature {
            next.includeTemperature = false
        } else if case .level(let level) = connection.params.reasoning {
            Log.models.notice(
                "rewrite reasoning level has no route connection=\(connection.id, privacy: .public) model=\(connection.model, privacy: .public) level=\(level, privacy: .public) status=\(status)")
            throw ProviderTransportError.noRouteForReasoningLevel(level)
        } else {
            next.requireAllParameters = false
        }
        Log.models.notice(
            "rewrite request adapted connection=\(connection.id, privacy: .public) model=\(connection.model, privacy: .public) temperature=\(next.includeTemperature, privacy: .public) require-parameters=\(next.requireAllParameters, privacy: .public) status=\(status)")
        return next
    }

    private static func indicatesNoRouteForParameters(_ error: OpenAIAPIError?, url: URL?) -> Bool {
        guard isOpenRouter(url?.host()), let message = error?.message?.lowercased() else { return false }
        return message.contains("requested parameters")
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
        [connection.id, connection.model, connection.baseUrl ?? "", connection.wireAPI.rawValue,
         connection.params.reasoning.storedValue]
            .joined(separator: "\n")
    }

    static func hostKey(for connection: Connection) -> String {
        WireAPIOverrideCache.key(for: connection)
    }

    private func buildRequest(
        system: String, user: String, connection: Connection, key: String?, adaptations: RequestAdaptations
    ) throws -> URLRequest {
        let temp = connection.params.temperature
        let maxTokens = adaptations.outputTokens(base: connection.params.maxTokens, ceiling: connection.params.outputCeiling)
        let reasoning = adaptations.reasoning.request

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
            let openRouter = Self.isOpenRouter(url.host())
            applyOpenRouterHeaders(to: &req, host: url.host())
            var effort: String?
            if case .effort(let value)? = reasoning { effort = value }
            if connection.wireAPI == .responses {
                var payload: [String: Any] = [
                    "model": connection.model,
                    "instructions": system,
                    "input": user,
                    "max_output_tokens": maxTokens,
                ]
                payload["store"] = false
                // Responses lists temperature as an optional request parameter, so a connection's
                // configured value must be honored on both wires — the auto-upgrade can flip wires
                // mid-lifetime, and sampling must not change with it. A server that rejects it self-heals
                // through the same remediation loop the chat payload relies on.
                if adaptations.includeTemperature { payload["temperature"] = temp }
                if let effort { payload["reasoning"] = ["effort": effort] }
                if openRouter, effort != nil, adaptations.requireAllParameters {
                    payload["provider"] = ["require_parameters": true]
                }
                req.httpBody = try body(payload)
                return req
            }
            var payload: [String: Any] = [
                "model": connection.model,
                adaptations.tokenLimitField.jsonKey: maxTokens,
                "messages": chatMessages(system: system, user: user, fold: adaptations.foldSystemIntoUser),
            ]
            if adaptations.includeTemperature { payload["temperature"] = temp }
            if let effort {
                if openRouter {
                    payload["reasoning"] = ["effort": effort]
                    if adaptations.requireAllParameters { payload["provider"] = ["require_parameters": true] }
                } else {
                    payload["reasoning_effort"] = effort
                }
            }
            req.httpBody = try body(payload)
            return req

        case .anthropic:
            guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw ProviderTransportError.badResponse }
            var req = jsonRequest(url)
            transport.applyAuth(key, for: connection.provider, to: &req)
            var payload: [String: Any] = [
                "model": connection.model,
                "max_tokens": maxTokens,
                "system": system,
                "messages": [["role": "user", "content": user]],
            ]
            if adaptations.includeTemperature { payload["temperature"] = temp }
            switch reasoning {
            case .anthropicThinking(let type)?:
                payload["thinking"] = ["type": type]
            case .anthropicEffort(let effort, let adaptive)?:
                payload["output_config"] = ["effort": effort]
                if adaptive { payload["thinking"] = ["type": "adaptive"] }
            default:
                break
            }
            req.httpBody = try body(payload)
            return req

        case .gemini:
            let base = "https://generativelanguage.googleapis.com/v1beta/models"
            guard let key, let url = URL(string: "\(base)/\(connection.model):generateContent") else {
                throw ProviderTransportError.badResponse
            }
            var req = jsonRequest(url)
            transport.applyAuth(key, for: connection.provider, to: &req)
            var generationConfig: [String: Any] = ["maxOutputTokens": maxTokens]
            if adaptations.includeTemperature { generationConfig["temperature"] = temp }
            switch reasoning {
            case .geminiLevel(let level)?: generationConfig["thinkingConfig"] = ["thinkingLevel": level]
            case .geminiBudget(let budget)?: generationConfig["thinkingConfig"] = ["thinkingBudget": budget]
            default: break
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

    private static func isOpenRouter(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "openrouter.ai" || host.hasSuffix(".openrouter.ai")
    }

    private func applyOpenRouterHeaders(to req: inout URLRequest, host: String?) {
        guard Self.isOpenRouter(host) else { return }
        req.setValue(Self.openRouterReferer, forHTTPHeaderField: "HTTP-Referer")
        req.setValue(Branding.appName, forHTTPHeaderField: "X-Title")
    }

    private static let openRouterReferer = "https://keyscribe.app"

    struct ParsedReply {
        let text: String
        let usage: ReplyUsage
    }

    private func parse(
        _ data: Data, provider: Connection.Provider, wireAPI: Connection.WireAPI = .chatCompletions
    ) throws -> ParsedReply {
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
                return try responsesReply(from: json)
            }
            guard let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first,
                  let message = choice["message"] as? [String: Any] else { throw ProviderTransportError.badResponse }
            let raw = Self.messageText(message["content"])
            var usage = ReplyUsage.openAIChat(json)
            if raw.map(ReasoningOutput.containsReasoning) == true { usage.hadReasoningContent = true }
            // A response cut off at max_tokens passes the gate when no sentinels were issued (common
            // privacy-off case), pasting half a sentence. Treat truncation as an error → local fallback.
            return try Self.checked(
                text: raw.flatMap(ReasoningOutput.clean),
                limitHit: (choice["finish_reason"] as? String) == "length", usage: usage)
        case .anthropic:
            let blocks = json["content"] as? [[String: Any]] ?? []
            return try Self.checked(
                text: anthropicText(from: blocks).flatMap(ReasoningOutput.clean),
                limitHit: (json["stop_reason"] as? String) == "max_tokens", usage: .anthropic(json))
        case .gemini:
            guard let candidates = json["candidates"] as? [[String: Any]],
                  let candidate = candidates.first else { throw ProviderTransportError.badResponse }
            // Join every answer part, not just the first — Gemini can split the reply across parts (or lead
            // with a non-text part), and reading `parts.first` alone would drop or miss the answer.
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
            return try Self.checked(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text,
                limitHit: (candidate["finishReason"] as? String) == "MAX_TOKENS", usage: .gemini(json))
        }
    }

    private static func checked(text: String?, limitHit: Bool, usage: ReplyUsage) throws -> ParsedReply {
        switch ReplyLimit.verdict(limitHit: limitHit, hasVisibleText: text != nil, usage: usage) {
        case .limitBeforeAnswer(let evidence): throw ProviderTransportError.limitBeforeAnswer(reasoningEvidence: evidence)
        case .truncatedAnswer: throw ProviderTransportError.truncated
        case .empty: throw ProviderTransportError.badResponse
        case .ok: return ParsedReply(text: text ?? "", usage: usage)
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

    private func responsesReply(from json: [String: Any]) throws -> ParsedReply {
        let status = json["status"] as? String
        let usage = ReplyUsage.openAIResponses(json)
        let text = (json["output"] as? [[String: Any]] ?? [])
            .filter { ($0["type"] as? String) == "message" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { ($0["type"] as? String) == "output_text" }
            .compactMap { $0["text"] as? String }
            .joined()
        if status == "incomplete" {
            // Only an explicit token-limit reason is attributed to the limit; without one the cause is unknown.
            let reason = (json["incomplete_details"] as? [String: Any])?["reason"] as? String
            guard reason == "max_output_tokens" else { throw ProviderTransportError.incompleteReply }
            return try Self.checked(text: ReasoningOutput.clean(text), limitHit: true, usage: usage)
        }
        // A minimal proxy can implement /responses without the `status` field at all. Accept that when the
        // output itself is well-formed rather than dropping a good reply to local. A status that IS present
        // must still say completed, so a genuinely unfinished reply is never inserted.
        guard status == nil || status == "completed", json["output"] is [[String: Any]] else {
            throw ProviderTransportError.badResponse
        }
        return try Self.checked(text: ReasoningOutput.clean(text), limitHit: false, usage: usage)
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
