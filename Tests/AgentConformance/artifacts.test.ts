import assert from "node:assert/strict"
import { test } from "node:test"
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { failureBundle } from "./lib/artifacts.ts"

test("failure evidence retains the case, app history and agent record without copying credentials", async () => {
  const root = mkdtempSync(join(tmpdir(), "verification-evidence-"))
  try {
    mkdirSync(join(root, "history"))
    writeFileSync(join(root, "app.log"), "a report reached the app")
    writeFileSync(join(root, "history", "2026-11-21.jsonl"), '{"heard":"fixture take"}\n')
    writeFileSync(join(root, "auth.json"), "credentials must stay here")
    const folder = await failureBundle(root, "branch/front", new Error("wrong recipient"), {
      "agent-record": () => [{ role: "user", text: "fixture take" }],
      "unavailable-reader": () => { throw new Error("not connected") },
    })
    assert.equal(JSON.parse(readFileSync(join(folder, "failure.json"), "utf8")).case, "branch/front")
    assert.equal(readFileSync(join(folder, "app.log"), "utf8"), "a report reached the app")
    assert.match(readFileSync(join(folder, "history-2026-11-21.jsonl"), "utf8"), /fixture take/)
    assert.equal(JSON.parse(readFileSync(join(folder, "agent-record.json"), "utf8"))[0].text, "fixture take")
    assert.match(readFileSync(join(folder, "unavailable-reader.error.txt"), "utf8"), /not connected/)
    assert.equal(existsSync(join(folder, "auth.json")), false)
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test("a reader that returns image bytes leaves a picture beside the other evidence", async () => {
  const root = mkdtempSync(join(tmpdir(), "verification-evidence-"))
  try {
    const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    const folder = await failureBundle(root, "dialog", new Error("timed out"), { "page-screenshot": () => png })
    assert.deepEqual(readFileSync(join(folder, "page-screenshot.png")), png)
    assert.equal(existsSync(join(folder, "page-screenshot.json")), false)
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test("a reader with nothing to show says so instead of failing to write", async () => {
  const root = mkdtempSync(join(tmpdir(), "verification-evidence-"))
  try {
    const folder = await failureBundle(root, "setup", new Error("no page yet"), { page: () => undefined })
    assert.equal(readFileSync(join(folder, "page.txt"), "utf8"), "nothing to show")
    assert.equal(existsSync(join(folder, "page.error.txt")), false)
  } finally { rmSync(root, { recursive: true, force: true }) }
})
