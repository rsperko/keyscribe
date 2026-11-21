import assert from "node:assert/strict"
import { test } from "node:test"
import { eventOrders } from "./event-orders.ts"

type Fixture = {
  focus: (focused: boolean) => Promise<void>
  connect: () => Promise<void>
  drain: () => Promise<void>
  reports: () => { on: boolean }[]
  stop: () => void
}

export function focusConnectionContract(adapter: string, create: () => Promise<Fixture>) {
  for (const focus of [["focus", "blur"], ["focus", "blur", "focus-again"]]) {
    for (const order of eventOrders([focus, ["connect"]])) {
      test(`${adapter}: focus survives connection ordering ${order.join(" → ")}`, async () => {
        const fixture = await create()
        try {
          for (const event of order) {
            if (event === "connect") await fixture.connect()
            else await fixture.focus(event !== "blur")
          }
          await fixture.drain()
          assert.equal(fixture.reports().at(-1)?.on, focus.at(-1) !== "blur", order.join(" → "))
        } finally { fixture.stop() }
      })
    }
  }
}
