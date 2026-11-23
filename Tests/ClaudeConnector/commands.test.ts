import { expect, test } from 'claude-code/testing'
import { harness, staleReply } from './support'

test('a check says whether a dictation is still held, handed to the agent, in the conversation, refused or unknown', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  const check = (id: string, request: string) => ({ op: 'check', id, expectedSession: 's1', request, expiresAt: Number.MAX_SAFE_INTEGER })
  h.box.held = true
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests' }])
  await h.answerEvents()
  await h.deliver([check('c1', 'r1')])
  await h.answerEvents()
  h.submitHold.on = true
  h.reads[0]()
  await h.settle()
  await h.deliver([check('c2', 'r1')])
  await h.answerEvents()
  h.releaseSubmits()
  await h.settle()
  await h.answerEvents()
  await h.deliver([check('c3', 'r1'), check('c4', 'r9')])
  await h.answerEvents()
  h.submitHold.on = false
  h.box.held = false
  h.downstream['prompt.submit'] = { drop: 'blocked by a hook' }
  await h.deliver([{ op: 'submit', id: 'r2', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'two' }])
  await h.answerEvents()
  await h.deliver([check('c5', 'r2')])
  await h.answerEvents()
  const checked = h.events().filter((b: any) => b.op === 'checked')
  expect(checked.map((b: any) => [b.check, b.request, b.state])).toEqual([['c1', 'r1', 'holding'], ['c2', 'r1', 'handed'], ['c3', 'r1', 'seen'], ['c4', 'r9', 'unknown'], ['c5', 'r2', 'refused']])
  expect(checked[4].reason).toBe('blocked by a hook')
})

test('a command being prepared when the connection is lost never acts', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.box.held = true
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'use approach B' }])
  expect(h.reads.length).toBe(1)

  await h.typed($)
  await h.settle()
  await h.clock.advance(2000)
  await h.settle()
  h.reads[0]()
  await h.settle()
  expect(h.submits).toEqual([])
})

test('a reply finishing after a disconnect is dropped while the replacement says hello', ($, on) => staleReply($, on, 'beforeHello'))

test('a reply finishing after a disconnect never speaks for the replacement connection', ($, on) => staleReply($, on, 'afterHello'))

test('every hello opens a new connection that its events, replies and polls carry', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  const first = h.events()[0].connection
  expect(typeof first).toBe('string')
  expect(h.open('/poll')[0].body).toMatchObject({ session: 's1', connection: first })
  await h.typed($)
  await h.deliver([{ op: 'status', id: 'r1', expectedSession: 's1', text: 'Dictating' }])
  await h.answerEvents()
  expect(h.events().slice(1).map((b) => [b.op, b.instance, b.connection])).toEqual([
    ['typed', h.events()[0].instance, first],
    ['ack', h.events()[0].instance, first],
  ])

  h.open('/poll')[0].answer(409)
  await h.settle()
  const second = h.events().slice(-1)[0]
  expect(second.op).toBe('hello')
  expect(second.connection).not.toBe(first)
  h.open('/event')[0].answer(200)
  await h.settle()
  expect(h.open('/poll')[0].body.connection).toBe(second.connection)
})

test('a command repeated on the same connection runs once and keeps nothing in plugin storage', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests', expectedPrompts: 0 }])
  await h.answerEvents()
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests', expectedPrompts: 0 }])
  await h.answerEvents()
  expect(h.submits).toEqual(['run the tests'])
  expect(h.events().filter((b) => b.request === 'r1').map((b) => b.op)).toEqual(['ack', 'submitted', 'ack'])
  expect(h.store.size).toBe(0)
})

test('admitting more commands than one connection remembers reconnects before acting', { timeoutMs: 120000 }, async ($, on) => {
  const h = harness(on)
  await h.connect($)
  const quick = () => new Promise((resolve) => setTimeout(resolve, 0))
  for (let batch = 0; batch < 4096 / 32; batch++) {
    const commands = Array.from({ length: 32 }, (_, i) => ({ op: 'status', id: 'c' + (batch * 32 + i), expectedSession: 's1', text: 'n' + (batch * 32 + i) }))
    h.open('/poll')[0].answer(200, JSON.stringify(commands))
    await quick()
    while (h.open('/event').length) {
      h.open('/event')[0].answer(200)
      await quick()
    }
  }
  expect(h.statuses.length).toBe(4096)
  expect(h.ops().filter((op) => op === 'hello').length).toBe(1)

  await h.deliver([{ op: 'status', id: 'over', expectedSession: 's1', text: 'one too many' }])
  expect(h.statuses.slice(-1)).toEqual([undefined])
  expect(h.statuses).not.toContain('one too many')
  expect(h.events().some((b) => b.request === 'over')).toBe(false)
  expect(h.ops().slice(-1)).toEqual(['hello'])
})
