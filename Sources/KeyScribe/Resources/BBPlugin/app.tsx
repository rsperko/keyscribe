import { useEffect, useRef } from "react"
import {
  definePluginApp, experimental_Icon as Icon, experimental_useRpcKeyedQuery, useBbContext, useRpc, useSidebarSplitLayout,
  type ExperimentalThreadRowMetadataDataInput, type ExperimentalThreadRowMetadataProps,
} from "@get-bb/plugin-sdk/app"
import { rowLabel, rpcContract, shownThread } from "./keyscribe.ts"

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

function FocusReporter() {
  const rpc = useRpc<typeof rpcContract>()
  const context = useBbContext()
  const split = useSidebarSplitLayout()
  const thread = shownThread(context?.threadId ?? null, split?.panes ?? null)
  const latest = useRef(thread)
  latest.current = thread

  const send = () => {
    rpc.call("window", { window: windowId, focused: document.hasFocus(), thread: latest.current }).catch(() => {})
  }

  useEffect(send, [thread])

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
  app.slots.experimental_threadRowMetadata<Labels>({ id: "spoken-name", useData: useLabels, component: SpokenName })
})
