import assert from "node:assert/strict"
import { createRequire } from "node:module"
import { existsSync, readFileSync, readdirSync, realpathSync, symlinkSync, writeFileSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { Instance, type TakeResult } from "./lib/instance.ts"
import { bringAwayForward } from "./lib/driver.ts"
import { UltimateDriver, pageChange } from "./lib/ultimate.ts"
import { awayWindow, terminalHost } from "./lib/terminal.ts"
import { run, sha256, shutDown, sleep, stopEach, until } from "./lib/util.ts"
import { failureBundle } from "./lib/artifacts.ts"
import { homeChanges, snapshotHome } from "./lib/home-audit.ts"
import { inputUnseen, voiceOverBlocks, voiceOverOn } from "./lib/preflight.ts"
import { clipboard } from "./lib/clipboard.ts"
import { matchesPageCase, parsePageOptions, type PageTargetKind } from "./lib/options.ts"

const repository = resolve(dirname(fileURLToPath(import.meta.url)), "../..")
const clone = process.env.ULTIMATE_CLONE
assert.ok(clone, "set ULTIMATE_CLONE to an installed Ultimate checkout")
const { chromium } = createRequire(join(resolve(clone), "package.json"))("playwright-core")
const homeBefore = snapshotHome()
const host = terminalHost()
host.check()
const away = awayWindow(host)
const instance = new Instance(Instance.locate())
const agent = new UltimateDriver("kestrel")
const options = parsePageOptions(process.argv.slice(2), process.env)
const { keep, replyWait, only, targets: selectedTargets, failFast, repeat } = options
let browser: any
let clipboardSaved = false
let failure: unknown
let cleaning: Promise<void> | undefined
let stopping = false
let stoppedEarly = false
const results: { case: string; conversation: number; ok?: boolean; why?: string; notApplicable?: string }[] = []
const clipboardFile = join(instance.folder, "clipboard.plist")

function command(tool: string, args: string[], timeout = 30) {
  const answer = run(tool, args, { timeout })
  assert.equal(answer.status, 0, `${tool} failed: ${answer.why}`)
  return answer.stdout
}
function cleanup() {
  return cleaning ??= (async () => {
    try {
      if (clipboardSaved) clipboard("restore", clipboardFile)
    } finally {
      try { await browser?.close() }
      finally {
        await shutDown(() => stopEach(() => away.close(), () => agent.stop(keep || !!failure)), (kept) => instance.dispose(kept), keep || !!failure)
      }
    }
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
async function streamed(event: string): Promise<any> {
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
        if (lines[0] === `event: ${event}`) return JSON.parse(lines.filter(line => line.startsWith("data: ")).at(-1)!.slice(6))
      }
    }
    throw new Error(`Ultimate's event stream ended before it sent ${event}`)
  } finally {
    clearTimeout(timer)
    controller.abort()
  }
}
const summaries = (): Promise<any[]> => streamed("conversations")
const fileListing = () => JSON.parse(readFileSync(join(agent.projectHome, "conversations.json"), "utf8")) as any[]
const key = (id: number) => `ultimate:${id}@${agent.projectHome}`
const name = (id: number) => `ultimate ${id}`
const take = (text: string, reply = false) => {
  assert.ok(!stopping, "conformance interrupted")
  return instance.take(text, { timeout: 45, ...(reply ? { waitReply: replyWait } : {}) })
}
function record(result: TakeResult) {
  assert.ok(result.history, JSON.stringify(result))
  return instance.entry(result.history!)
}
let chromeWindow = ""
let debugPort = 0
let page: any
let main = 0

const windows = () => instance.windows()
const focus = (spec: string) => instance.focus(spec)
const lookAway = () => bringAwayForward(away, windows, focus)
async function shown(page: any, id: number, side?: number) {
  await request("/api/ui", pageChange({ "shell.surface": "agent", "shell.conversation": id,
    "ext.side-chat.front": side ?? null }))
  const editor = page.locator(`textarea[data-conversation="${side ?? id}"]:visible`).filter({ visible: true })
  await editor.waitFor({ state: "visible", timeout: 60_000 })
  focus(chromeWindow)
  await editor.focus()
  await page.waitForFunction(() => document.hasFocus() && document.visibilityState === "visible")
  return editor
}
async function delivered(id: number, text: string, explicit = true, reply = true): Promise<TakeResult> {
  const since = (await agent.messages(id)).length
  const result = take(explicit ? `tell ${name(id)}, ${text}` : text, reply)
  assert.equal(result.ok, true, JSON.stringify(result))
  assert.equal(result.conversation, key(id), JSON.stringify(result))
  await until("Ultimate's own record of the take", async () =>
    (await agent.messages(id)).slice(since).some(m => m.role === "user" && m.text.includes(text)) ? true : undefined, 30)
  if (reply) {
    assert.ok(result.reply, JSON.stringify(result))
    const messages = (await agent.messages(id)).slice(since)
    const input = messages.filter(m => m.role === "user" && m.text.includes(text)).at(-1)!
    const answer = messages.filter(m => m.role === "agent" && m.turn === input.turn).at(-1)
    assert.ok(answer, "the take has its own reply")
    assert.equal(result.reply!.sha256, sha256(answer.text))
  }
  return result
}
const chromeEvidence = async () => ({
  connected: browser?.isConnected() ?? false,
  chromeWindowTitles: windows().filter(listed => agent.window.owns(listed)).map(listed => listed.title),
  pages: browser?.contexts().flatMap((context: any) => context.pages().map((open: any) => ({ url: open.url(), closed: open.isClosed() }))) ?? [],
  targets: debugPort ? await fetch(`http://127.0.0.1:${debugPort}/json/list`, { signal: AbortSignal.timeout(5000) }).then((answer) => answer.json()).catch((error) => `the debugging port did not answer: ${error}`) : [],
})
const pageState = () => page?.evaluate(() => {
  const describe = (element: Element | null) => element && {
    tag: element.tagName.toLowerCase(), role: element.getAttribute("role"),
    label: element.getAttribute("aria-label") ?? element.getAttribute("placeholder") ?? element.getAttribute("title"),
    text: (element.textContent ?? "").trim().slice(0, 200),
  }
  return {
    url: location.href, title: document.title, focused: document.hasFocus(), visibility: document.visibilityState,
    active: describe(document.activeElement),
    dialogs: Array.from(document.querySelectorAll('[role="dialog"], [role="alertdialog"], dialog[open]'))
      .filter(dialog => dialog.getClientRects().length).map(describe),
    editors: Array.from(document.querySelectorAll("textarea[data-conversation]")).map(editor => ({
      conversation: editor.getAttribute("data-conversation"),
      visible: !!(editor as HTMLElement).getClientRects().length, active: editor === document.activeElement,
    })),
  }
})
const pageEvidence = () => ({
  "windows": () => windows(),
  "front": () => instance.cli(["--front-probe"], 15).stdout,
  "chrome": chromeEvidence,
  "page": pageState,
  "page-screenshot": () => page?.isClosed() === false ? page.screenshot({ timeout: 10_000 }) : undefined,
  ...(agent.diagnostics?.() ?? {}),
})
let crashed = false
const debuggerAnswers = async () => !!debugPort && !!(await fetch(`http://127.0.0.1:${debugPort}/json/version`, { signal: AbortSignal.timeout(5000) }).catch(() => null))?.ok
function usePage(chosen: any) {
  if (chosen !== page) chosen.on("crash", () => { if (page === chosen) crashed = true })
  page = chosen
  crashed = false
  page.setDefaultTimeout(30_000)
}
async function openPage() {
  if (!(await debuggerAnswers())) {
    await browser?.close().catch(() => {})
    browser = undefined
    await agent.window.close()
    debugPort = await agent.launchChrome(main)
    await until("Chrome's debugging endpoint", async () => (await debuggerAnswers()) ? true : undefined, 30)
  }
  if (!browser?.isConnected()) browser = await chromium.connectOverCDP(`http://127.0.0.1:${debugPort}`)
  const context = browser.contexts()[0]
  assert.ok(context, "the conformance Chrome has no browsing context to open the page in")
  const broken = crashed ? page : undefined
  const open = context.pages().filter((candidate: any) => !candidate.isClosed() && candidate !== broken)
  usePage(open.find((candidate: any) => candidate.url().startsWith(agent.url)) ?? open[0] ?? await context.newPage())
  await broken?.close().catch(() => {})
  await page.goto(`${agent.url}/?conversation=${main}`)
  await page.locator(`textarea[data-conversation="${main}"]:visible`).waitFor({ timeout: 60_000 })
  chromeWindow = await until("the Ultimate page's own Chrome window", () => windows().find(listed => agent.window.owns(listed))?.spec, 30)
}
async function pageProblem(): Promise<string | undefined> {
  if (!agent.chromeRunning()) return "Chrome quit"
  if (!browser?.isConnected()) return "the debugging connection to Chrome dropped while Chrome kept running"
  if (crashed) return "the page's renderer crashed"
  if (!page || page.isClosed()) {
    const others = browser.contexts().flatMap((context: any) => context.pages()).filter((open: any) => !open.isClosed())
    return others.length ? "the page was closed while Chrome kept other pages open" : "the page was closed and Chrome has no page left"
  }
  if (!page.url().startsWith(agent.url)) return `the page left Ultimate for ${page.url()}`
  return undefined
}
const openDialogs = () => page.locator('[role="dialog"]:visible, [role="alertdialog"]:visible, dialog[open]:visible')
const dialogsGone = (what: string) => until(what, async () => (await openDialogs().count()) === 0 ? true : undefined, 5, 100)
async function closeDialogs() {
  for (let tries = 0; tries < 3 && await openDialogs().count(); tries++) {
    await page.keyboard.press("Escape")
    await page.waitForTimeout(300)
  }
  if (await openDialogs().count()) await openDialogs().getByRole("button", { name: "Close" }).first().click({ timeout: 2000 }).catch(() => {})
}
function report(row: typeof results[number], seconds?: number) {
  results.push(row)
  const verdict = row.notApplicable !== undefined ? "N/A" : row.ok ? "PASS" : "FAIL"
  console.log(`${verdict} #${row.conversation} ${row.case}${seconds === undefined ? "" : ` ${seconds.toFixed(1)}s`}${row.why ? ` ${row.why}` : ""}${row.notApplicable ? ` ${row.notApplicable}` : ""}`)
  writeFileSync(join(instance.folder, "conformance.json"), JSON.stringify(results, null, 2))
  if (row.ok === false && failFast) stoppedEarly = true
}
const why = (error: unknown) => `${String(error)}${error instanceof Error && error.cause ? `; cause: ${String(error.cause)}` : ""}`
async function leftBehind(): Promise<string | undefined> {
  const problem = await pageProblem()
  if (problem) return problem
  try {
    const dialogs = await openDialogs().count()
    return dialogs ? `${dialogs === 1 ? "a dialog was" : `${dialogs} dialogs were`} left open: ${JSON.stringify(await pageState().catch(why))}` : undefined
  } catch (error) {
    await sleep(500)
    return (await pageProblem()) ?? `the page could not be checked: ${why(error)}`
  }
}
async function restored(after: string) {
  try {
    if (await pageProblem()) await openPage()
    else await closeDialogs()
    const still = await leftBehind()
    assert.ok(!still, still)
    return true
  } catch (error) {
    report({ case: `the page was restored after "${after}"`, conversation: main, ok: false, why: why(error) })
    stoppedEarly = true
    return false
  }
}
async function attempt(id: number, label: string, test: () => Promise<void>, kind = "page", after?: () => Promise<void>) {
  if (stoppedEarly || !matchesPageCase(only, label, kind)) return
  for (let round = 0; round < repeat && !stoppedEarly; round++) {
    assert.ok(!stopping, "conformance interrupted")
    const tag = repeat > 1 ? `${label} [${round + 1}/${repeat}]` : label
    const before = await leftBehind()
    if (before) {
      const check = `the page was usable before "${tag}"`
      await failureBundle(instance.folder, check, new Error(before), pageEvidence())
        .catch(failure => console.error(`Could not capture the page's evidence: ${failure}`))
      report({ case: check, conversation: main, ok: false, why: before })
      if (stoppedEarly || !(await restored(check))) return
    }
    const started = Date.now()
    const problems: string[] = []
    let failed: unknown
    try { await test() } catch (error) { failed = error; problems.push(why(error)) }
    const evidence = { "agent-history": () => agent.messages(id),
      "discovery": () => instance.cli(["--discovery-report", agent.kind, "--folder", agent.folder], 15), ...pageEvidence() }
    if (failed) await failureBundle(instance.folder, `${id}/${tag}`, failed, evidence)
      .catch(failure => console.error(`Could not capture failure evidence: ${failure}`))
    if (after) await after().catch(error => problems.push(`cleaning up failed: ${why(error)}`))
    const left = await leftBehind()
    if (left) problems.push(`after the case, ${left}`)
    if (!failed && problems.length) await failureBundle(instance.folder, `${id}/${tag}`, new Error(problems.join("; ")), evidence)
      .catch(failure => console.error(`Could not capture failure evidence: ${failure}`))
    report(problems.length ? { case: tag, conversation: id, ok: false, why: problems.join("; ") } : { case: tag, conversation: id, ok: true },
      (Date.now() - started) / 1000)
    if (left && !stoppedEarly) await restored(tag)
  }
}

try {
  console.log(`Ultimate page conformance: ${instance.folder}, ${agent.root}`)
  await agent.setUp()
  writeFileSync(join(agent.folder, "settings.json"), JSON.stringify({ onboarding: true, extensions: { disable: ["sample-unrelated-extension"] } }))
  command("git", ["-C", agent.project, "fetch", "--depth=1", repository, "HEAD"])
  command("git", ["-C", agent.project, "reset", "--hard", "FETCH_HEAD"])
  assert.ok(!voiceOverOn(), voiceOverBlocks)
  await instance.prepare()
  const linked = join(agent.root, "linked-setup")
  symlinkSync(agent.folder, linked)
  const installed = instance.connector("install", "ultimate", linked, agent.tool)
  assert.equal(installed.status, 0, installed.why)
  const installedPlugin = readdirSync(join(agent.folder, "extensions")).find(name => existsSync(join(agent.folder, "extensions", name, "keyscribe.json")))
  assert.ok(installedPlugin, "the installed connector has its configuration")
  await instance.launch()
  const probe = instance.take("check on all")
  assert.notEqual(probe.observesInput, false, inputUnseen(instance.binary))
  assert.notEqual(probe.observesInput, undefined, `the test instance could not answer whether it sees input: ${probe.problem ?? JSON.stringify(probe)}`)
  await agent.start()
  await action("onboarding", "firstRunDone", null)
  main = await action("subagents", "standing", { name: "ultimate" }) as number
  clipboard("save", clipboardFile)
  clipboardSaved = true
  await openPage()
  assert.equal(await page.evaluate(() => navigator.webdriver), false, "the conformance page must share navigation like an ordinary browser")
  console.log(`The standing agent's visible composer is ready in "${await page.title()}"`)
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
    await dialogsGone("the Get ready dialog to close from its Close button")
  }, "dialog", closeDialogs)
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
    await page.waitForTimeout(500)
    await page.evaluate(() => document.getElementById("ks-quiet")!.classList.remove("ks-quiet"))
    await page.waitForTimeout(6500)
    const result = take("Reply with only quietblocked.")
    assert.equal(result.ok, false, JSON.stringify(result))
    assert.match(result.hud ?? "", /dialog covers/, JSON.stringify(result))
    assert.ok(!(await agent.messages(main)).some(m => m.text.includes("quietblocked")))
  }, "dialog", () => page.evaluate(() => {
    document.getElementById("ks-quiet")?.remove()
    document.getElementById("ks-quiet-style")?.remove()
  }))
  const needsBranch = !selectedTargets || selectedTargets.has("branch") || selectedTargets.has("worker")
  const needsWorker = !selectedTargets || selectedTargets.has("worker")
  const needsSide = !selectedTargets || selectedTargets.has("side")
  const wantsTabSide = matchesPageCase(only, "Tab new side-chat mode opens a new side chat instead of sending to @ultimate", "main")
  let branch: any
  let side: any
  if (!stoppedEarly && needsBranch) {
    console.log("Asking the standing agent for a real coordinator branch")
    await request(`/api/conversations/${main}/submit`, { text: "Call your branch tool to start one coordinator branch discussing plum orchards. Tell it to reply only ready. Keep the branch open afterward: do not conclude or stop it. Do not edit files, commit, or push. Use the branch tool, not an API-created conversation or the subagent tool." })
    branch = await until("a branch made by the branch tool", async () => (await summaries()).find(c => c.label === "coordinator"), 120, 500)
    assert.ok(branch.cwd.includes("worktrees"), "the branch has its own workspace")
  } else if (!stoppedEarly && (needsSide || wantsTabSide)) {
    await request(`/api/conversations/${main}/submit`, { text: "Reply only ready. Do not edit files or call tools." })
    await until("the standing agent's initial turn", async () =>
      fileListing().find(c => c.id === main)?.answerAt !== undefined ? true : undefined, 120, 500)
  }
  if (!stoppedEarly && needsSide) {
    side = await until("the standing agent's finished turn to fork", async () => {
      const response = await agent.api("/api/extensions/side-chat/actions/open", {
        conversationId: main, args: { text: "Reply only ready. Do not edit files or call tools." },
      })
      const body = await response.json() as any
      if (response.status === 500 && body.error === "@ultimate has no finished turn to fork yet") return undefined
      assert.ok(response.ok, JSON.stringify(body))
      return body.result
    }, 120, 500)
  }
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
  }, "main")
  if (side) await attempt(main, "go to @ultimate with its side chat in front shows @ultimate's own message box", async () => {
    await shown(page, main, side.id)
    await lookAway()
    const result = take(`go to ${name(main)}`)
    assert.ok(result.ok, JSON.stringify(result))
    await page.waitForFunction((id: number) => {
      const box = [...document.querySelectorAll<HTMLTextAreaElement>(`textarea[data-conversation="${id}"]`)].find(editor => editor.getClientRects().length > 0)
      return !!box && !box.closest('[inert]')
    }, main, { timeout: 15_000 })
  }, "main")
  const landerCase = "lander hold identifies the conversation"
  if (!stoppedEarly && matchesPageCase(only, landerCase, "lander")) {
    const served = String((await streamed("system"))?.project?.root ?? "")
    assert.ok(served, "Ultimate did not say which project it serves")
    if (realpathSync(served) !== realpathSync(agent.project)) {
      report({ case: landerCase, conversation: 0, notApplicable: `this Ultimate serves ${served}, not the scratch project whose lander the case uses` })
    } else {
      const lander = fileListing().find(c => c.label === "lander")
      assert.ok(lander, "the project has its standing lander")
      await attempt(lander.id, landerCase, async () => {
        await request("/api/ui", pageChange({ "shell.surface": "agent", "shell.conversation": lander.id, "ext.side-chat.front": null }))
        focus(chromeWindow)
        await page.waitForURL(new RegExp(`conversation=${lander.id}(?:&|$)`))
        await page.waitForTimeout(500)
        const result = take("Reply with only landerblocked.")
        assert.equal(result.ok, false, JSON.stringify(result))
        assert.match(result.hud ?? "", /lander/)
      }, "lander")
    }
  }
  const created = await request("/api/conversations", {})
  const createdCountBefore = results.length
  await attempt(created.id, "new conversation accepts its first foreground take immediately", async () => {
    await shown(page, created.id)
    await delivered(created.id, "Reply with only firstready.", false)
  }, "created")
  if (results.length > createdCountBefore) assert.equal(results.at(-1)?.ok, true, "immediate page discovery must work before the matrix starts")
  let worker: any
  if (!stoppedEarly && branch) {
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
  }
  if (!stoppedEarly && needsWorker && branch) {
    console.log("Asking the coordinator branch for a real owned subagent")
    const workerArgs = { action: "start", label: "feather", tools: ["bash"], isolate: "none", background: true,
      instructions: "Answer user messages. Do not edit files, commit, push, or delegate.", task: "Reply only ready.",
      ...(process.env.ULTIMATE_MODEL ? { model: process.env.ULTIMATE_MODEL } : {}) }
    await request(`/api/conversations/${branch.id}/submit`, {
      whenBusy: "steer",
      text: `Call codemode with this exact code, preserving the argument object without adding any keys:\nreturn await tools.subagent(${JSON.stringify(workerArgs)});\nThis starts one real owned subagent. Do not call the subagent tool directly: use the exact codemode code. Create no worktree and make no other changes.`,
    })
    worker = await until("the coordinator's owned subagent", async () => (await summaries()).find(c => c.label === "feather" && c.parentConversationId !== undefined), 120, 500)
    assert.equal(worker.parentConversationId, branch.id)
    assert.ok(worker.ownerTaskId, "the subagent belongs to its parent's task")
  }
  const allTargets: { kind: PageTargetKind; id: number }[] = [
    ...(worker ? [{ kind: "worker" as const, id: worker.id }] : []),
    { kind: "main" as const, id: main },
    ...(branch ? [{ kind: "branch" as const, id: branch.id }] : []),
    { kind: "created" as const, id: created.id },
    ...(side ? [{ kind: "side" as const, id: side.id }] : []),
  ]
  const targetEntries = selectedTargets ? allTargets.filter(t => selectedTargets.has(t.kind)) : allTargets
  const targets = targetEntries.map(t => t.id)
  for (const { kind, id } of targetEntries) {
    if (stoppedEarly) break
    const show = () => shown(page, side && id === side.id ? main : id, side && id === side.id ? side.id : undefined)
    const token = `case${id}`
    const runCase = (label: string, fn: () => Promise<void>) => attempt(id, label, fn, kind)
    await runCase("unnamed front take and silent reply", async () => {
      await show()
      const body = `Reply with only ${token}front.`
      const result = await delivered(id, body, false)
      assert.equal(record(result)?.facts.find((f: any) => f.label === "Chosen by")?.value, "The conversation in front")
      await until("History saying the reply was not read over the conversation in front", () =>
        record(result)?.steps?.some((s: any) => /was in front when it finished/.test(s.text)) ? true : undefined, 30)
      if (side && id === side.id) assert.ok(!(await agent.messages(main)).some(m => m.text === body))
    })
    await runCase("named idle delivery and exact reply", async () => { await show(); await delivered(id, `Reply with only ${token}idle.`) })
    await runCase("slash text", async () => { await delivered(id, "/status", true, false) })
    await runCase("two identical takes", async () => {
      const body = `Reply with only ${token}twice.`
      const since = (await agent.messages(id)).length
      const first = await delivered(id, body)
      const second = await delivered(id, body)
      assert.notEqual(first.request, second.request)
      assert.equal((await agent.messages(id)).slice(since).filter(m => m.role === "user" && m.text === body).length, 2)
    })
    await runCase("take while busy", async () => {
      await show()
      await delivered(id, "Use your shell tool to sleep 20 seconds, then reply ready. Do not edit files.", true, false)
      await page.getByTitle("Stop (Esc)", { exact: true }).filter({ visible: true }).first().waitFor()
      const result = await delivered(id, `When the sleep finishes, reply with only ${token}busy.`, true)
      assert.equal(result.reply?.sha256, sha256(`${token}busy`), "the working conversation answered the second take")
    })
    await runCase("long take", async () => {
      const body = `Read this sample: ${"plum orchard ".repeat(250)}. Reply only ${token}long.`
      await delivered(id, body)
    })
    await runCase("ask address", async () => {
      const body = `Reply with only ${token}ask.`
      const since = (await agent.messages(id)).length
      const result = take(`ask ${name(id)}, ${body}`, true)
      assert.equal(result.conversation, key(id), JSON.stringify(result))
      assert.ok((await agent.messages(id)).slice(since).some(m => m.role === "user" && m.text === body))
    })
    await runCase("near-miss number sends nothing", async () => {
      const body = `never${token}`
      const result = take(`tell ultimate 999999, ${body}`)
      assert.equal(result.ok, false, JSON.stringify(result))
      for (const target of targets) assert.ok(!(await agent.messages(target)).some(m => m.role === "user" && m.text.includes(body)))
    })
    await runCase("clipboard text", async () => {
      clipboard("text", `clipboard${token}`)
      const since = (await agent.messages(id)).length
      const result = take(`tell ${name(id)}, Reply ready about insert clipboard contents.`, true)
      assert.equal(result.conversation, key(id), JSON.stringify(result))
      assert.ok((await agent.messages(id)).slice(since).some(m => m.role === "user" && m.text.includes(`clipboard${token}`)))
    })
    await runCase("clipboard image", async () => {
      clipboard("image")
      const newest = async () => (await request(`/api/conversations/${id}/history?before=${Number.MAX_SAFE_INTEGER}`)).entries
      const last = Math.max(0, ...(await newest()).map((e: any) => Number(e.id)))
      const result = take(`tell ${name(id)}, Describe insert clipboard contents in one word.`, true)
      assert.equal(result.conversation, key(id), JSON.stringify(result))
      assert.ok((await newest()).some((e: any) => Number(e.id) > last && e.input && JSON.stringify(e.model).includes('"type":"image"')))
    })
    for (const background of [false, true]) await runCase(`draft ${background ? "background" : "front"}`, async () => {
      const editor = await show()
      const draft = `draft${token}${background ? "back" : "front"}`
      const since = (await agent.messages(id)).length
      await editor.fill(draft)
      await page.waitForTimeout(300)
      if (background) await lookAway()
      const result = take(`tell ${name(id)}, Reply only ready.`, true)
      assert.equal(result.conversation, key(id), JSON.stringify(result))
      const merged = (await agent.messages(id)).slice(since).some(m => m.role === "user" && m.text.includes(draft))
      assert.ok(merged || (await editor.inputValue()).includes(draft), "the draft was delivered or remains in its composer")
      await editor.fill("")
    })
    await runCase("unknown name sends nothing", async () => {
      const result = take(`tell zebrafinch, never${token}`)
      assert.equal(result.ok, false, JSON.stringify(result))
      assert.equal(result.conversation, undefined)
    })
    await runCase("reply read with another app in front", async () => {
      await show(); await lookAway()
      const body = `Reply with only ${token}away.`
      const result = await delivered(id, body)
      await until("the spoken reply in History", () => record(result)?.spoken_reply ? true : undefined, 30)
    })
    await runCase("repeat that", async () => {
      const result = take("repeat that")
      assert.ok(result.ok, JSON.stringify(result))
    })
    for (const verb of ["open", "go to"]) await runCase(`${verb} brings the conversation forward`, async () => {
      await shown(page, created.id)
      await lookAway()
      const result = take(`${verb} ${name(id)}`)
      assert.ok(result.ok, JSON.stringify(result))
      assert.ok(instance.cli(["--front-probe"], 15).stdout.includes("front=com.google.Chrome"))
      await page.waitForURL(new RegExp(`conversation=${id}(?:&|$)`))
    })
    await runCase("check on then unnamed send", async () => {
      await show()
      const result = take(`check on ${name(id)}`)
      assert.ok(result.ok, JSON.stringify(result))
      assert.ok(record(result)?.facts.some((f: any) => f.label === "Conversation" && f.value.endsWith(`${id}@${agent.projectHome}`)), "status belongs to the requested conversation")
      await page.waitForFunction(() => document.hasFocus() && document.visibilityState === "visible")
      await delivered(id, `Reply with only ${token}afterstatus.`, false)
    })
    await runCase("switch conversations and back", async () => {
      await shown(page, id === main ? created.id : main)
      await show()
      await delivered(id, `Reply with only ${token}back.`, false)
    })
    await runCase("current sidebar title after an address verb", async () => {
      const title = (await summaries()).find(c => c.id === id)?.title
      assert.ok(title, "the sidebar has a title to address")
      const result = take(`check on ${title}`)
      assert.ok(result.ok, JSON.stringify(result))
      assert.ok(record(result)?.facts.some((f: any) => f.label === "Conversation" && f.value.endsWith(`${id}@${agent.projectHome}`)), "the sidebar title resolves to its own conversation")
    })
  }
  await instance.quit()
  const removed = instance.connector("uninstall", "ultimate", agent.folder, agent.tool)
  assert.equal(removed.status, 0, removed.why)
  assert.match(instance.connector("status", "ultimate", agent.folder, agent.tool).stdout, /notInstalled/)
  const preserved = JSON.parse(readFileSync(join(agent.folder, "settings.json"), "utf8"))
  assert.equal(preserved.onboarding, true)
  assert.ok(preserved.extensions.disable.includes("sample-unrelated-extension"))
  assert.ok(results.some(r => r.notApplicable === undefined), "filter matched zero conformance cases")
  assert.ok(!results.some(r => r.ok === false), `${results.filter(r => r.ok === false).length} conformance cases failed`)
} catch (error) {
  failure = error
  console.error(error)
  await failureBundle(instance.folder, "ultimate-page/setup-or-completion", error, pageEvidence()).catch(failure => console.error(`Could not capture setup evidence: ${failure}`))
}
finally {
  await cleanup()
  console.log(`Ultimate page conformance: ${results.filter(r => r.ok === true).length} passed, ${results.filter(r => r.ok === false).length} failed, ${results.filter(r => r.notApplicable !== undefined).length} not applicable; ${instance.folder}`)
}
const touched = (() => { try { return homeChanges(homeBefore, snapshotHome()) } catch (error) { return [(error as Error).message] } })()
if (touched.length) console.error(`The run changed the user's own setup outside its scratch folders:\n  ${touched.join("\n  ")}`)
const partial = results.some(r => r.notApplicable !== undefined)
if (partial && !failure && !touched.length) console.log("Partial run: a case did not apply to the Ultimate under test, so this is not a full pass")
process.exit(failure || touched.length ? 1 : partial ? 3 : 0)
