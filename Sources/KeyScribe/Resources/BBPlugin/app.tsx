import { useEffect, useRef } from "react"
import {
  definePluginApp, experimental_Icon as Icon, experimental_useRpcKeyedQuery, useBbContext, useComposer, useComposers, useRealtime, useRpc,
  useSidebarSplitLayout,
  type ExperimentalThreadRowMetadataDataInput, type ExperimentalThreadRowMetadataProps, type PluginComposerApi,
} from "@get-bb/plugin-sdk/app"
import { ComposerAnswers, composeChannel, composeInto, isComposeAsk, rowLabel, rpcContract, shownThread } from "./keyscribe.ts"

type Labels = Record<string, string | null> | undefined

function useLabels({ threads }: ExperimentalThreadRowMetadataDataInput): Labels {
  const keys = threads.map((thread) => thread.id)
  return experimental_useRpcKeyedQuery({ contract: rpcContract, method: "labels", keys, enabled: keys.length > 0 }).data as Labels
}

function SpokenName({ thread, data }: ExperimentalThreadRowMetadataProps<Labels>) {
  const name = rowLabel(data?.[thread.id], thread.title)
  if (!name) return null
  return (
    <span title="The name to say when you dictate to this thread" style={chip}>
      <Icon name="Mic" aria-hidden style={{ width: "1em", height: "1em", flexShrink: 0 }} />
      <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{name}</span>
    </span>
  )
}

const chip = {
  display: "inline-flex", alignItems: "center", gap: "0.3em", maxWidth: "100%", minWidth: 0,
  padding: "0 0.45em", borderRadius: "999px", fontSize: "0.8em", lineHeight: 1.6,
  border: "1px solid color-mix(in srgb, currentColor 30%, transparent)",
  background: "color-mix(in srgb, currentColor 8%, transparent)", opacity: 0.85,
} as const

const heartbeat = 5000
const windowId = Math.random().toString(36).slice(2, 12)
const unreachable = "This window can\u2019t reach the voice app\u2019s plugin yet. Try again in a moment."
const answerPopup = "read-aloud-answer"
const answers = new ComposerAnswers()

let askReadAloud: ((thread: string, on: boolean) => Promise<{ message: string }>) | null = null

async function readAloud(composer: PluginComposerApi, on: boolean) {
  if (composer.scope.kind !== "thread") return
  const request = answers.begin(composer.key)
  const ask = askReadAloud
  let message = unreachable
  if (ask) {
    try {
      message = (await ask(composer.scope.threadId, on)).message
    } catch {}
  }
  if (answers.settle(composer.key, request, message)) composer.experimental_openPopup(answerPopup)
}

function ReadAloudBridge() {
  const rpc = useRpc<typeof rpcContract>()
  useEffect(() => {
    const ask = (thread: string, on: boolean) => rpc.call("readAloud", { thread, on })
    askReadAloud = ask
    return () => {
      if (askReadAloud === ask) askReadAloud = null
    }
  }, [rpc])
  return null
}

function ReadAloudAnswer() {
  const composer = useComposer()
  return <div role="status" style={{ padding: "0.6em 0.8em", maxWidth: "28em" }}>{answers.answer(composer.key) ?? ""}</div>
}

function ComposeBridge() {
  const rpc = useRpc<typeof rpcContract>()
  const composers = useComposers()
  const latest = useRef(composers)
  latest.current = composers
  for (const box of composers) void [box.text, box.isSubmittingBlocked]
  useRealtime(composeChannel, (payload) => {
    if (!isComposeAsk(payload) || payload.window !== windowId) return
    void rpc.call("composing", { id: payload.id })
      .then(async ({ go }) => {
        if (!go) return
        const answer = await composeInto(latest.current, payload.thread, payload.text, () => latest.current)
        await rpc.call("composed", { id: payload.id, ...answer })
      })
      .catch(() => {})
  })
  return null
}

const readAloudCommands = [
  { id: "read-reply-aloud", label: "Read this thread\u2019s reply aloud", on: true },
  { id: "stop-reading-reply-aloud", label: "Don\u2019t read this thread\u2019s reply aloud", on: false },
]

function FocusReporter() {
  const rpc = useRpc<typeof rpcContract>()
  const context = useBbContext()
  const split = useSidebarSplitLayout()
  const composers = useComposers()
  const thread = shownThread(context?.threadId ?? null, split?.panes ?? null)
  const draft = thread !== null && composers.some((box) => box.scope.kind === "thread" && box.scope.threadId === thread && !box.isEmpty)
  const newThread = thread === null && !context?.threadId && composers.some((box) => box.scope.kind === "new-thread")
  const latest = useRef({ thread, draft, newThread })
  latest.current = { thread, draft, newThread }

  const send = () => {
    rpc.call("window", { window: windowId, focused: document.hasFocus(), ...latest.current }).catch(() => {})
  }

  useEffect(send, [thread, draft, newThread])

  useEffect(() => {
    let timer: ReturnType<typeof setInterval> | null = null
    const pace = () => {
      if (document.hidden && timer) {
        clearInterval(timer)
        timer = null
      } else if (!document.hidden && !timer) {
        timer = setInterval(send, heartbeat)
      }
    }
    const visibility = () => {
      pace()
      send()
    }
    window.addEventListener("focus", send)
    window.addEventListener("blur", send)
    document.addEventListener("visibilitychange", visibility)
    pace()
    return () => {
      window.removeEventListener("focus", send)
      window.removeEventListener("blur", send)
      document.removeEventListener("visibilitychange", visibility)
      if (timer) clearInterval(timer)
    }
  }, [])

  return null
}

export default definePluginApp((app) => {
  app.slots.experimental_appOverlay({ id: "focus-reporter", component: FocusReporter })
  app.slots.experimental_appOverlay({ id: "read-aloud-bridge", component: ReadAloudBridge })
  app.slots.experimental_appOverlay({ id: "compose-bridge", component: ComposeBridge })
  app.slots.experimental_threadRowMetadata<Labels>({ id: "spoken-name", useData: useLabels, component: SpokenName })
  app.composer.customize({
    id: "read-aloud",
    scopes: ["thread"],
    plusMenu: readAloudCommands.map(({ id, label, on }) => ({ id, label, icon: "Mic", run: ({ composer }) => readAloud(composer, on) })),
    experimental_popups: [{ id: answerPopup, label: "Reply read aloud", component: ReadAloudAnswer }],
  })
  for (const { id, label, on } of readAloudCommands) {
    app.composer.experimental_registerCommand({ id, title: label, run: ({ composer }) => readAloud(composer, on) })
  }
})
