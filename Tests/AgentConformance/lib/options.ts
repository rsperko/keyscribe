function flagValue(argv: string[], flag: string): string | undefined {
  const index = argv.indexOf(flag)
  return index >= 0 ? argv[index + 1] : undefined
}

function parseRepeat(raw: string | undefined): number {
  if (raw === undefined || raw === "") return 1
  const value = Number(raw)
  if (!Number.isInteger(value) || value < 1) throw new Error(`--repeat must be a positive integer (got ${raw})`)
  return value
}

export type RunOptions = {
  agent: string | undefined
  only: string[] | undefined
  failFast: boolean
  repeat: number
  keep: boolean
  replyWait: number
}

export function parseRunOptions(argv: string[], env: NodeJS.ProcessEnv): RunOptions {
  const onlyRaw = flagValue(argv, "--only") ?? env.ONLY
  return {
    agent: flagValue(argv, "--agent") ?? env.AGENT,
    only: onlyRaw ? onlyRaw.split(",").map(s => s.trim()).filter(Boolean) : undefined,
    failFast: argv.includes("--fail-fast") || env.FAIL_FAST === "1",
    repeat: parseRepeat(flagValue(argv, "--repeat") ?? env.REPEAT),
    keep: argv.includes("--keep") || env.KEEP === "1",
    replyWait: Number(env.REPLY_WAIT ?? 120),
  }
}

export type PageTargetKind = "worker" | "main" | "branch" | "created" | "side"
const validPageTargets = new Set<PageTargetKind>(["worker", "main", "branch", "created", "side"])

export type PageOptions = {
  only: RegExp | undefined
  targets: Set<PageTargetKind> | undefined
  failFast: boolean
  repeat: number
  keep: boolean
  replyWait: number
}

export function parsePageOptions(argv: string[], env: NodeJS.ProcessEnv): PageOptions {
  const onlyRaw = flagValue(argv, "--only") ?? env.ONLY
  const targetsRaw = flagValue(argv, "--targets") ?? env.TARGETS
  let targets: Set<PageTargetKind> | undefined
  if (targetsRaw) {
    targets = new Set<PageTargetKind>()
    for (const part of targetsRaw.split(",").map(s => s.trim()).filter(Boolean)) {
      if (!validPageTargets.has(part as PageTargetKind)) {
        throw new Error(`unknown --targets entry "${part}" (valid: ${[...validPageTargets].join(", ")})`)
      }
      targets.add(part as PageTargetKind)
    }
  }
  return {
    only: onlyRaw ? new RegExp(onlyRaw, "i") : undefined,
    targets,
    failFast: argv.includes("--fail-fast") || env.FAIL_FAST === "1",
    repeat: parseRepeat(flagValue(argv, "--repeat") ?? env.REPEAT),
    keep: argv.includes("--keep") || env.KEEP === "1",
    replyWait: Number(env.REPLY_WAIT ?? 90),
  }
}

export function matchesPageCase(only: RegExp | undefined, label: string, kind: string): boolean {
  if (!only) return true
  return only.test(label) || only.test(`${kind} ${label}`)
}
