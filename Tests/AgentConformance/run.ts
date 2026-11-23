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
import { clipboard, withClipboard } from "./lib/clipboard.ts"
import { parseRunOptions } from "./lib/options.ts"
import { homeChanges, snapshotHome } from "./lib/home-audit.ts"
import { inputUnseen, voiceOverBlocks, voiceOverOn } from "./lib/preflight.ts"
import { awayWindow, terminalHost } from "./lib/terminal.ts"
import { shutDown, stopEach, until } from "./lib/util.ts"

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

function auditHome(): ReturnType<typeof snapshotHome> | string {
  try { return snapshotHome() } catch (error) { return (error as Error).message }
}
const homeBefore = auditHome()
if (typeof homeBefore === "string") {
  console.log(`SETUP FAILED\n${homeBefore}`)
  process.exit(1)
}
let away: ReturnType<typeof awayWindow>
try {
  const host = terminalHost()
  host.check()
  away = awayWindow(host)
} catch (error) {
  console.log(`SETUP FAILED\n${(error as Error).message}`)
  process.exit(1)
}
const binary = Instance.locate()
const instance = new Instance(binary)
const agent = drivers[agentKind]("kestrel")
const context: Context = {
  instance, agent, away, replyWait,
  clipboard: { set: (kind, value) => clipboard(kind, ...(value === undefined ? [] : [value])), keep: withClipboard },
}
const results: { id: string; title: string; ok: boolean; why?: string; seconds: number }[] = []
let cleaning: Promise<void> | undefined
function cleanup(preserve: boolean) {
  return cleaning ??= (async () => {
    await shutDown(() => stopEach(() => away.close(), () => agent.stop(keep)), (kept) => instance.dispose(kept), preserve)
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
      "discovery": () => instance.cli(["--discovery-report", agent.kind, "--folder", agent.folder], 15),
      ...(agent.diagnostics?.() ?? {}),
    }).catch(failure => console.error(`Could not capture failure evidence: ${failure}`))
  }
  writeFileSync(join(instance.folder, "conformance.json"), JSON.stringify({ agent: agentKind, results }, null, 2))
  const last = results.at(-1)!
  console.log(`${last.ok ? "PASS" : "FAIL"} ${last.id} ${last.title} (${last.seconds.toFixed(1)} s)${last.why ? `\n     ${last.why}` : ""}`)
  return last.ok
}

let setupFailure: string | undefined
let stopFailure: string | undefined
try {
  console.log(`agent-conformance: ${agentKind}, KeyScribe ${binary}, instance ${instance.folder}`)
  if (voiceOverOn()) throw new Error(voiceOverBlocks)
  await instance.prepare()
  await instance.launch()
  const probe = instance.take("check on all")
  if (probe.observesInput === false) throw new Error(inputUnseen(binary))
  if (probe.observesInput === undefined) throw new Error(`the test instance could not answer whether it sees input: ${probe.problem ?? JSON.stringify(probe)}`)
  await instance.quit()
  await agent.setUp()
  const installed = instance.connector("install", agent.kind, agent.folder, agent.tool)
  console.log(`install: ${installed.stdout.trim() || installed.stderr.trim()}`)
  await instance.launch()
  await agent.start()
  console.log(`conversation: ${agent.conversation} named ${agent.name}`)
  await until("the app to know the conversation by its name", () => (instance.take(`check on ${agent.name}`).ok ? true : undefined), 90, 3000)
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
  await cleanup(preserve).catch((error) => {
    stopFailure = (error as Error).message
    console.log(`FAIL the run could not stop the agent: ${stopFailure}`)
  })
  if (preserve || stopFailure) console.log(`kept: ${instance.folder}${keep || stopFailure ? `, ${agent.folder}` : ""}`)
}

const homeAfter = auditHome()
const touched = typeof homeAfter === "string" ? [homeAfter] : homeChanges(homeBefore, homeAfter)
if (touched.length) console.log(`FAIL the run changed the user's own setup outside its scratch folders:\n     ${touched.join("\n     ")}`)
const failed = results.filter((result) => !result.ok).length
console.log(`agent-conformance: ${results.length - failed} passed, ${failed} failed${setupFailure ? ", setup failed" : ""}${stopFailure ? ", agent not stopped" : ""}${touched.length ? ", user's setup changed" : ""}`)
process.exit(setupFailure || stopFailure || failed || touched.length ? 1 : 0)
