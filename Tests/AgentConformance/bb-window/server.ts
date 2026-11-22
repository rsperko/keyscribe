import type { BbPluginApi } from "@get-bb/plugin-sdk"
import { randomBytes } from "node:crypto"
import { channel, contract, type Answer, type Look, type Seen } from "./contract.ts"

const gather = 1500

export default async function plugin(bb: BbPluginApi) {
  const looks = new Map<string, Answer["windows"]>()
  bb.rpc.register(contract, {
    look: async ({ thread, fill }: Look): Promise<Answer> => {
      const id = randomBytes(6).toString("hex")
      looks.set(id, [])
      bb.realtime.publish(channel, { id, thread, ...(fill === undefined ? {} : { fill }) })
      await new Promise((resolve) => setTimeout(resolve, gather))
      const windows = looks.get(id) ?? []
      looks.delete(id)
      return { windows }
    },
    close: () => {
      bb.realtime.publish(channel, { id: "close", thread: "", close: true })
      return null
    },
    seen: ({ id, ...window }: Seen) => {
      looks.get(id)?.push(window)
      return null
    },
  })
}
