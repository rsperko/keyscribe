import { expect, test } from 'claude-code/testing'
import { askedToReadAloud, harness, mergeCommand, outcome, readAloudCommand, readAloudTool } from './support'

test('the read-aloud tool asks for the running turn and tells the model only what the app answered', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: 'work', turnId: 't1' })
  await h.answerEvents()
  const cases: Array<[string | null, RegExp]> = [
    ['{"ok":true,"spoken":true}', /will report your final reply/],
    ['{"ok":true,"spoken":false}', /Read Agent Replies Aloud is off/],
    ['{"ok":true,"quiet":true}', /disconnected/],
  ]
  for (const [answer, said] of cases) {
    const call = $.tool.call({ tool: readAloudTool } as any)
    const { body, result } = await askedToReadAloud(h, call, answer)
    expect(body).toMatchObject({ op: 'notify', session: 's1', turn: 't1', on: true })
    expect(String(result.result)).toMatch(said)
  }
})

test('a read-aloud request the app never answers promises nothing', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: 'work', turnId: 't1' })
  await h.answerEvents()
  const call = $.tool.call({ tool: readAloudTool } as any)
  await h.settle()
  await h.clock.advance(5000)
  await h.settle()
  expect(String((await call).result)).toMatch(/didn’t confirm the request, so the reply may not be reported\. Tell the user\.$/)
})

test('a read-aloud command the app never answers says the reply may not come', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  const run = $.command.run({ command: readAloudCommand, args: '' } as any)
  await h.settle()
  await h.clock.advance(5000)
  await h.settle()
  await run
  expect(h.logs.slice(-1)[0]).toMatch(/didn’t confirm the request, so you may not get this reply\.$/)
})

test('the command covers the running turn, the next one when idle, and cancels', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  const idle = $.command.run({ command: readAloudCommand, args: '' } as any)
  const first = await askedToReadAloud(h, idle, '{"ok":true,"spoken":true}')
  expect(first.body).toMatchObject({ op: 'notify', turn: '', on: true })
  expect(first.result.text).toBeUndefined()
  expect(h.logs.slice(-1)[0]).toMatch(/your next reply/)

  await $.turn.start({ text: 'work', turnId: 't2' })
  await h.answerEvents()
  const busy = $.command.run({ command: readAloudCommand, args: '' } as any)
  const second = await askedToReadAloud(h, busy, '{"ok":true,"spoken":true}')
  expect(second.body).toMatchObject({ op: 'notify', turn: 't2', on: true })
  expect(h.logs.slice(-1)[0]).toMatch(/the result of this work/)

  const cancel = $.command.run({ command: readAloudCommand, args: 'cancel' } as any)
  const third = await askedToReadAloud(h, cancel, '{"ok":true,"spoken":true}')
  expect(third.body).toMatchObject({ op: 'notify', turn: 't2', on: false })
  expect(h.logs.slice(-1)[0]).toMatch(/won’t report this reply/)
})

test('a read-aloud request that timed out behind other events is never delivered late', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await h.typed($, 'one')
  await h.typed($, 'two')
  await h.typed($, 'three')
  await h.settle()
  const call = $.tool.call({ tool: readAloudTool } as any)
  for (let i = 0; i < 4; i++) {
    await h.clock.advance(1500)
    await h.settle()
    if (h.open('/event').length) h.open('/event')[0].answer(200)
    await h.settle()
  }
  expect(String((await call).result)).toMatch(/didn’t confirm the request/)
  await h.answerEvents()
  expect(h.ops()).not.toContain('notify')
})

test('a focus runs only the named definition, outside its place it is refused, and it runs before expiry', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  const focus = (id: string, expiresAt: number, definition?: string) => h.deliver([{ op: 'focus', id, expectedSession: 's1', expiresAt, definition }])
  const reasons = (id: string) => h.events().filter((b: any) => b.request === id).map((b: any) => b.reason).filter(Boolean)
  await focus('r1', Number.MAX_SAFE_INTEGER, 'cmux')
  await h.answerEvents()
  expect(reasons('r1')).toEqual(['notInPlace'])
  h.env.CMUX_SURFACE_ID = 'surface-9'
  await h.clock.advance(1000)
  await focus('r2', 1000, 'cmux')
  await h.answerEvents()
  expect(reasons('r2')).toEqual(['expired'])
  await focus('r3', Number.MAX_SAFE_INTEGER, 'cmux')
  await h.answerEvents()
  expect(h.runs.map((r: any) => r.argv ?? r)).toEqual([['/usr/bin/env', 'cmux', 'focus-panel', '--panel', 'surface-9']])
  expect(h.events().filter((b: any) => b.request === 'r3').map((b: any) => b.op)).toContain('focused')
  h.run.exitCode = 1
  await focus('r4', Number.MAX_SAFE_INTEGER, 'cmux')
  await h.answerEvents()
  expect(reasons('r4')).toEqual(['focusFailed'])
})

test('a focus definition is substituted whole, never by a shell, and never from a value that reads as an option', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  const focus = (id: string, definition?: string) => h.deliver([{ op: 'focus', id, expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, definition }])
  const reasons = (id: string) => h.events().filter((b: any) => b.request === id).map((b: any) => b.reason).filter(Boolean)
  h.env.MUX_PANE = 'pane "1" $(touch /tmp/x); rm'
  h.env.TMUX = '7'
  for (const [id, definition] of [['r1', undefined], ['r2', 'unknown'], ['r3', 'stray'], ['r4', 'relative']] as const) {
    await focus(id, definition)
    await h.answerEvents()
    expect(reasons(id)).toEqual(['unknownFocus'])
  }
  expect(h.runs).toEqual([])
  await focus('r5', 'mux')
  await h.answerEvents()
  expect(h.runs.map((r: any) => r.argv ?? r)).toEqual([['/opt/mux/bin/mux', 'focus', '--pane={MUX_PANE}', 'pane "1" $(touch /tmp/x); rm']])
  h.env.MUX_PANE = '-rf'
  await focus('r6', 'mux')
  await h.answerEvents()
  expect(reasons('r6')).toEqual(['unsafeValue'])
  expect(h.runs.length).toBe(1)
})

for (const draft of ['/model', '  !ls']) {
  test(`a draft like ${JSON.stringify(draft)} that would run as a command is never joined, so Return never runs it with the dictation`, async ($, on) => {
    const h = harness(on)
    await h.connect($)
    h.box.text = draft
    await h.deliver([mergeCommand()])
    await h.answerEvents()
    expect(h.fills).toEqual([])
    expect(h.box.text).toBe(draft)
    expect(outcome(h)).toEqual(['ack', 'draft'])
  })
}
