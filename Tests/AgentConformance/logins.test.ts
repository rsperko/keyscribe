import assert from "node:assert/strict"
import { test } from "node:test"
import { claudeCredential, claudeLoginSettings, codexLoginConfig } from "./lib/logins.ts"

test("a Codex login set up in its configuration keeps only its chosen provider, however the file is written", () => {
  const config = [
    `model = "big"`,
    `model_provider = "proxy" # the work proxy`,
    `approval_policy = "never"`,
    `instructions = """`,
    `[model_providers.fake]`,
    `name = "inside a string"`,
    `"""`,
    "",
    `[model_providers.proxy] # comment after a header`,
    `name = "Proxy"`,
    `base_url = "https://proxy.example/v1"`,
    `http_headers = { "x-team" = "a" }`,
    "",
    `[model_providers.proxy.auth]`,
    `command = "proxy-token"`,
    `args = ["--quiet"]`,
    "",
    `[model_providers.other]`,
    `name = "Other"`,
    "",
    `[mcp_servers.example] # comment`,
    `command = "secret-server"`,
    "",
    `[projects."/Users/me/src/app"]`,
    `trust_level = "trusted"`,
  ].join("\n")
  const login = codexLoginConfig(config)
  assert.deepEqual(login.top, [`model_provider = "proxy"`])
  assert.deepEqual(login.tables, [
    `[model_providers.proxy]`,
    `name = "Proxy"`,
    `base_url = "https://proxy.example/v1"`,
    "",
    `[model_providers.proxy.http_headers]`,
    `x-team = "a"`,
    "",
    `[model_providers.proxy.auth]`,
    `command = "proxy-token"`,
    `args = ["--quiet"]`,
  ])
  assert.ok(!login.tables.join("\n").includes("secret-server") && !login.tables.join("\n").includes("inside a string"))
  assert.deepEqual(codexLoginConfig(`model = "big"\n[projects."/x"]\ntrust_level = "trusted"\n`), { top: [], tables: [] })
})

test("the provider copied into the scratch configuration reads back as the same provider", () => {
  const login = codexLoginConfig(`model_provider = "p"\n[model_providers.p]\nname = "a \\"quoted\\" name"\nretries = 3\nwire = true\n`)
  const copied = [...login.top, "", ...login.tables].join("\n")
  assert.deepEqual(codexLoginConfig(copied), login)
})

test("a Claude Code login from its settings keeps the key helper and its environment, nothing else", () => {
  assert.deepEqual(claudeLoginSettings({ apiKeyHelper: "~/bin/key", env: { ANTHROPIC_BASE_URL: "https://proxy.example" }, hooks: { Stop: [] }, model: "opus" }),
    { apiKeyHelper: "~/bin/key", env: { ANTHROPIC_BASE_URL: "https://proxy.example" } })
  assert.deepEqual(claudeLoginSettings({ hooks: {} }), {})
})

test("a Claude Code login counts wherever the copied setup or the run's environment holds it, and the key it approves is the one it uses", () => {
  assert.deepEqual(claudeCredential({ env: { ANTHROPIC_API_KEY: "sk-from-settings" } }, {}), { usable: true, apiKey: "sk-from-settings" })
  assert.deepEqual(claudeCredential({ env: { CLAUDE_CODE_OAUTH_TOKEN: "token" } }, {}), { usable: true, apiKey: undefined })
  assert.deepEqual(claudeCredential({ apiKeyHelper: "~/bin/key" }, {}), { usable: true, apiKey: undefined })
  assert.deepEqual(claudeCredential({}, { ANTHROPIC_API_KEY: "sk-env" }), { usable: true, apiKey: "sk-env" })
  assert.deepEqual(claudeCredential({ env: { ANTHROPIC_BASE_URL: "https://proxy.example" } }, {}), { usable: false, apiKey: undefined })
})

test("a provider's lists of tables are copied as lists of tables", () => {
  const login = codexLoginConfig([
    `model_provider = "p"`, `[model_providers.p]`, `name = "P"`,
    `[[model_providers.p.fallbacks]]`, `url = "https://a.example"`, `[[model_providers.p.fallbacks]]`, `url = "https://b.example"`,
  ].join("\n"))
  assert.deepEqual(login.tables, [
    `[model_providers.p]`, `name = "P"`, "",
    `[[model_providers.p.fallbacks]]`, `url = "https://a.example"`, "",
    `[[model_providers.p.fallbacks]]`, `url = "https://b.example"`,
  ])
  assert.deepEqual(codexLoginConfig([...login.top, ...login.tables].join("\n")), login)
})

test("a Claude Code login never carries over the settings the run chooses itself", () => {
  assert.deepEqual(claudeLoginSettings({ env: { CLAUDE_CONFIG_DIR: "/Users/me/.claude", ANTHROPIC_MODEL: "opus", ANTHROPIC_BASE_URL: "https://proxy.example" } }),
    { env: { ANTHROPIC_BASE_URL: "https://proxy.example" } })
  assert.deepEqual(claudeLoginSettings({ env: { CLAUDE_CONFIG_DIR: "/Users/me/.claude" } }), {})
})
