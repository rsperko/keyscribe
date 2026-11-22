export type Look = { thread: string; fill?: string }
export type Seen = { id: string; shown: string | null; focused: boolean; draft: string | null }
export type Answer = { windows: Omit<Seen, "id">[] }

export const channel = "conformance-window"

type Checked<T> = { value: T } | { issues: { message: string }[] }
const schema = <T,>(accepts: (value: unknown) => value is T, message: string) => ({
  "~standard": { version: 1 as const, vendor: "keyscribe-conformance", validate: (value: unknown): Checked<T> => accepts(value) ? { value } : { issues: [{ message }] } },
})

const isLook = (value: unknown): value is Look => {
  const look = value as Record<string, unknown> | null
  return !!look && typeof look.thread === "string" && (look.fill === undefined || typeof look.fill === "string")
}
const isSeen = (value: unknown): value is Seen => {
  const seen = value as Record<string, unknown> | null
  return !!seen && typeof seen.id === "string" && (seen.shown === null || typeof seen.shown === "string")
    && typeof seen.focused === "boolean" && (seen.draft === null || typeof seen.draft === "string")
}
const isAnswer = (value: unknown): value is Answer => Array.isArray((value as Record<string, unknown> | null)?.windows)

const isNothing = (value: unknown): value is null => value === null

export const contract = {
  look: { input: schema(isLook, "expected { thread, fill? }"), output: schema(isAnswer, "expected { windows }") },
  close: { input: schema(isLook, "expected { thread }"), output: schema(isNothing, "expected null") },
  seen: { input: schema(isSeen, "expected { id, shown, focused, draft }"), output: schema(isNothing, "expected null") },
}
