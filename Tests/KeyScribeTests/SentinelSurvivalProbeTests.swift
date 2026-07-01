import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

private func pad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
}
private func padL(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
}
private func oneLine(_ s: String, _ max: Int) -> String {
    let flat = s.replacingOccurrences(of: "\n", with: "⏎").trimmingCharacters(in: .whitespaces)
    return flat.count <= max ? flat : String(flat.prefix(max)) + "…"
}

// Opt-in probe — the M5/M6 token-sentinel survival question (prompt_design.md "Open questions",
// docs/development/roadmap.md M5). The redaction wedge's whole premise is that a nonce token survives the LLM
// rewrite verbatim; until now that was only verified against the local oMLX proxy. This runs the
// real production rewrite path against the floor model (Gemini 2.5 Flash) over a battery of
// realistic rewrite shapes and reports survival.
//
// Needs a real key; never stored — read from the environment:
//   RUN_SENTINEL_PROBE=1 GEMINI_API_KEY=… swift test --filter sentinelSurvival
// Optional env (provider is pluggable — also point it at a weak local model to stress the floor):
//   PROBE_PROVIDER  gemini | openai_compatible | openai | anthropic   (default gemini)
//   PROBE_MODEL     model id  (default gemini-2.5-flash; e.g. an oMLX model id for local)
//   PROBE_BASE_URL  required for openai_compatible (e.g. http://127.0.0.1:11234/v1)
//   PROBE_API_KEY   key for the chosen provider (falls back to GEMINI_API_KEY)
//   SENTINEL_REPS   (default 3 — reps per cell, to catch nondeterminism)
//   SENTINEL_TEMP   (default 0.0 — measures the model's default preservation behavior)
//   SENTINEL_BAKEOFF=1  also run Table B: the multi-sentinel bake-off (≈4× the calls)
// Local-weak-model example (the redaction floor — does a dumb model still keep the token?):
//   RUN_SENTINEL_PROBE=1 PROBE_PROVIDER=openai_compatible \
//     PROBE_BASE_URL=http://127.0.0.1:11234/v1 PROBE_MODEL=Rocinante-X-12B-v1-mlx-4bit \
//     PROBE_API_KEY=… swift test --filter sentinelSurvival
struct SentinelSurvivalProbeTests {
    // MARK: - Scenario matrix

    enum Tok: Sendable { case redact(String); case verbatim(String) }

    struct Scenario: Sendable {
        let name: String
        let modePrompt: String
        let dictated: String          // edit-in-place spoken instruction; "" for dictation rewrite
        let editInPlace: Bool
        let toks: [Tok]
        // builds the content given the rendered token strings (one per `toks`, in order)
        let content: @Sendable ([String]) -> String
    }

    static let scenarios: [Scenario] = [
        Scenario(
            name: "polish-1", modePrompt: "Fix the grammar, spelling, and punctuation. Do not change the meaning.",
            dictated: "", editInPlace: false, toks: [.redact("jane.doe@acme.com")],
            content: { t in "hey just sent the invoice over to \(t[0]) can you confirm you got it thanks" }),
        Scenario(
            name: "formal", modePrompt: "Rewrite this to sound more formal and professional.",
            dictated: "", editInPlace: false, toks: [.redact("(415) 555-0137")],
            content: { t in "yo call me at \(t[0]) when you get a sec" }),
        Scenario(
            name: "multi-3", modePrompt: "Clean this up into a polished, well-punctuated message.",
            dictated: "", editInPlace: false,
            toks: [.redact("jane.doe@acme.com"), .redact("4111 1111 1111 1111"), .redact("123-45-6789")],
            content: { t in "Hi, my email is \(t[0]), my card is \(t[1]), and my ssn is \(t[2]). please update my file" }),
        Scenario(
            name: "translate-es", modePrompt: "Translate the following into Spanish.",
            dictated: "", editInPlace: false, toks: [.redact("jane.doe@acme.com")],
            content: { t in "Please send the signed documents to \(t[0]) before noon tomorrow." }),
        Scenario(
            name: "summarize", modePrompt: "Summarize this in one concise sentence.",
            dictated: "", editInPlace: false, toks: [.redact("jane.doe@acme.com")],
            content: { t in "We met yesterday and went over the budget in detail. The point of contact going forward is \(t[0]). Please follow up next week about the timeline and the remaining deliverables." }),
        Scenario(
            name: "verbatim-edit", modePrompt: "Apply the user's instruction to the selected text.",
            dictated: "make this more concise", editInPlace: true, toks: [.verbatim("config.loadOrDie(strict: true)")],
            content: { t in "You have to call \(t[0]) exactly as written or the whole pipeline silently does the wrong thing and corrupts the output." }),
        Scenario(
            name: "adjacent-2", modePrompt: "Fix the punctuation only; do not reword.",
            dictated: "", editInPlace: false, toks: [.redact("jane.doe@acme.com"), .redact("john.roe@acme.com")],
            content: { t in "Contacts \(t[0]) \(t[1]) reach either one" }),
        Scenario(
            name: "boundaries", modePrompt: "Capitalize and punctuate properly.",
            dictated: "", editInPlace: false, toks: [.redact("jane.doe@acme.com"), .redact("john.roe@acme.com")],
            content: { t in "\(t[0]) is my work email reply instead to \(t[1])" }),
    ]

    // MARK: - Sentinel candidates (Table B)

    struct Candidate: Sendable {
        let name: String
        // type rawValue ("REDACT"/"VERB"), 1-based index → token string
        let render: @Sendable (String, Int) -> String
    }

    static let candidates: [Candidate] = [
        Candidate(name: "current ⟦SN⟧", render: { "⟦SN:\($0):\($1)⟧" }),
        Candidate(name: "ascii [[ ]]", render: { "[[SN:\($0):\($1)]]" }),
        Candidate(name: "handlebar {{ }}", render: { "{{SN_\($0)_\($1)}}" }),
        Candidate(name: "PUA \u{E000}\u{E001}", render: { "\u{E000}SN:\($0):\($1)\u{E001}" }),
    ]

    // MARK: - Harness

    static func env(_ k: String) -> String? { ProcessInfo.processInfo.environment[k] }

    static func makeClient(key: String) -> HTTPLLMClient {
        HTTPLLMClient(keyProvider: { _ in key })
    }

    static func provider() -> Connection.Provider {
        switch (env("PROBE_PROVIDER") ?? "gemini").lowercased() {
        case "openai_compatible", "openai-compatible", "compat": return .openaiCompatible
        case "openai": return .openai
        case "anthropic": return .anthropic
        default: return .gemini
        }
    }

    static func connection(provider: Connection.Provider, model: String, temp: Double) -> Connection {
        Connection(
            id: "probe", name: "Probe", provider: provider, model: model,
            keyRef: "probe", baseUrl: env("PROBE_BASE_URL"), params: .init(temperature: temp, maxTokens: 1024))
    }

    struct CellResult { var survived = 0; var total = 0; var failures: [String] = [] }

    @Test(.enabled(if: SentinelSurvivalProbeTests.env("RUN_SENTINEL_PROBE") != nil
        && (SentinelSurvivalProbeTests.env("PROBE_API_KEY")
            ?? SentinelSurvivalProbeTests.env("GEMINI_API_KEY")) != nil))
    func sentinelSurvival() async throws {
        let key = (Self.env("PROBE_API_KEY") ?? Self.env("GEMINI_API_KEY"))!
        let provider = Self.provider()
        let model = Self.env("PROBE_MODEL") ?? Self.env("GEMINI_MODEL") ?? "gemini-2.5-flash"
        let reps = Int(Self.env("SENTINEL_REPS") ?? "") ?? 3
        let temp = Double(Self.env("SENTINEL_TEMP") ?? "") ?? 0.0
        let bakeoff = Self.env("SENTINEL_BAKEOFF") != nil
        let client = Self.makeClient(key: key)
        let conn = Self.connection(provider: provider, model: model, temp: temp)

        print("\n=== Sentinel survival probe — provider=\(provider.rawValue) model=\(model) temp=\(temp) reps=\(reps) ===")

        try await tableA(client: client, conn: conn, reps: reps)
        if bakeoff { try await tableB(client: client, conn: conn, reps: reps) }
        else { print("\n(Table B sentinel bake-off skipped — set SENTINEL_BAKEOFF=1 to run it.)") }
        print("=== end probe ===\n")
    }

    // Table A — production fidelity. Current sentinel, the real PromptAssembler + HTTPLLMClient +
    // ValidationGate, exactly as the app calls them. Answers: does the shipping path hold up on Flash?
    private func tableA(client: HTTPLLMClient, conn: Connection, reps: Int) async throws {
        print("\n--- Table A · production path (current ⟦SN⟧ sentinel, real PromptAssembler + ValidationGate) ---")
        print(pad("scenario", 16) + pad("tok", 5) + pad("survive", 10) + pad("gate", 26) + "first failure (raw)")

        var grandPass = 0, grandTotal = 0
        for s in Self.scenarios {
            let tokenizer = Tokenizer()
            let tokenStrings = s.toks.map { t -> String in
                switch t {
                case .redact(let v): return tokenizer.tokenize(v, type: .redact)
                case .verbatim(let v): return tokenizer.tokenize(v, type: .verbatim)
                }
            }
            let issued = tokenizer.issuedTokens
            let content = s.content(tokenStrings)
            let inputs = PromptInputs(
                modePrompt: s.modePrompt, dictatedInstructions: s.dictated, content: content,
                tokens: issued, validTerms: [], language: "English", modeSystemInstructions: "",
                appName: nil, bundleId: nil, fieldRole: nil, selectedText: nil)
            let prompt = PromptAssembler.assemble(inputs)
            var system = prompt.system
            if let rule = Self.env("PROBE_TOKEN_RULE") {
                let def = "- Each ⟦SN:…⟧ is an opaque marker — copy it into your output verbatim and exactly once, with its characters unchanged. You may move it if the instruction reorders the text, but never edit what is inside it, translate it, drop it, or replace it with a word like REDACTED."
                system = system.replacingOccurrences(of: def, with: "- " + rule)
            }
            if let extra = Self.env("PROBE_EXTRA_SYSTEM") { system += "\n" + extra }

            var cell = CellResult()
            var gateTally: [String: Int] = [:]
            for _ in 0..<reps {
                cell.total += 1
                let raw: String
                do { raw = try await client.complete(system: system, user: prompt.user, connection: conn) }
                catch { cell.failures.append("CLIENT_ERR: \(error)"); gateTally["clientError", default: 0] += 1; continue }
                switch ValidationGate.check(output: raw, issuedTokens: issued) {
                case .pass:
                    cell.survived += 1; gateTally["pass", default: 0] += 1
                case .fail(let f):
                    gateTally["\(f)", default: 0] += 1
                    cell.failures.append(oneLine(raw, 80))
                }
            }
            grandPass += cell.survived; grandTotal += cell.total
            let gateSummary = gateTally.sorted { $0.value > $1.value }
                .map { "\($0.key):\($0.value)" }.joined(separator: " ")
            print(pad(s.name, 16) + pad("\(issued.count)", 5)
                + pad("\(cell.survived)/\(cell.total)", 10) + pad(oneLine(gateSummary, 24), 26)
                + (cell.failures.first ?? ""))
        }
        print(pad("TOTAL", 16) + pad("", 5) + pad("\(grandPass)/\(grandTotal)", 10))
    }

    // Table B — sentinel bake-off. Same scenarios, an identical form-agnostic preserve prompt for
    // every candidate (the only variable is the sentinel characters), so we have data to pick a
    // replacement if Table A shows the current one is weak.
    private func tableB(client: HTTPLLMClient, conn: Connection, reps: Int) async throws {
        print("\n--- Table B · sentinel bake-off (identical prompt, sentinel is the only variable) ---")
        let colW = 12
        var header = pad("scenario", 16)
        for c in Self.candidates { header += padL(oneLine(c.name, colW - 1), colW) }
        print(header)

        var totals = Array(repeating: 0, count: Self.candidates.count)
        var totalReps = Array(repeating: 0, count: Self.candidates.count)
        var sampleFailures: [String] = []
        for s in Self.scenarios {
            var row = pad(s.name, 16)
            for (ci, cand) in Self.candidates.enumerated() {
                var idx: [String: Int] = [:]
                let tokenStrings = s.toks.map { t -> String in
                    switch t {
                    case .redact(let v): idx["REDACT", default: 0] += 1; _ = v; return cand.render("REDACT", idx["REDACT"]!)
                    case .verbatim(let v): idx["VERB", default: 0] += 1; _ = v; return cand.render("VERB", idx["VERB"]!)
                    }
                }
                let content = s.content(tokenStrings)
                let (sys, usr) = Self.bakeoffPrompt(scenario: s, content: content, tokens: tokenStrings)
                var survived = 0
                for _ in 0..<reps {
                    totalReps[ci] += 1
                    let raw: String
                    do { raw = try await client.complete(system: sys, user: usr, connection: conn) }
                    catch { sampleFailures.append("[\(cand.name)/\(s.name)] CLIENT_ERR \(error)"); continue }
                    let ok = tokenStrings.allSatisfy { raw.components(separatedBy: $0).count - 1 == 1 }
                    if ok { survived += 1; totals[ci] += 1 }
                    else if sampleFailures.count < 12 {
                        sampleFailures.append("[\(cand.name)/\(s.name)] \(oneLine(raw, 90))")
                    }
                }
                row += padL("\(survived)/\(reps)", colW)
            }
            print(row)
        }
        var totalRow = pad("TOTAL", 16)
        for (ci, _) in Self.candidates.enumerated() { totalRow += padL("\(totals[ci])/\(totalReps[ci])", 12) }
        print(totalRow)
        if !sampleFailures.isEmpty {
            print("\n  sample mangling / drops:")
            for f in sampleFailures { print("    " + f) }
        }
    }

    // Form-agnostic preserve prompt for the bake-off: lists the literal tokens (whatever their
    // shape), so the sentinel characters are the only thing varying across candidates.
    static func bakeoffPrompt(scenario s: Scenario, content: String, tokens: [String]) -> (String, String) {
        let list = tokens.joined(separator: ", ")
        let system = """
        You are a text transformation engine. Transform the text exactly as instructed and return ONLY the transformed text — no preamble, no explanation, no surrounding quotes or code fences.
        You MUST reproduce these placeholder tokens EXACTLY as written, each exactly once, unchanged. Never alter, translate, space out, renumber, drop, or replace them with a word: \(list).
        Write in English.
        """
        var instr = s.modePrompt
        let d = s.dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { instr += "\n" + d }
        let user = """
        <instructions>
        \(instr)
        </instructions>

        <content>
        \(content)
        </content>
        """
        return (system, user)
    }
}
