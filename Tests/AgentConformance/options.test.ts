import assert from "node:assert/strict"
import { test } from "node:test"
import { matchesPageCase, parsePageOptions, parseRunOptions } from "./lib/options.ts"

test("parseRunOptions reads agent, only, fail-fast, repeat, keep and reply wait", () => {
  const parsed = parseRunOptions(
    ["--agent", "bb", "--only", "D1,R1", "--fail-fast", "--repeat", "3", "--keep"],
    { REPLY_WAIT: "45" },
  )
  assert.deepEqual(parsed, {
    agent: "bb",
    only: ["D1", "R1"],
    failFast: true,
    repeat: 3,
    keep: true,
    replyWait: 45,
  })
  assert.throws(() => parseRunOptions(["--agent", "bb", "--repeat", "0"], {}), /repeat/)
})

test("parsePageOptions parses only, targets, fail-fast and repeat while defaulting to full matrix", () => {
  const full = parsePageOptions([], {})
  assert.equal(full.only, undefined)
  assert.equal(full.targets, undefined)
  assert.equal(full.failFast, false)
  assert.equal(full.repeat, 1)

  const narrow = parsePageOptions(["--only", "first-run|Tab", "--targets", "main,side", "--fail-fast", "--repeat", "5"], {})
  assert.equal(narrow.failFast, true)
  assert.equal(narrow.repeat, 5)
  assert.deepEqual([...narrow.targets!].sort(), ["main", "side"])
  assert.equal(matchesPageCase(narrow.only, "first-run dialog holds", "main"), true)
  assert.equal(matchesPageCase(narrow.only, "clipboard image", "side"), false)
})
