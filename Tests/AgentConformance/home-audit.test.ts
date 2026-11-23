import assert from "node:assert/strict"
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { auditLimit, homeChanges, snapshotHome } from "./lib/home-audit.ts"

function home() {
  const folder = mkdtempSync(join(tmpdir(), "ks-home-"))
  mkdirSync(join(folder, ".codex"))
  writeFileSync(join(folder, ".codex", "config.toml"), "model = \"x\"\n")
  writeFileSync(join(folder, ".codex", "hooks.json"), "{}")
  mkdirSync(join(folder, ".pi", "agent", "extensions", "mine"), { recursive: true })
  writeFileSync(join(folder, ".pi", "agent", "extensions", "mine", "index.ts"), "export {}")
  return folder
}

test("a run that leaves the agents' files in the user's home alone reports nothing", () => {
  const folder = home()
  try {
    const before = snapshotHome(folder)
    writeFileSync(join(folder, ".codex", "history.jsonl"), "{}")
    assert.deepEqual(homeChanges(before, snapshotHome(folder)), [])
  } finally { rmSync(folder, { recursive: true, force: true }) }
})

test("each file the run changed, added or removed in the user's home is named", () => {
  const folder = home()
  try {
    const before = snapshotHome(folder)
    writeFileSync(join(folder, ".codex", "config.toml"), "model = \"x\"\n[projects.\"/tmp/scratch\"]\ntrust_level = \"trusted\"\n")
    rmSync(join(folder, ".codex", "hooks.json"))
    mkdirSync(join(folder, ".pi", "agent", "extensions", "keyscribe"))
    writeFileSync(join(folder, ".pi", "agent", "extensions", "keyscribe", "index.ts"), "export {}")
    assert.deepEqual(homeChanges(before, snapshotHome(folder)).sort(), [
      `added ${join(folder, ".pi", "agent", "extensions", "keyscribe")}/`,
      `added ${join(folder, ".pi", "agent", "extensions", "keyscribe", "index.ts")}`,
      `changed ${join(folder, ".codex", "config.toml")}`,
      `removed ${join(folder, ".codex", "hooks.json")}`,
    ])
  } finally { rmSync(folder, { recursive: true, force: true }) }
})

test("a linked extension is recorded as its link, so a link back to its own folder or a large checkout is never walked", () => {
  const folder = home()
  const checkout = mkdtempSync(join(tmpdir(), "ks-checkout-"))
  try {
    writeFileSync(join(checkout, "index.ts"), "export {}")
    symlinkSync(checkout, join(folder, ".pi", "agent", "extensions", "linked"))
    symlinkSync(join(folder, ".pi", "agent"), join(folder, ".pi", "agent", "extensions", "loop"))
    const before = snapshotHome(folder)
    assert.equal(before.get(join(folder, ".pi", "agent", "extensions", "linked")), `link to ${checkout}`)
    assert.ok(![...before.keys()].some((path) => path.startsWith(join(folder, ".pi", "agent", "extensions", "loop", "/"))))
    writeFileSync(join(checkout, "index.ts"), "export const changed = 1")
    assert.deepEqual(homeChanges(before, snapshotHome(folder)), [])
  } finally {
    rmSync(folder, { recursive: true, force: true })
    rmSync(checkout, { recursive: true, force: true })
  }
})

test("a folder too large to compare fails the audit saying where, instead of stalling the run", () => {
  const folder = home()
  try {
    const crowded = join(folder, ".pi", "agent", "extensions", "crowded")
    mkdirSync(crowded)
    for (let index = 0; index <= auditLimit; index++) writeFileSync(join(crowded, `f${index}`), "")
    assert.throws(() => snapshotHome(folder), /could not record the agents' files.*more than/)
  } finally { rmSync(folder, { recursive: true, force: true }) }
})

test("a configuration file kept elsewhere through a link is checked by what it holds, not only where it points", () => {
  const folder = home()
  const dotfiles = mkdtempSync(join(tmpdir(), "ks-dotfiles-"))
  try {
    writeFileSync(join(dotfiles, "config.toml"), "model = \"x\"\n")
    rmSync(join(folder, ".codex", "config.toml"))
    symlinkSync(join(dotfiles, "config.toml"), join(folder, ".codex", "config.toml"))
    const before = snapshotHome(folder)
    writeFileSync(join(dotfiles, "config.toml"), "model = \"x\"\n[projects.\"/tmp/scratch\"]\ntrust_level = \"trusted\"\n")
    assert.deepEqual(homeChanges(before, snapshotHome(folder)), [`changed ${join(folder, ".codex", "config.toml")}`])
  } finally {
    rmSync(folder, { recursive: true, force: true })
    rmSync(dotfiles, { recursive: true, force: true })
  }
})
