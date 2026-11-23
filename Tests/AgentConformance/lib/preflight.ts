import { run } from "./util.ts"

export function appOf(binary: string) {
  const bundle = binary.indexOf(".app/")
  return bundle < 0 ? binary : binary.slice(0, bundle + ".app".length)
}

export function startingApp(pid = process.pid, parentOf: (pid: number) => { parent: number; command: string } | undefined = processInfo) {
  let found: string | undefined
  for (let current = pid, steps = 0; current > 1 && steps < 64; steps++) {
    const info = parentOf(current)
    if (!info) break
    const bundle = info.command.indexOf(".app/")
    if (bundle >= 0) found = info.command.slice(0, bundle + ".app".length)
    current = info.parent
  }
  return found
}

function processInfo(pid: number) {
  const answer = run("/bin/ps", ["-o", "ppid=,comm=", "-p", String(pid)], { timeout: 5 })
  const match = /^\s*(\d+)\s+(.*)$/.exec(answer.stdout.trim())
  return match ? { parent: Number(match[1]), command: match[2] } : undefined
}

export function inputUnseen(binary: string, starter: string | null = startingApp() ?? null) {
  const from = starter ? `the app this run was started from, ${starter}` : "the terminal or app this run was started from"
  return `the test instance does not see key presses and clicks, so it can never confirm the conversation in front. `
    + `macOS charges a test instance's Accessibility to ${from}, not to ${appOf(binary)}. `
    + `Turn on Accessibility for that app in System Settings > Privacy & Security, or start the run from a terminal that has it, then run again. `
    + `The instance only listens; it never takes your key presses.`
}

export function voiceOverOn() {
  return run("/usr/bin/pgrep", ["-x", "VoiceOver"], { timeout: 5 }).status === 0
}

export const voiceOverBlocks = "VoiceOver is on, and under it a reply panel stays open until someone closes it, so each later reply would wait behind it. Turn VoiceOver off for the run."
