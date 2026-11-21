import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { createRequire } from "node:module"
import { existsSync, openSync, readFileSync, readdirSync, symlinkSync, writeFileSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { Instance, type TakeResult } from "./lib/instance.ts"
import { UltimateDriver } from "./lib/ultimate.ts"
import { freePort, run, sha256, until } from "./lib/util.ts"

const clone = process.env.ULTIMATE_CLONE
assert.ok(clone, "set ULTIMATE_CLONE to an installed Ultimate checkout")
const { chromium } = createRequire(join(resolve(clone), "package.json"))("playwright-core")
const repository = resolve(dirname(fileURLToPath(import.meta.url)), "../..")
const instance = new Instance(Instance.locate())
const agent = new UltimateDriver("kestrel")
const keep = process.argv.includes("--keep")
const replyWait = Number(process.env.REPLY_WAIT ?? 90)
let browser: any
let clipboardSaved = false
let failure: unknown
let cleaning: Promise<void> | undefined
let stopping = false
const results: { case: string; conversation: number; ok: boolean; why?: string }[] = []
const clipboardFile = join(instance.folder, "clipboard.plist")

function command(tool: string, args: string[], timeout = 30) {
  const answer = run(tool, args, { timeout })
  assert.equal(answer.status, 0, `${tool} failed: ${answer.stdout}${answer.stderr}`)
  return answer.stdout
}
const clipboard = (...args: string[]) => command("xcrun", ["swift", join(repository, "Tests/AgentConformance/clipboard.swift"), ...args])
function cleanup() {
  return cleaning ??= (async () => {
    if (clipboardSaved) clipboard("restore", clipboardFile)
    await browser?.close()
    await agent.stop(keep || !!failure)
    await instance.dispose(keep || !!failure)
  })()
}
process.once("SIGTERM", () => { stopping = true; failure = new Error("conformance interrupted"); void cleanup().finally(() => process.exit(1)) })
process.once("SIGINT", () => { stopping = true; failure = new Error("conformance interrupted"); void cleanup().finally(() => process.exit(1)) })
const request = async (path: string, payload?: object) => {
  const response = await agent.api(path, payload)
  assert.ok(response.ok, `${path} answered ${response.status}: ${await response.clone().text()}`)
  return await response.json() as any
}
const action = async (extension: string, name: string, args: object | null, conversationId?: number) =>
  (await request(`/api/extensions/${extension}/actions/${name}`, { args, conversationId })).result
async function summaries(): Promise<any[]> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 10_000)
  try {
    const response = await fetch(`${agent.url}/api/events`, { headers: { origin: agent.url }, signal: controller.signal })
    const reader = response.body!.getReader()
    const decoder = new TextDecoder()
    let text = ""
    for (;;) {
      const { value, done } = await reader.read()
      if (done) break
      text += decoder.decode(value, { stream: true })
      for (const block of text.split("\n\n").slice(0, -1)) {
        const lines = block.split("\n")
        if (lines[0] === "event: conversations") return JSON.parse(lines.filter(line => line.startsWith("data: ")).at(-1)!.slice(6))
      }
    }
    throw new Error("Ultimate's event stream ended before it listed its conversations")
  } finally {
    clearTimeout(timer)
    controller.abort()
  }
}
const fileListing = () => JSON.parse(readFileSync(join(agent.projectHome, "conversations.json"), "utf8")) as any[]
const key = (id: number) => `ultimate:${id}@${agent.projectHome}`
const name = (id: number) => `ultimate ${id}`
const take = (text: string, reply = false) => {
  assert.ok(!stopping, "conformance interrupted")
  return instance.take(text, { timeout: 45, ...(reply ? { waitReply: replyWait } : {}) })
}
const records = () => readdirSync(join(instance.folder, "history")).filter(f => f.endsWith(".jsonl"))
  .flatMap(f => readFileSync(join(instance.folder, "history", f), "utf8").trim().split("\n").filter(Boolean).map(line => JSON.parse(line)))
const record = (text: string) => records().filter(e => e.heard === text || e.heard?.endsWith(text)).at(-1)
let chromeWindow = ""
let otherWindow = ""

function windows() {
  const lines = instance.cli(["--windows-probe"], 30).stdout.split("\n")
  let app = "", pid = ""
  return lines.flatMap(line => {
    const process = /^(\S+) pid=(\d+)/.exec(line)
    if (process) { app = process[1]; pid = process[2] }
    const window = /AXStandardWindow id=(cg:\d+).*title=(.*)/.exec(line)
    return window ? [{ app, spec: `${pid}:${window[1]}`, title: window[2] }] : []
  })
}
function focus(spec: string) {
  const result = instance.cli(["--windows-probe", "--focus", spec], 15)
  assert.equal(result.status, 0, result.stdout + result.stderr)
}
async function shown(page: any, id: number, side?: number) {
  await request("/api/ui", { set: { "shell.surface": "agent", "shell.conversation": id,
    "ext.side-chat.front": side ?? null } })
  const editor = page.locator(`textarea[data-conversation="${side ?? id}"]:visible`).filter({ visible: true })
  await editor.waitFor({ state: "visible", timeout: 60_000 })
  focus(chromeWindow)
  await editor.focus()
  await page.waitForFunction(() => document.hasFocus() && document.visibilityState === "visible")
  return editor
}
async function delivered(id: number, text: string, explicit = true, reply = true): Promise<TakeResult> {
  const result = take(explicit ? `tell ${name(id)}, ${text}` : text, reply)
  assert.equal(result.ok, true, JSON.stringify(result))
  assert.equal(result.conversation, key(id), JSON.stringify(result))
  await until("Ultimate's own record of the take", async () =>
    (await agent.messages(id)).some(m => m.role === "user" && m.text.includes(text)) ? true : undefined, 30)
  if (reply) {
    assert.ok(result.reply, JSON.stringify(result))
    const messages = await agent.messages(id)
    const input = messages.filter(m => m.role === "user" && m.text.includes(text)).at(-1)!
    const answer = messages.filter(m => m.role === "agent" && m.turn === input.turn).at(-1)
    assert.ok(answer, "the take has its own reply")
    assert.equal(result.reply!.sha256, sha256(answer.text))
  }
  return result
}
async function attempt(id: number, label: string, test: () => Promise<void>) {
  assert.ok(!stopping, "conformance interrupted")
  const started = Date.now()
  try { await test(); results.push({ case: label, conversation: id, ok: true }) }
  catch (error) { results.push({ case: label, conversation: id, ok: false,
    why: `${String(error)}${error instanceof Error && error.cause ? `; cause: ${String(error.cause)}` : ""}` }) }
  const result = results.at(-1)!
  console.log(`${result.ok ? "PASS" : "FAIL"} #${id} ${label} ${((Date.now() - started) / 1000).toFixed(1)}s${result.why ? ` ${result.why}` : ""}`)
  writeFileSync(join(instance.folder, "conformance.json"), JSON.stringify(results, null, 2))
}

try {
  console.log(`Ultimate page conformance: ${instance.folder}, ${agent.root}`)
  await agent.setUp()
  writeFileSync(join(agent.folder, "settings.json"), JSON.stringify({ onboarding: true, extensions: { disable: ["sample-unrelated-extension"] } }))
  command("git", ["-C", agent.project, "fetch", "--depth=1", repository, "HEAD"])
  command("git", ["-C", agent.project, "reset", "--hard", "FETCH_HEAD"])
  await instance.prepare()
  const settings = join(instance.folder, "settings.toml")
  writeFileSync(settings, readFileSync(settings, "utf8").replace(/\[agents\.spoken_result\][\s\S]*?(?=\n\[|$)/,
    "[agents.spoken_result]\nenabled = true\ntext_only = true\n"))
  const linked = join(agent.root, "linked-setup")
  symlinkSync(agent.folder, linked)
  const installed = instance.connector("install", "ultimate", linked, agent.tool)
  assert.equal(installed.status, 0, installed.stdout + installed.stderr)
  const installedPlugin = readdirSync(join(agent.folder, "extensions")).find(name => existsSync(join(agent.folder, "extensions", name, "keyscribe.json")))
  assert.ok(installedPlugin, "the installed connector has its configuration")
  await instance.launch()
  await agent.start()
  await action("onboarding", "firstRunDone", null)
  const main = await action("subagents", "standing", { name: "ultimate" }) as number
  clipboard("save", clipboardFile)
  clipboardSaved = true
  const debugPort = await freePort()
  const chromeLog = openSync(join(agent.root, "chrome.log"), "a")
  spawn(process.env.CHROME_BIN ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", [
    `--user-data-dir=${join(agent.root, "chrome")}`, `--remote-debugging-port=${debugPort}`,
    "--no-first-run", "--no-default-browser-check", `--app=${agent.url}/?conversation=${main}`,
  ], { stdio: ["ignore", chromeLog, chromeLog], detached: true })
  await until("Chrome's debugging endpoint", async () =>
    (await fetch(`http://127.0.0.1:${debugPort}/json/version`).catch(() => null))?.ok ? true : undefined, 30)
  browser = await chromium.connectOverCDP(`http://127.0.0.1:${debugPort}`)
  const page = browser.contexts()[0].pages()[0]
  page.setDefaultTimeout(30_000)
  await page.goto(`${agent.url}/?conversation=${main}`)
  assert.equal(await page.evaluate(() => navigator.webdriver), false, "the conformance page must share navigation like an ordinary browser")
  await page.locator(`textarea[data-conversation="${main}"]:visible`).waitFor({ timeout: 60_000 })
  console.log("The standing agent's visible composer is ready")
  chromeWindow = await until("the native Chrome app window", () => windows().find(w => w.title.includes(agent.project))?.spec, 30)
  otherWindow = windows().find(w => w.app !== "com.google.Chrome" && w.app !== "com.keyscribe.app.dev")!.spec
  assert.ok(otherWindow, "the run needs another native app window")
  await attempt(main, "first-run dialog holds and names the obstruction", async () => {
    focus(chromeWindow)
    await page.keyboard.press("Meta+k")
    await page.getByPlaceholder("Run a command…").fill("Get ready")
    await page.getByRole("option", { name: "Get ready…", exact: true }).click()
    await page.getByRole("heading", { name: "Get ready", exact: true }).waitFor()
    await page.waitForTimeout(500)
    const result = take("Reply with only modalblocked.")
    assert.equal(result.ok, false, JSON.stringify(result))
    assert.match(result.hud ?? "", /dialog covers/, JSON.stringify(result))
    assert.ok(!(await agent.messages(main)).some(m => m.text.includes("modalblocked")))
    await page.getByRole("button", { name: "Close", exact: true }).click()
  })
  assert.equal(results.at(-1)?.ok, true, "the dialog fixture must close before delivery cases start")
  await attempt(main, "a dialog shown by a style change alone holds within a heartbeat", async () => {
    focus(chromeWindow)
    await page.locator(`textarea[data-conversation="${main}"]:visible`).click()
    await page.evaluate(() => {
      const style = document.createElement("style")
      style.id = "ks-quiet-style"
      style.textContent = ".ks-quiet { display: none }"
      document.head.append(style)
      const dialog = document.createElement("div")
      dialog.id = "ks-quiet"
      dialog.setAttribute("role", "dialog")
      dialog.className = "ks-quiet"
      dialog.textContent = "A dialog that appears without moving focus"
      document.body.append(dialog)
    })
    try {
      await page.waitForTimeout(500)
      await page.evaluate(() => document.getElementById("ks-quiet")!.classList.remove("ks-quiet"))
      await page.waitForTimeout(6500)
      const result = take("Reply with only quietblocked.")
      assert.equal(result.ok, false, JSON.stringify(result))
      assert.match(result.hud ?? "", /dialog covers/, JSON.stringify(result))
      assert.ok(!(await agent.messages(main)).some(m => m.text.includes("quietblocked")))
    } finally {
      await page.evaluate(() => {
        document.getElementById("ks-quiet")?.remove()
        document.getElementById("ks-quiet-style")?.remove()
      })
    }
  })
  assert.equal(results.at(-1)?.ok, true, "the style-change dialog fixture must close before delivery cases start")
  console.log("Asking the standing agent for a real coordinator branch")
  await request(`/api/conversations/${main}/submit`, { text: "Call your branch tool to start one coordinator branch discussing plum orchards. Tell it to reply only ready. Keep the branch open afterward: do not conclude or stop it. Do not edit files, commit, or push. Use the branch tool, not an API-created conversation or the subagent tool." })
  const branch = await until("a branch made by the branch tool", async () => (await summaries()).find(c => c.label === "coordinator"), 120, 500)
  assert.ok(branch.cwd.includes("worktrees"), "the branch has its own workspace")
  const side = await until("the standing agent's finished turn to fork", async () => {
    const response = await agent.api("/api/extensions/side-chat/actions/open", {
      conversationId: main, args: { text: "Reply only ready. Do not edit files or call tools." },
    })
    const body = await response.json() as any
    if (response.status === 500 && body.error === "@ultimate has no finished turn to fork yet") return undefined
    assert.ok(response.ok, JSON.stringify(body))
    return body.result
  }, 120, 500)
  await attempt(main, "Tab new side-chat mode opens a new side chat instead of sending to @ultimate", async () => {
    const beforeIds = new Set((await summaries()).filter(c => c.label === "side-chat").map(c => c.id))
    await shown(page, main)
    await page.keyboard.press("Tab")
    await page.locator('[data-side-mode="side"]').waitFor({ state: "visible", timeout: 10_000 })
    await page.waitForTimeout(300)
    const body = "Reply with only tabside."
    const result = take(body, true)
    assert.equal(result.ok, true, JSON.stringify(result))
    assert.ok(!(await agent.messages(main)).some(m => m.role === "user" && m.text.includes("tabside")), "Tab side-chat mode must never send to @ultimate")
    const opened = await until("a new side chat opened by Tab mode", async () =>
      (await summaries()).find(c => c.label === "side-chat" && !beforeIds.has(c.id)), 30, 500)
    await until("the new side chat's own record of the take", async () =>
      (await agent.messages(opened.id)).some(m => m.role === "user" && m.text.includes("tabside")) ? true : undefined, 30, 500)
    assert.ok(result.reply, JSON.stringify(result))
    const messages = await agent.messages(opened.id)
    const input = messages.filter(m => m.role === "user" && m.text.includes("tabside")).at(-1)!
    const answer = messages.filter(m => m.role === "agent" && m.turn === input.turn).at(-1)
    assert.ok(answer, "the new side chat answered its take")
    assert.equal(result.reply!.sha256, sha256(answer.text))
  })
  const lander = fileListing().find(c => c.label === "lander")
  assert.ok(lander, "the project has its standing lander")
  await attempt(lander.id, "lander hold identifies the conversation", async () => {
    await request("/api/ui", { set: { "shell.surface": "agent", "shell.conversation": lander.id, "ext.side-chat.front": null } })
    focus(chromeWindow)
    await page.waitForURL(new RegExp(`conversation=${lander.id}(?:&|$)`))
    await page.waitForTimeout(500)
    const result = take("Reply with only landerblocked.")
    assert.equal(result.ok, false, JSON.stringify(result))
    assert.match(result.hud ?? "", /lander/)
  })
  const created = await request("/api/conversations", {})
  await attempt(created.id, "new conversation accepts its first foreground take immediately", async () => {
    await shown(page, created.id)
    await delivered(created.id, "Reply with only firstready.", false)
  })
  assert.equal(results.at(-1)?.ok, true, "immediate page discovery must work before the matrix starts")
  console.log("Waiting for the standing agent to settle the branch's answer")
  let idleSince = 0
  await until("the standing agent idle after the branch answered", async () => {
    const answered = fileListing().find(c => c.id === branch.id)?.answerAt !== undefined
    const idle = answered && !(await summaries()).find(c => c.id === main)?.busy
    idleSince = idle ? idleSince || Date.now() : 0
    return idleSince && Date.now() - idleSince > 3000 ? true : undefined
  }, 120, 500)
  const reopened = await action("conversations", "resume", { ids: [branch.id] })
  if (reopened.resumed.length) console.log(`The standing agent concluded branch ${branch.id}; resumed it as a user would`)
  console.log("Asking the coordinator branch for a real owned subagent")
  const workerArgs = { action: "start", label: "feather", tools: ["bash"], isolate: "none", background: true,
    instructions: "Answer user messages. Do not edit files, commit, push, or delegate.", task: "Reply only ready.",
    ...(process.env.ULTIMATE_MODEL ? { model: process.env.ULTIMATE_MODEL } : {}) }
  await request(`/api/conversations/${branch.id}/submit`, {
    whenBusy: "steer",
    text: `Call codemode with this exact code, preserving the argument object without adding any keys:\nreturn await tools.subagent(${JSON.stringify(workerArgs)});\nThis starts one real owned subagent. Do not call the subagent tool directly: use the exact codemode code. Create no worktree and make no other changes.`,
  })
  const worker = await until("the coordinator's owned subagent", async () => (await summaries()).find(c => c.label === "feather" && c.parentConversationId !== undefined), 120, 500)
  assert.equal(worker.parentConversationId, branch.id)
  assert.ok(worker.ownerTaskId, "the subagent belongs to its parent's task")
  const targets = [worker.id, main, branch.id, created.id, side.id]
  for (const id of targets) {
    const show = () => shown(page, id === side.id ? main : id, id === side.id ? side.id : undefined)
    const token = `case${id}`
    await attempt(id, "unnamed front take and silent reply", async () => {
      await show()
      const body = `Reply with only ${token}front.`
      await delivered(id, body, false)
      assert.equal(record(body)?.facts.find((f: any) => f.label === "Chosen by")?.value, "The conversation in front")
      assert.ok(record(body)?.steps.some((s: any) => /was in front when it finished/.test(s.text)))
      if (id === side.id) assert.ok(!(await agent.messages(main)).some(m => m.text === body))
    })
    await attempt(id, "named idle delivery and exact reply", async () => { await show(); await delivered(id, `Reply with only ${token}idle.`) })
    await attempt(id, "slash text", async () => { await delivered(id, "/status", true, false) })
    await attempt(id, "two identical takes", async () => {
      const body = `Reply with only ${token}twice.`
      const first = await delivered(id, body)
      const second = await delivered(id, body)
      assert.notEqual(first.request, second.request)
      assert.equal((await agent.messages(id)).filter(m => m.role === "user" && m.text === body).length, 2)
    })
    await attempt(id, "take while busy", async () => {
      await show()
      await delivered(id, "Use your shell tool to sleep 20 seconds, then reply ready. Do not edit files.", true, false)
      await page.getByTitle("Stop (Esc)", { exact: true }).filter({ visible: true }).first().waitFor()
      const result = await delivered(id, `When the sleep finishes, reply with only ${token}busy.`, true)
      assert.equal(result.reply?.sha256, sha256(`${token}busy`), "the working conversation answered the second take")
    })
    await attempt(id, "long take", async () => {
      const body = `Read this sample: ${"plum orchard ".repeat(250)}. Reply only ${token}long.`
      await delivered(id, body)
    })
    await attempt(id, "ask address", async () => {
      const body = `Reply with only ${token}ask.`
      const result = take(`ask ${name(id)}, ${body}`, true)
      assert.equal(result.conversation, key(id), JSON.stringify(result))
      assert.ok((await agent.messages(id)).some(m => m.role === "user" && m.text === body))
    })
    await attempt(id, "near-miss number sends nothing", async () => {
      const body = `never${token}`
      const result = take(`tell ultimate 999999, ${body}`)
      assert.equal(result.ok, false, JSON.stringify(result))
      for (const target of targets) assert.ok(!(await agent.messages(target)).some(m => m.role === "user" && m.text.includes(body)))
    })
    await attempt(id, "clipboard text", async () => {
      clipboard("text", `clipboard${token}`)
      const result = take(`tell ${name(id)}, Reply ready about insert clipboard contents.`, true)
      assert.equal(result.conversation, key(id), JSON.stringify(result))
      assert.ok((await agent.messages(id)).some(m => m.role === "user" && m.text.includes(`clipboard${token}`)))
    })
    await attempt(id, "clipboard image", async () => {
      clipboard("image")
      const result = take(`tell ${name(id)}, Describe insert clipboard contents in one word.`, true)
      assert.equal(result.conversation, key(id), JSON.stringify(result))
      const history = await request(`/api/conversations/${id}/history?before=${Number.MAX_SAFE_INTEGER}`)
      assert.ok(history.entries.some((e: any) => e.input && JSON.stringify(e.model).includes('"type":"image"')))
    })
    for (const background of [false, true]) await attempt(id, `draft ${background ? "background" : "front"}`, async () => {
      const editor = await show()
      const draft = `draft${token}${background ? "back" : "front"}`
      await editor.fill(draft)
      await page.waitForTimeout(300)
      if (background) focus(otherWindow)
      const result = take(`tell ${name(id)}, Reply only ready.`, true)
      assert.equal(result.conversation, key(id), JSON.stringify(result))
      const merged = (await agent.messages(id)).some(m => m.role === "user" && m.text.includes(draft))
      assert.ok(merged || (await editor.inputValue()).includes(draft), "the draft was delivered or remains in its composer")
      await editor.fill("")
    })
    await attempt(id, "unknown name sends nothing", async () => {
      const result = take(`tell zebrafinch, never${token}`)
      assert.equal(result.ok, false, JSON.stringify(result))
      assert.equal(result.conversation, undefined)
    })
    await attempt(id, "reply read with another app in front", async () => {
      await show(); focus(otherWindow)
      const body = `Reply with only ${token}away.`
      await delivered(id, body)
      await until("the spoken reply in History", () => record(body)?.spoken_reply ? true : undefined, 30)
    })
    await attempt(id, "repeat that", async () => {
      const result = take("repeat that")
      assert.ok(result.ok, JSON.stringify(result))
    })
    for (const verb of ["open", "go to"]) await attempt(id, `${verb} brings the conversation forward`, async () => {
      await shown(page, created.id)
      focus(otherWindow)
      const result = take(`${verb} ${name(id)}`)
      assert.ok(result.ok, JSON.stringify(result))
      assert.ok(instance.cli(["--front-probe"], 15).stdout.includes("front=com.google.Chrome"))
      await page.waitForURL(new RegExp(`conversation=${id}(?:&|$)`))
    })
    await attempt(id, "check on then unnamed send", async () => {
      await show()
      const result = take(`check on ${name(id)}`)
      assert.ok(result.ok, JSON.stringify(result))
      assert.ok(record(`check on ${name(id)}`)?.facts.some((f: any) => f.label === "Conversation" && f.value.endsWith(`${id}@${agent.projectHome}`)), "status belongs to the requested conversation")
      await page.waitForFunction(() => document.hasFocus() && document.visibilityState === "visible")
      await delivered(id, `Reply with only ${token}afterstatus.`, false)
    })
    await attempt(id, "switch conversations and back", async () => {
      await shown(page, id === main ? created.id : main)
      await show()
      await delivered(id, `Reply with only ${token}back.`, false)
    })
    await attempt(id, "current sidebar title after an address verb", async () => {
      const title = (await summaries()).find(c => c.id === id)?.title
      assert.ok(title, "the sidebar has a title to address")
      const result = take(`check on ${title}`)
      assert.ok(result.ok, JSON.stringify(result))
      assert.ok(record(`check on ${title}`)?.facts.some((f: any) => f.label === "Conversation" && f.value.endsWith(`${id}@${agent.projectHome}`)), "the sidebar title resolves to its own conversation")
    })
  }
  await instance.quit()
  const removed = instance.connector("uninstall", "ultimate", agent.folder, agent.tool)
  assert.equal(removed.status, 0, removed.stdout + removed.stderr)
  assert.match(instance.connector("status", "ultimate", agent.folder, agent.tool).stdout, /notInstalled/)
  const preserved = JSON.parse(readFileSync(join(agent.folder, "settings.json"), "utf8"))
  assert.equal(preserved.onboarding, true)
  assert.ok(preserved.extensions.disable.includes("sample-unrelated-extension"))
  assert.ok(results.every(r => r.ok), `${results.filter(r => !r.ok).length} conformance cases failed`)
} catch (error) { failure = error; console.error(error) }
finally {
  await cleanup()
  console.log(`Ultimate page conformance: ${results.filter(r => r.ok).length} passed, ${results.filter(r => !r.ok).length} failed; ${instance.folder}`)
}
process.exit(failure ? 1 : 0)
