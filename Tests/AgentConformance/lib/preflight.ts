import { run } from "./util.ts"

export function appOf(binary: string) {
  const bundle = binary.indexOf(".app/")
  return bundle < 0 ? binary : binary.slice(0, bundle + ".app".length)
}

export function inputUnseen(binary: string) {
  return `the test instance does not see key presses and clicks, so it can never confirm the conversation in front. `
    + `Turn on Accessibility for ${appOf(binary)} in System Settings > Privacy & Security, then run again. `
    + `It only listens; it never takes your key presses.`
}

export function voiceOverOn() {
  return run("/usr/bin/pgrep", ["-x", "VoiceOver"], { timeout: 5 }).status === 0
}

export const voiceOverBlocks = "VoiceOver is on, and under it a reply panel stays open until someone closes it, so each later reply would wait behind it. Turn VoiceOver off for the run."
