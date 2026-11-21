import { spawnSync } from "node:child_process"
import { writeFileSync } from "node:fs"
import { join } from "node:path"
import { fileURLToPath } from "node:url"
import { exercises, removal, type Context, type Exercise } from "./exercises.ts"
import { BBDriver } from "./lib/bb.ts"
import { ClaudeDriver } from "./lib/claude.ts"
import { CodexDriver } from "./lib/codex.ts"
import type { AgentDriver } from "./lib/driver.ts"
import { Instance } from "./lib/instance.ts"
import { OmpDriver, PiDriver } from "./lib/pi.ts"
import { UltimateDriver } from "./lib/ultimate.ts"
import { failureBundle } from "./lib/artifacts.ts"
import { parseRunOptions } from "./lib/options.ts"

const drivers: Record<string, (name: string) => AgentDriver> = {
  claude: (name) => new ClaudeDriver(name),
  pi: (name) => new PiDriver(name),
  omp: (name) => new OmpDriver(name),
  codex: (name) => new CodexDriver(name),
  bb: (name) => new BBDriver(name),
  ultimate: (name) => new UltimateDriver(name),
}

const options = parseRunOptions(process.argv.slice(2), process.env)
const agentKind = options.agent
if (!agentKind || (!drivers[agentKind] && agentKind !== "all")) {
  console.error(`usage: run.ts --agent <${Object.keys(drivers).join("|")}|all> [--only D1,R1] [--fail-fast] [--repeat N] [--keep]`)
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
const { only, failFast, repeat, keep, replyWait } = options

const binary = Instance.locate()
const instance = new Instance(binary)
const agent = drivers[agentKind]("kestrel")
const context: Context = { instance, agent, replyWait }
const results: { id: string; title: string; ok: boolean; why?: string; seconds: number }[] = []
let cleaning: Promise<void> | undefined
function cleanup(preserve: boolean) {
  return cleaning ??= (async () => {
    try { await agent.stop(keep) }
    finally { await instance.dispose(preserve) }
  })()
}
for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.once(signal, () => {
    console.error(`Conformance interrupted by ${signal}`)
    void cleanup(true).finally(() => process.exit(1))
  })
}

async function attempt(exercise: Exercise): Promise<boolean> {
  if (exercise.applies && !exercise.applies(agent)) {
    console.log(`N/A  ${exercise.id} ${exercise.title} (does not apply to ${agentKind})`)
    return true
  }
  const started = Date.now()
  try {
    await exercise.run(context)
    results.push({ id: exercise.id, title: exercise.title, ok: true, seconds: (Date.now() - started) / 1000 })
  } catch (error) {
    results.push({ id: exercise.id, title: exercise.title, ok: false, why: (error as Error).message, seconds: (Date.now() - started) / 1000 })
    await failureBundle(instance.folder, `${agentKind}/${exercise.id}`, error, {
      "agent-history": () => agent.messages(),
      "discovery": () => instance.cli(["--discovery-report"], 15),
      ...(agent.diagnostics?.() ?? {}),
    }).catch(failure => console.error(`Could not capture failure evidence: ${failure}`))
  }
  writeFileSync(join(instance.folder, "conformance.json"), JSON.stringify({ agent: agentKind, results }, null, 2))
  const last = results.at(-1)!
  console.log(`${last.ok ? "PASS" : "FAIL"} ${last.id} ${last.title} (${last.seconds.toFixed(1)} s)${last.why ? `\n     ${last.why}` : ""}`)
  return last.ok
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
  let stopEarly = false
  for (let round = 0; round < repeat && !stopEarly; round++) {
    for (const exercise of exercises) {
      if (only && !only.includes(exercise.id)) continue
      const ok = await attempt(exercise)
      if (!ok && failFast) { stopEarly = true; break }
    }
  }
  if (!stopEarly && (!only || only.includes(removal.id))) await attempt(removal)
} catch (error) {
  setupFailure = (error as Error).stack ?? String(error)
  console.log(`SETUP FAILED\n${setupFailure}`)
  await failureBundle(instance.folder, `${agentKind}/setup`, error, {
    ...(agent.diagnostics?.() ?? {}),
  }).catch(failure => console.error(`Could not capture setup evidence: ${failure}`))
} finally {
  const preserve = keep || !!setupFailure || results.some(result => !result.ok)
  await cleanup(preserve)
  if (preserve) console.log(`kept: ${instance.folder}${keep ? `, ${agent.folder}` : ""}`)
}

const failed = results.filter((result) => !result.ok).length
console.log(`agent-conformance: ${results.length - failed} passed, ${failed} failed${setupFailure ? ", setup failed" : ""}`)
process.exit(setupFailure || failed ? 1 : 0)
