import assert from "node:assert/strict"
import { spawn, execFileSync } from "node:child_process"
import { createServer } from "node:http"
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs"
import { createRequire } from "node:module"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const clone = process.env.ULTIMATE_CLONE
const node = process.env.ULTIMATE_NODE ?? process.execPath
const port = Number(process.env.ULTIMATE_PORT ?? 4798)
if (!clone || !existsSync(join(clone, "bin/ultimate.ts"))) {
  console.error("test-ultimate-page-smoke: set ULTIMATE_CLONE to an Ultimate clone with pnpm install done")
  process.exit(2)
}
const { chromium } = createRequire(join(resolve(clone), "package.json"))("playwright-core")

const sources = join(dirname(fileURLToPath(import.meta.url)), "../../../Sources/KeyScribe/Resources/UltimateConnector")
const root = realpathSync(mkdtempSync(join(tmpdir(), "ks-ultimate-smoke-")))
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
mkdirSync(join(project, ".ultimate"))
writeFileSync(join(project, ".ultimate", "settings.json"), JSON.stringify({ defaultSurface: "inbox" }))
writeFileSync(join(setup, "trust.json"), JSON.stringify({ [project]: true }))
const socketPath = join(bridge, "bridge.sock")
writeFileSync(join(bridge, "token"), "smoke-token\n")
writeFileSync(join(bridge, "ready.json"), JSON.stringify({ launch: "smoke", protocol: 3 }))
for (const name of readdirSync(sources)) copyFileSync(join(sources, name), join(extension, name))
writeFileSync(join(extension, "keyscribe.json"), JSON.stringify({
  protocol: 3, socketPath, tokenPath: join(bridge, "token"), readyPath: join(bridge, "ready.json"), installation: "smoke",
  setup, version: "smoke", appName: "KeyScribe", plugin: "keyscribe",
}))

const told: Array<{ op: string; on?: boolean; session?: string; at: number }> = []
const app = createServer((request, response) => {
  if (request.url === "/poll") return void setTimeout(() => response.end("[]"), 20_000)
  let body = ""
  request.on("data", (chunk) => { body += chunk })
  request.on("end", () => {
    try {
      if (request.url === "/event") told.push({ ...JSON.parse(body), at: Date.now() })
    } catch {}
    response.end("{}")
  })
})
await new Promise<void>((done) => app.listen(socketPath, done))

type Report = { page: string; focused: boolean; conversation: number | null; draft: boolean; pageConversation?: number | null; problem?: string }
const reports: Report[] = []
const problems: string[] = []

async function until<T>(what: string, find: () => T | undefined, seconds = 20): Promise<T> {
  const end = Date.now() + seconds * 1000
  for (;;) {
    const found = find()
    if (found !== undefined) return found
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}; last report: ${JSON.stringify(reports.at(-1))}`)
    await new Promise((done) => setTimeout(done, 200))
  }
}
const after = (index: number, match: (report: Report) => boolean) => () => reports.slice(index).find(match)
const addressed = (url: string) => {
  const value = new URL(url).searchParams.get("conversation")
  return value && /^\d+$/.test(value) ? Number(value) : null
}

const environment = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("ULTIMATE_")))
const child = spawn(node, [join(clone, "bin/ultimate.ts"), project, "--port", String(port), "--no-open"], {
  env: { ...environment, ULTIMATE_USER_HOME: user, ULTIMATE_HOME: join(setup, "projects", "project-smoke"), NO_COLOR: "1" },
  stdio: ["ignore", "pipe", "pipe"],
  detached: true,
})
const output: string[] = []
child.stdout.on("data", (chunk) => output.push(String(chunk)))
child.stderr.on("data", (chunk) => output.push(String(chunk)))

let browser: any
let failed = false
try {
  const origin = `http://127.0.0.1:${port}`
  const api = (path: string, payload?: object) => fetch(origin + path, {
    method: payload ? "POST" : "GET", headers: { origin, "content-type": "application/json" },
    ...(payload ? { body: JSON.stringify(payload) } : {}),
  })
  const upBy = Date.now() + 180_000
  while (!(await api("/api/models").catch(() => null))?.ok) {
    if (Date.now() > upBy || child.exitCode !== null) throw new Error("Ultimate did not start serving")
    await new Promise((done) => setTimeout(done, 1000))
  }
  const first = (await (await api("/api/conversations", { title: "Smoke one" })).json() as { id: number }).id
  const second = (await (await api("/api/conversations", { title: "Smoke two" })).json() as { id: number }).id

  browser = await chromium.launch({ channel: "chrome", headless: true })
  const context = await browser.newContext()
  const page = await context.newPage()
  page.on("pageerror", (error: Error) => problems.push(`page error: ${error.message}`))
  page.on("console", (message: any) => {
    if (message.type() === "error" && /keyscribe/i.test(message.text())) problems.push(`console: ${message.text()}`)
  })
  context.on("request", (request: any) => {
    if (!request.url().endsWith("/api/extensions/keyscribe/actions/page")) return
    const args = request.postDataJSON()?.args
    if (args) reports.push(args as Report)
  })

  await page.goto(`${origin}/?conversation=${first}`)
  const loaded = await until("a first page report", after(0, (report) => report.pageConversation === first), 60)
  assert.equal(loaded.focused, false, "a headless page never claims focus")
  console.log("the page facet loaded and reports the conversation in its address")

  let mark = reports.length
  await page.goto(`${origin}/?conversation=${second}`)
  await until("a report for the second conversation", after(mark, (report) => report.pageConversation === second && report.conversation === second), 30)
  console.log("switching conversations changes the report")

  mark = reports.length
  const box = page.locator(`textarea[data-conversation="${second}"]`).first()
  await box.fill("a draft the smoke check typed")
  await until("a report with a draft", after(mark, (report) => report.conversation === second && report.draft))
  await box.fill("")
  await until("a report without a draft", after(reports.length - 1, (report) => report.conversation === second && !report.draft))
  console.log("typing in the message box flips the draft")

  mark = reports.length
  await page.evaluate(() => {
    const dialog = document.createElement("div")
    dialog.setAttribute("role", "dialog")
    dialog.id = "ks-smoke-dialog"
    dialog.textContent = "smoke dialog"
    document.body.append(dialog)
  })
  await until("a report held by the dialog", after(mark, (report) => report.conversation === null && /dialog/i.test(report.problem ?? "")))
  await page.evaluate(() => document.getElementById("ks-smoke-dialog")?.remove())
  await until("a report after the dialog closed", after(reports.length - 1, (report) => report.conversation === second))
  console.log("a dialog holds the page and its closing releases it")

  await box.fill("an unrelated draft")
  for (const [how, close] of [
    ["removed", (note: HTMLTextAreaElement) => note.remove()],
    ["hidden", (note: HTMLTextAreaElement) => { note.hidden = true }],
    ["disabled", (note: HTMLTextAreaElement) => { note.disabled = true }],
  ] as const) {
    mark = reports.length
    await page.evaluate(() => {
      const note = document.createElement("textarea")
      note.id = "ks-smoke-note"
      note.placeholder = "Anything else?"
      document.body.append(note)
      note.focus()
    })
    await until("a report held by a focused box that is not a message box",
      after(mark, (report) => report.conversation === null && /not a conversation’s message box/.test(report.problem ?? "")))
    mark = reports.length
    await page.evaluate(`(${close.toString()})(document.getElementById("ks-smoke-note"))`)
    await until(`a release within one heartbeat after the other box is ${how}`,
      after(mark, (report) => report.conversation === second && report.draft), 3)
    await page.evaluate(() => document.getElementById("ks-smoke-note")?.remove())
  }
  mark = reports.length
  await page.evaluate(() => {
    const preview = document.createElement("iframe")
    preview.id = "ks-smoke-preview"
    preview.title = "Preview"
    document.body.append(preview)
    preview.focus()
  })
  await page.waitForFunction(() => document.activeElement?.id === "ks-smoke-preview")
  await new Promise((done) => setTimeout(done, 1500))
  assert.deepEqual(reports.slice(mark).filter((report) => report.conversation !== second).map((report) => report.problem), [],
    "focus in a preview frame never holds the take")
  assert.equal(reports.at(-1)!.conversation, second)
  await page.evaluate(() => document.getElementById("ks-smoke-preview")?.remove())
  console.log("focus in a preview frame still names the conversation shown")

  await box.fill("")
  await until("a report without the draft", after(reports.length - 1, (report) => report.conversation === second && !report.draft))
  console.log("focus in another text box holds the take, and closing that box releases it at once")

  mark = reports.length
  await page.locator(`[data-ui="surface-tabs"] [data-surface="inbox"]:visible`).first().click()
  const inInbox = await until("a report from the Inbox",
    after(mark, (report) => report.conversation === null && /has no message box\. Open a conversation, or say its name/.test(report.problem ?? "")))
  assert.equal(inInbox.pageConversation, addressed(page.url()), "the report names the conversation in the browser's address")
  mark = reports.length
  await page.locator(`[data-ui="surface-tabs"] [data-surface="agent"]:visible`).first().click()
  const back = await until("a report after returning to the conversation", after(mark, (report) => report.conversation === second), 30)
  assert.equal(back.pageConversation, addressed(page.url()), "the report names the conversation in the browser's address")
  console.log("a surface with no message box says so and what to do")

  mark = reports.length
  const before = reports.at(-1)!.page
  await page.evaluate(() => window.dispatchEvent(new PageTransitionEvent("pagehide")))
  await until("the leaving page's last report", after(mark, (report) => report.page === before && report.conversation === null))
  mark = reports.length
  await page.reload()
  await until("a report from the reloaded page", after(mark, (report) => report.page !== before && report.pageConversation === second), 60)
  console.log("leaving clears the page's report and a reload reports again")

  mark = reports.length
  const opened = await context.newPage()
  await opened.goto(`${origin}/`)
  await until("a report from the project's default surface",
    after(mark, (report) => report.conversation === null && /has no message box/.test(report.problem ?? "")), 60)
  await opened.close()
  console.log("the surface the project opens on is the one the page reports")

  const held = new AbortController()
  const marked = told.length
  void fetch(origin + "/api/extensions/keyscribe/actions/next", {
    method: "POST", headers: { origin, "content-type": "application/json" }, signal: held.signal,
    body: JSON.stringify({
      args: { page: "smoke-held", seq: 1, focused: true, conversation: second, draft: false, asking: false, labelsOf: [second], labels: {} },
    }),
  }).catch(() => undefined)
  await until("the held page claiming focus", () => told.slice(marked).find((event) => event.op === "shown" && event.on === true), 30)
  const closedAt = Date.now()
  held.abort()
  const releasing = told.length
  const gone = await until("the closed page being forgotten",
    () => told.slice(releasing).find((event) => event.op === "shown" && event.on === false), 45)
  const seconds = (gone.at - closedAt) / 1000
  assert.ok(seconds < 22, `a page whose held request closed is forgotten ${seconds.toFixed(1)} s after it closed, past its silence`)
  console.log(`a page whose held request closes is forgotten ${seconds.toFixed(1)} s later, not after its hold`)

  assert.deepEqual(problems, [], "the page reported errors from the extension")
  console.log("test-ultimate-page-smoke: passed")
} catch (error) {
  failed = true
  console.error(error)
  for (const problem of problems) console.error(problem)
  console.error(output.join("").slice(-4000))
} finally {
  await browser?.close().catch(() => undefined)
  const exited = new Promise((done) => child.exitCode !== null || child.signalCode !== null ? done(undefined) : child.once("exit", done))
  try { process.kill(-child.pid!, "SIGTERM") } catch {}
  await Promise.race([exited, new Promise((done) => setTimeout(done, 10_000))])
  app.close()
  if (!failed) rmSync(root, { recursive: true, force: true })
  else console.error(`kept ${root}`)
  process.exit(failed ? 1 : 0)
}
