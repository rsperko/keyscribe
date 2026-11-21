import assert from "node:assert/strict"
import { spawn, execFileSync } from "node:child_process"
import { createServer, type IncomingMessage, type ServerResponse } from "node:http"
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { promptDigest } from "../../../Sources/KeyScribe/Resources/UltimateConnector/keyscribe.ts"

const clone = process.env.ULTIMATE_CLONE
const node = process.env.ULTIMATE_NODE ?? process.execPath
const model = process.env.ULTIMATE_MODEL ?? "openrouter/z-ai/glm-5.3-flash"
const port = Number(process.env.ULTIMATE_PORT ?? 4799)
if (!clone || !existsSync(join(clone, "bin/ultimate.ts"))) {
  console.error("test-ultimate-live: set ULTIMATE_CLONE to an Ultimate clone with pnpm install done")
  process.exit(2)
}

const sources = join(dirname(fileURLToPath(import.meta.url)), "../../../Sources/KeyScribe/Resources/UltimateConnector")
const root = realpathSync(mkdtempSync(join(tmpdir(), "ks-ultimate-live-")))
const user = join(root, "user")
const setup = join(user, ".ultimate")
const project = join(root, "project")
const bridge = join(root, "bridge")
const extension = join(setup, "extensions", "keyscribe")
for (const folder of [extension, project, bridge]) mkdirSync(folder, { recursive: true })
writeFileSync(join(setup, "onboarding.json"), JSON.stringify({ firstRunDone: true }))
writeFileSync(join(setup, "settings.json"), JSON.stringify({ onboarding: false }))
execFileSync("git", ["init", "-q", project])
writeFileSync(join(project, "README.md"), "A scratch project.\n")

const socketPath = join(bridge, "bridge.sock")
writeFileSync(join(bridge, "token"), "live-token\n")
writeFileSync(join(bridge, "ready.json"), JSON.stringify({ launch: "live", protocol: 3 }))
for (const name of ["server.ts", "keyscribe.ts", "web.tsx", "README.md"]) copyFileSync(join(sources, name), join(extension, name))
writeFileSync(join(extension, "keyscribe.json"), JSON.stringify({
  protocol: 3, socketPath, tokenPath: join(bridge, "token"), readyPath: join(bridge, "ready.json"), installation: "live",
  setup, version: "live", appName: "KeyScribe", plugin: "keyscribe",
}))

type Event = Record<string, any>
const events: Event[] = []
const unacknowledged = new Map<string, Event>()
let parked: ServerResponse | null = null
const body = (request: IncomingMessage) => new Promise<string>((resolve) => {
  let text = ""
  request.on("data", (chunk) => { text += chunk })
  request.on("end", () => resolve(text))
})
const server = createServer(async (request, response) => {
  assert.equal(request.headers.authorization, "Bearer live-token")
  const parsed = JSON.parse(await body(request))
  if (request.url === "/poll") {
    if (unacknowledged.size) return response.end(JSON.stringify([...unacknowledged.values()]))
    parked?.end("[]")
    parked = response
    return
  }
  events.push(parsed)
  if (parsed.op === "ack") unacknowledged.delete(parsed.request)
  if (parsed.op === "notify") return response.end(JSON.stringify({ spoken: true }))
  response.end(JSON.stringify(parsed.op === "hello" ? { quiet: false } : {}))
})
await new Promise<void>((resolve) => server.listen(socketPath, resolve))

function send(command: Event) {
  unacknowledged.set(command.id, command)
  if (parked) {
    const waiting = parked
    parked = null
    waiting.end(JSON.stringify([...unacknowledged.values()]))
  }
}

async function until<T>(what: string, find: () => T | undefined, seconds: number): Promise<T> {
  const end = Date.now() + seconds * 1000
  for (;;) {
    const found = find()
    if (found !== undefined) return found
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`)
    await new Promise((resolve) => setTimeout(resolve, 250))
  }
}

const environment = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("ULTIMATE_")))
const log = join(root, "ultimate.log")
const child = spawn(node, [join(clone, "bin/ultimate.ts"), project, "--port", String(port), "--no-open"], {
  env: { ...environment, ULTIMATE_USER_HOME: user, ULTIMATE_HOME: join(setup, "projects", "project-live"), ULTIMATE_MODEL: model, NO_COLOR: "1" },
  stdio: ["ignore", "pipe", "pipe"],
  detached: true,
})
const output: string[] = []
child.stdout.on("data", (chunk) => output.push(String(chunk)))
child.stderr.on("data", (chunk) => output.push(String(chunk)))

let failed = false
try {
  const origin = `http://127.0.0.1:${port}`
  const api = (path: string, payload?: object) =>
    fetch(origin + path, {
      method: payload ? "POST" : "GET",
      headers: { origin, "content-type": "application/json" },
      ...(payload ? { body: JSON.stringify(payload) } : {}),
    })
  const upBy = Date.now() + 180_000
  for (;;) {
    const answer = await api("/api/models").catch(() => null)
    if (answer?.ok) break
    if (Date.now() > upBy || child.exitCode !== null) throw new Error("Ultimate did not start serving")
    await new Promise((resolve) => setTimeout(resolve, 1000))
  }
  console.log("ultimate is up")
  const created = await (await api("/api/conversations", { title: "Live check" })).json() as { id: number }
  const projects = join(setup, "projects")
  const home = await until("the project home", () => readdirSync(projects).map((name) => join(projects, name)).find((path) => existsSync(join(path, "ultimate.lock"))), 30)
  const session = `${created.id}@${realpathSync(home)}`
  const hello = await until("the conversation's hello", () => events.find((e) => e.op === "hello" && e.session === session), 60)
  console.log("hello", hello.session, hello.features.join(","))
  assert.equal(hello.agent, "ultimate")
  assert.ok(hello.features.includes("label"))

  const action = async (extension: string, name: string, args: object) => {
    const answer = await api(`/api/extensions/${extension}/actions/${name}`, { args })
    assert.ok(answer.ok, `${extension}/${name} answered ${answer.status}`)
    return ((await answer.json()) as { result: any }).result
  }
  send({ op: "status", id: "live-label", expectedSession: session, text: "\u201Clive check\u201D" })
  for (let tries = 0; ; tries++) {
    const { label } = await action("keyscribe", "label", { conversation: created.id })
    if (label === "\u201Clive check\u201D") break
    if (tries > 60) throw new Error(`the page reads the label ${JSON.stringify(label)}`)
    await new Promise((resolve) => setTimeout(resolve, 250))
  }
  console.log("the page reads the name to say")

  await action("conversations", "rename", { id: created.id, title: "renamed live" })
  const retitled = await until("the renamed title", () => events.find((e) => e.op === "title" && e.session === session && e.text === "renamed live"), 30)
  console.log("renamed:", retitled.text)

  const untitled = (await (await api("/api/conversations", {})).json()) as { id: number }
  const branch = `${untitled.id}@${realpathSync(home)}`
  const greeted = await until("the untitled branch's hello", () => events.find((e) => e.op === "hello" && e.session === branch), 60)
  assert.equal(greeted.title, undefined)
  send({ op: "submit", id: "live-untitled", expectedSession: branch, text: "Reply with exactly one word: kiwi", expiresAt: Date.now() + 30_000 })
  await until("the untitled branch's reply", () => events.find((e) => e.op === "turnComplete" && e.session === branch), 180)
  await new Promise((resolve) => setTimeout(resolve, 8000))
  const named = events.filter((e) => e.op === "title" && e.session === branch && e.text)
  assert.deepEqual(named, [], "a branch titled from its first message or a summary is never reported as named")
  console.log("an untitled branch stays unnamed after its first reply")

  const said = "Reply with exactly one word: pineapple"
  send({ op: "submit", id: "live-1", expectedSession: session, text: said, expiresAt: Date.now() + 30_000 })
  const receipt = await until("the receipt", () => events.find((e) => e.op === "submitted" && e.request === "live-1"), 60)
  assert.ok(receipt.turn, "the receipt names the turn")
  const started = await until("the turn's start", () => events.find((e) => e.op === "turnStarted" && e.session === session), 60)
  assert.equal(started.turn, receipt.turn)
  const complete = await until("the reply", () => events.find((e) => e.op === "turnComplete" && e.session === session), 180)
  console.log("reply:", JSON.stringify(complete.answer))
  assert.equal(complete.reason, "complete")
  assert.match(complete.answer.toLowerCase(), /pineapple/)
  assert.equal(complete.prompt, promptDigest(said))
  const history = (await (await api(`/api/conversations/${created.id}/history?before=${Number.MAX_SAFE_INTEGER}`)).json()) as { entries: any[] }
  const typed = history.entries.filter((entry) => entry.input && entry.kind === "pi.user").map((entry) => JSON.stringify(entry.model))
  assert.ok(typed.some((model) => model.includes(said)), "Ultimate recorded the dictation as the user's own prompt")

  send({ op: "submit", id: "live-2", expectedSession: session, text: "Call the keyscribe_tell_me_when_done tool once, then reply with the word done.", expiresAt: Date.now() + 30_000 })
  const notify = await until("the read-aloud request", () => events.find((e) => e.op === "notify" && e.session === session), 180)
  assert.equal(notify.on, true)
  await until("the second reply", () => events.filter((e) => e.op === "turnComplete" && e.session === session).at(1), 180)
  const finished = () => events.filter((e) => e.op === "turnComplete" && e.session === session).length
  const before = finished()
  send({ op: "submit", id: "live-3", expectedSession: session, text: "Run `ls -la` and then `sleep 8` with your shell tool, then reply with what you found.", expiresAt: Date.now() + 30_000 })
  const running = await until("the tool turn's start", () => events.filter((e) => e.op === "turnStarted" && e.session === session).at(2), 120)
  send({ op: "submit", id: "live-4", expectedSession: session, text: "Also end your reply with the word mango.", expiresAt: Date.now() + 30_000 })
  const steered = await until("the steer's receipt", () => events.find((e) => e.op === "submitted" && e.request === "live-4"), 60)
  if (finished() === before) {
    assert.equal(steered.turn, "", "a dictation for a working conversation is confirmed when queued")
    const absorbed = await until("the steer's absorption", () => events.find((e) => e.op === "absorbed" && e.session === session), 180)
    assert.equal(absorbed.turn, running.turn)
    assert.equal(absorbed.prompt, promptDigest("Also end your reply with the word mango."))
    console.log("steered into", absorbed.turn)
  } else console.log("the tool turn ended before the steer arrived; it started its own turn")
  const last = await until("the reply after the steer", () => events.filter((e) => e.op === "turnComplete" && e.session === session).find((e) => /mango/i.test(e.answer)), 240)
  console.log("steered reply:", JSON.stringify(last.answer.slice(-120)))
  console.log("test-ultimate-live: passed")
} catch (error) {
  failed = true
  console.error("test-ultimate-live: FAILED:", error)
  console.error("events:", JSON.stringify(events, null, 1).slice(-6000))
  console.error("ultimate output tail:", output.join("").slice(-4000))
} finally {
  writeFileSync(log, output.join(""))
  try {
    process.kill(-child.pid!, "SIGTERM")
  } catch {}
  await new Promise((resolve) => setTimeout(resolve, 2000))
  try {
    process.kill(-child.pid!, "SIGKILL")
  } catch {}
  parked?.end("[]")
  server.close()
  if (!failed) rmSync(root, { recursive: true, force: true })
  else console.error("kept", root)
  process.exit(failed ? 1 : 0)
}

