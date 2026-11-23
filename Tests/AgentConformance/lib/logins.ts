import { spawnSync } from "node:child_process"
import { chmodSync, copyFileSync, existsSync, readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const readToml = `import json, sys, tomllib
print(json.dumps(tomllib.loads(sys.stdin.read()), default=str))`

function parseToml(text: string): Record<string, any> {
  const python = process.env.PYTHON_BIN ?? "python3"
  const parsed = spawnSync(python, ["-I", "-c", readToml], { input: text, encoding: "utf8", timeout: 30_000 })
  if (parsed.status !== 0) {
    throw new Error(`could not read the Codex configuration that names your provider with ${python} (it needs Python 3.11 or later; set PYTHON_BIN): ${(parsed.stderr || parsed.error?.message || "").trim()}`)
  }
  return JSON.parse(parsed.stdout)
}

const key = (name: string) => (/^[A-Za-z0-9_-]+$/.test(name) ? name : JSON.stringify(name))
const scalar = (value: unknown): string => (Array.isArray(value) ? `[${value.map(scalar).join(", ")}]` : JSON.stringify(value))
const isTable = (value: unknown) => typeof value === "object" && value !== null && !Array.isArray(value)
const isTables = (value: unknown) => Array.isArray(value) && value.length > 0 && value.every(isTable)

export function tomlTable(path: string[], table: Record<string, unknown>, header = `[${path.map(key).join(".")}]`): string[] {
  const lines = [header]
  for (const [name, value] of Object.entries(table)) if (!isTable(value) && !isTables(value)) lines.push(`${key(name)} = ${scalar(value)}`)
  for (const [name, value] of Object.entries(table)) {
    if (isTable(value)) lines.push("", ...tomlTable([...path, name], value as Record<string, unknown>))
    if (isTables(value)) {
      for (const item of value as Record<string, unknown>[]) {
        lines.push("", ...tomlTable([...path, name], item, `[[${[...path, name].map(key).join(".")}]]`))
      }
    }
  }
  return lines
}

export function codexLoginConfig(config: string): { top: string[]; tables: string[] } {
  if (!/\bmodel_provider\b/.test(config)) return { top: [], tables: [] }
  const parsed = parseToml(config)
  const chosen = parsed.model_provider
  if (typeof chosen !== "string") return { top: [], tables: [] }
  const provider = parsed.model_providers?.[chosen]
  return {
    top: [`model_provider = ${JSON.stringify(chosen)}`],
    tables: isTable(provider) ? tomlTable(["model_providers", chosen], provider) : [],
  }
}

const runChooses = new Set(["CLAUDE_CONFIG_DIR", "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_SMALL_FAST_MODEL"])

export function claudeLoginSettings(settings: Record<string, unknown>): Record<string, unknown> {
  const kept: Record<string, unknown> = {}
  if (settings.apiKeyHelper !== undefined) kept.apiKeyHelper = settings.apiKeyHelper
  if (isTable(settings.env)) {
    const env = Object.fromEntries(Object.entries(settings.env as Record<string, unknown>).filter(([name]) => !runChooses.has(name)))
    if (Object.keys(env).length) kept.env = env
  }
  return kept
}

export function copyCodexLogin(from: string, home: string, why: string) {
  const auth = join(from, "auth.json")
  const provider = codexLoginConfig(existsSync(join(from, "config.toml")) ? readFileSync(join(from, "config.toml"), "utf8") : "")
  if (!existsSync(auth) && !provider.top.length) throw new Error(`no Codex login at ${from}: ${why} (or set CODEX_AUTH_HOME)`)
  if (existsSync(auth)) {
    copyFileSync(auth, join(home, "auth.json"))
    chmodSync(join(home, "auth.json"), 0o600)
  }
  return provider
}

export function claudeCredential(login: Record<string, unknown>, environment: NodeJS.ProcessEnv) {
  const copied = (login.env ?? {}) as Record<string, string | undefined>
  const apiKey = copied.ANTHROPIC_API_KEY ?? environment.ANTHROPIC_API_KEY
  const usable = !!(apiKey || copied.CLAUDE_CODE_OAUTH_TOKEN || environment.CLAUDE_CODE_OAUTH_TOKEN || login.apiKeyHelper)
  return { usable, apiKey }
}

export function claudeLoginFile(environment: NodeJS.ProcessEnv) {
  return join(environment.CLAUDE_LOGIN_HOME ?? join(environment.HOME ?? homedir(), ".claude"), "settings.json")
}

export function codexLoginHome(environment: NodeJS.ProcessEnv) {
  return environment.CODEX_AUTH_HOME ?? join(environment.HOME ?? homedir(), ".codex")
}

export function loginProblem(agent: string, environment: NodeJS.ProcessEnv): string | undefined {
  if (agent === "claude") {
    const from = claudeLoginFile(environment)
    const login = claudeLoginSettings(existsSync(from) ? JSON.parse(readFileSync(from, "utf8")) : {})
    if (claudeCredential(login, environment).usable) return undefined
    return `a scratch Claude Code folder has no login: set CLAUDE_CODE_OAUTH_TOKEN (claude setup-token) or ANTHROPIC_API_KEY, or give ${from} an apiKeyHelper (or set CLAUDE_LOGIN_HOME)`
  }
  if (agent === "codex") {
    const from = codexLoginHome(environment)
    if (existsSync(join(from, "auth.json"))) return undefined
    const config = join(from, "config.toml")
    if (existsSync(config) && codexLoginConfig(readFileSync(config, "utf8")).top.length) return undefined
    return `no Codex login at ${from}: neither auth.json nor a model_provider in config.toml (or set CODEX_AUTH_HOME)`
  }
  return undefined
}
