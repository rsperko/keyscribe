import { useRef } from "react"
import { definePluginApp, useBbContext, useComposers, useRealtime, useRpc } from "@get-bb/plugin-sdk/app"
import { channel, contract } from "./contract.ts"

const settle = 400

function WindowReporter() {
  const rpc = useRpc<typeof contract>()
  const context = useBbContext()
  const composers = useComposers()
  const latest = useRef({ context, composers })
  latest.current = { context, composers }
  useRealtime(channel, (payload: { id: string; thread: string; fill?: string; close?: boolean }) => {
    if (payload.close) return window.close()
    const box = () => latest.current.composers.find((composer) => composer.scope.kind === "thread" && composer.scope.threadId === payload.thread)
    if (payload.fill !== undefined) box()?.insert(payload.fill, { at: "end" })
    setTimeout(() => {
      const { context } = latest.current
      void rpc.call("seen", { id: payload.id, shown: context?.threadId ?? null, focused: document.hasFocus(), draft: box()?.text ?? null }).catch(() => {})
    }, settle)
  })
  return null
}

export default definePluginApp((app) => {
  app.slots.experimental_appOverlay({ id: "conformance-window", component: WindowReporter })
})
