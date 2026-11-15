import { useEffect, useRef } from "react"
import { definePluginApp, useBbContext, useRpc, useSidebarSplitLayout } from "@get-bb/plugin-sdk/app"
import { shownThread } from "./keyscribe.ts"
import type { rpcContract } from "./server.ts"

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
})
