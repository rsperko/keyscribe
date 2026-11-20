import { spawnSync } from "node:child_process"
import { fileURLToPath } from "node:url"
import { exercises, removal, type Context, type Exercise } from "./exercises.ts"
import { BBDriver } from "./lib/bb.ts"
import { ClaudeDriver } from "./lib/claude.ts"
import { CodexDriver } from "./lib/codex.ts"
import type { AgentDriver } from "./lib/driver.ts"
import { Instance } from "./lib/instance.ts"
import { OmpDriver, PiDriver } from "./lib/pi.ts"
import { UltimateDriver } from "./lib/ultimate.ts"

const drivers: Record<string, (name: string) => AgentDriver> = {
  claude: (name) => new ClaudeDriver(name),
  pi: (name) => new PiDriver(name),
  omp: (name) => new OmpDriver(name),
  codex: (name) => new CodexDriver(name),
  bb: (name) => new BBDriver(name),
  ultimate: (name) => new UltimateDriver(name),
}

const argument = (flag: string) => {
  const index = process.argv.indexOf(flag)
  return index >= 0 ? process.argv[index + 1] : undefined
}
const agentKind = argument("--agent") ?? process.env.AGENT
if (!agentKind || (!drivers[agentKind] && agentKind !== "all")) {
  console.error(`usage: run.ts --agent <${Object.keys(drivers).join("|")}|all> [--only D1,R1] [--keep]`)
  process.exit(2)
}
if (agentKind === "all") {
  const passthrough = process.argv.slice(2).filter((_, index, args) => args[index] !== "--agent" && args[index - 1] !== "--agent")
  const outcomes = Object.keys(drivers).map((kind) => {
    console.log(`\n=== ${kind} ===`)
    const ran = spawnSync(process.execPath, [fileURLToPath(import.meta.url), "--agent", kind, ...passthrough], { stdio: "inherit" })
    return `${kind}: ${ran.status === 0 ? "passed" : "FAILED"}`
  })
  console.log(`\n${outcomes.join("\n")}`)
  process.exit(outcomes.some((line) => line.endsWith("FAILED")) ? 1 : 0)
}
const only = argument("--only")?.split(",")
const keep = process.argv.includes("--keep") || process.env.KEEP === "1"
const replyWait = Number(process.env.REPLY_WAIT ?? 120)

const binary = Instance.locate()
const instance = new Instance(binary)
const agent = drivers[agentKind]("kestrel")
const context: Context = { instance, agent, replyWait }
const results: { id: string; title: string; ok: boolean; why?: string; seconds: number }[] = []

async function attempt(exercise: Exercise) {
  const started = Date.now()
  try {
    await exercise.run(context)
    results.push({ id: exercise.id, title: exercise.title, ok: true, seconds: (Date.now() - started) / 1000 })
  } catch (error) {
    results.push({ id: exercise.id, title: exercise.title, ok: false, why: (error as Error).message, seconds: (Date.now() - started) / 1000 })
  }
  const last = results.at(-1)!
  console.log(`${last.ok ? "PASS" : "FAIL"} ${last.id} ${last.title} (${last.seconds.toFixed(1)} s)${last.why ? `\n     ${last.why}` : ""}`)
}

let setupFailure: string | undefined
try {
  console.log(`agent-conformance: ${agentKind}, KeyScribe ${binary}, instance ${instance.folder}`)
  await agent.setUp()
  await instance.prepare()
  const installed = instance.connector("install", agent.kind, agent.folder, agent.tool)
  console.log(`install: ${installed.stdout.trim() || installed.stderr.trim()}`)
  await instance.launch()
  await agent.start()
  console.log(`conversation: ${agent.conversation} named ${agent.name}`)
  for (const exercise of exercises) if (!only || only.includes(exercise.id)) await attempt(exercise)
  if (!only || only.includes(removal.id)) await attempt(removal)
} catch (error) {
  setupFailure = (error as Error).stack ?? String(error)
  console.log(`SETUP FAILED\n${setupFailure}`)
} finally {
  await agent.stop(keep)
  await instance.dispose(keep)
  if (keep) console.log(`kept: ${instance.folder}, ${agent.folder}`)
}

const failed = results.filter((result) => !result.ok).length
console.log(`agent-conformance: ${results.length - failed} passed, ${failed} failed${setupFailure ? ", setup failed" : ""}`)
process.exit(setupFailure || failed ? 1 : 0)
