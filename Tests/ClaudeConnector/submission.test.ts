import { expect, test } from 'claude-code/testing'
import { boxCommand, harness, outcome, submitCommand, cleared } from './support'

test('a dictation for the prompt box with no turn running is submitted as usual', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await h.deliver([boxCommand()])
  await h.answerEvents()
  expect(h.fills).toEqual([])
  expect(h.submits).toEqual(['run the tests'])
  expect(outcome(h)).toEqual(['ack', 'submitted'])
})

test('a submission that goes through never touches the prompt box', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await h.deliver([submitCommand()])
  await h.answerEvents()
  expect(h.fills).toEqual([])
  expect(outcome(h)).toEqual(['ack', 'submitted'])
})

test('dictation decided on the current prompt count is submitted, acknowledged first', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await h.typed($)
  await h.answerEvents()

  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests', expectedPrompts: 1 }])
  await h.answerEvents()
  expect(h.submits).toEqual(['run the tests'])
  expect(h.events().filter((b) => b.request === 'r1').map((b) => b.op)).toEqual(['ack', 'submitted'])
})

test('a submit names the turn its own prompt started', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.submitHold.on = true
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests' }])
  await $.turn.start({ text: 'run the tests', turnId: 't2' })
  h.releaseSubmits()
  await h.answerEvents()
  expect(h.events().filter((b: any) => b.op === 'submitted').map((b: any) => b.turn)).toEqual(['t2'])
})

test('a turn someone else started while the submit was in flight is never named as the submit\'s own', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.submitHold.on = true
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests' }])
  await $.turn.start({ text: 'typed by me', turnId: 't1' })
  h.releaseSubmits()
  await h.answerEvents()
  expect(h.events().filter((b: any) => b.op === 'submitted').map((b: any) => b.turn)).toEqual([''])
})

test('the connector own submission does not count as the user typing', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'one', expectedPrompts: 0 }])
  await h.answerEvents()
  await h.deliver([{ op: 'submit', id: 'r2', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'two', expectedPrompts: 0 }])
  await h.answerEvents()
  expect(h.submits).toEqual(['one', 'two'])
})

test('dictation never submits over a message the user is still writing, and leaves it in place', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.box.text = 'half a thought'
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests', expectedPrompts: 0 }])
  await h.answerEvents()
  expect(h.submits).toEqual([])
  expect(h.events().filter((b) => b.request === 'r1').map((b) => b.reason ?? b.op)).toEqual(['ack', 'draft'])
})

test('a prompt sent while the draft is being read holds the dictation', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.box.held = true
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests', expectedPrompts: 0 }])
  expect(h.reads.length).toBe(1)
  await h.typed($)
  await h.settle()
  h.reads[0]()
  await h.answerEvents()
  expect(h.submits).toEqual([])
  expect(h.events().filter((b) => b.request === 'r1').map((b) => b.reason ?? b.op)).toEqual(['ack', 'typedSince'])
})

test('a dictation still being checked when the conversation is disconnected is refused and never sent', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.box.held = true
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests', expectedPrompts: 0 }])
  expect(h.reads.length).toBe(1)
  await h.deliver([{ op: 'quiet', id: 'q1', expectedSession: 's1' }])
  h.reads[0]()
  await h.answerEvents()
  expect(h.submits).toEqual([])
  expect(h.events().filter((b) => b.request === 'r1').map((b) => b.reason ?? b.op)).toEqual(['ack', 'disconnected'])
})

test('a turn starting while the draft is being read refuses the dictation as working, for the app to queue', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.box.held = true
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests', expectedPrompts: 0 }])
  expect(h.reads.length).toBe(1)
  await $.turn.start({ text: '', turnId: 't1' })
  await h.settle()
  h.reads[0]()
  await h.answerEvents()
  expect(h.submits).toEqual([])
  expect(h.events().filter((b) => b.request === 'r1').map((b) => b.reason ?? b.op)).toEqual(['ack', 'working'])
})

test('a dictation refused for a draft is delivered when sent again as its next attempt, never under its first id', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.box.text = 'half typed'
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests' }])
  await h.answerEvents()
  h.box.text = ''
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests' }])
  await h.answerEvents()
  expect(h.submits).toEqual([])
  await h.deliver([{ op: 'submit', id: 'r1~1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests' }])
  await h.answerEvents()
  expect(h.submits).toEqual(['run the tests'])
  expect(h.events().filter((b: any) => b.op === 'submitted').map((b: any) => b.request)).toEqual(['r1~1'])
})

test('a submission whose deadline passes while the draft is being read is refused as expired and never submits', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.box.held = true
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: (await h.clock.now()) + 500, text: 'run the tests', expectedPrompts: 0 }])
  expect(h.reads.length).toBe(1)
  await h.clock.advance(1000)
  h.reads[0]()
  await h.answerEvents()
  expect(h.submits).toEqual([])
  expect(h.events().filter((e: any) => e.request === 'r1' && e.reason).map((e: any) => e.reason)).toEqual(['expired'])
})

test('a session replaced while the draft is being read never submits', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.box.held = true
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests', expectedPrompts: 0 }])
  expect(h.reads.length).toBe(1)
  await cleared($, h, 's2')
  await h.settle()
  h.reads[0]()
  await h.answerEvents()
  expect(h.submits).toEqual([])
})

for (const [origin, counts] of [
  [{ kind: 'composer' }, true],
  [{ kind: 'bridge' }, true],
  [{ kind: 'slack-ping' }, true],
  [{ kind: 'unclassified' }, true],
  [{ kind: 'plugin', name: 'another', asUser: true }, false],
  [{ kind: 'task-notification' }, false],
  [{ kind: 'scheduled-trigger' }, false],
] as const) {
  test(`a ${origin.kind} prompt ${counts ? 'counts' : 'does not count'} as the user typing`, async ($, on) => {
    const h = harness(on)
    await h.connect($)
    await $.prompt.submit({ text: 'something', origin, wait: false })
    await h.answerEvents()
    expect(h.events().filter((b) => b.op === 'typed').map((b) => b.prompts)).toEqual(counts ? [1] : [])
  })
}

test('a full queue disconnects, acts on nothing it had, and says hello again only once the sender is free', async ($, on) => {
  const h = harness(on)
  await h.connect($)

  for (let i = 0; i < 80; i++) await h.typed($, 'prompt ' + i)
  await h.settle()
  expect(h.ops()).toEqual(['hello', 'typed'])

  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'late', expectedPrompts: 80 }])
  expect(h.submits).toEqual([])
  h.open('/event')[0].answer(200)
  await h.settle()
  expect(h.ops()).toEqual(['hello', 'typed', 'hello'])
  expect(h.events()[2].gap).toBe(true)
  expect(h.events().some((b) => b.request === 'r1')).toBe(false)
})

test('an event past its deadline disconnects, but the next send waits for that request to settle', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await h.typed($)
  await h.settle()
  const stuck = h.open('/event')[0]

  await h.clock.advance(2000)
  await h.settle()
  expect(h.open('/event')).toEqual([stuck])
  await h.typed($, 'dropped while disconnected')
  await h.clock.advance(60000)
  await h.settle()
  expect(h.open('/event')).toEqual([stuck])

  stuck.answer(200)
  await h.settle()
  expect(h.ops()).toEqual(['hello', 'typed', 'hello'])
  expect(h.events()[2]).toMatchObject({ op: 'hello', session: 's1', gap: true, prompts: 2 })
})

test('a poll past its deadline disconnects, and polling resumes only after it settles', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  const stuck = h.open('/poll')[0]

  await h.clock.advance(28000)
  await h.settle()
  expect(h.ops()).toEqual(['hello', 'hello'])
  h.open('/event')[0].answer(200)
  await h.settle()
  expect(h.open('/poll')).toEqual([stuck])

  stuck.answer(200, JSON.stringify([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'late', expectedPrompts: 0 }]))
  await h.settle()
  expect(h.submits).toEqual([])
  expect(h.open('/poll').length).toBe(1)
  expect(h.open('/poll')[0]).not.toBe(stuck)
})

test('a submission whose clock read is still pending when its session is cleared never submits into the next session', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.box.held = true
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests' }])
  await h.answerEvents()
  h.clockHold.on = true
  h.reads[0]()
  await h.settle()
  expect(h.clockHold.held.length).toBeGreaterThan(0)
  h.clockHold.on = false
  await cleared($, h, 's2')
  await h.settle()
  for (const release of h.clockHold.held.splice(0)) release()
  await h.settle()
  await h.answerEvents()
  expect(h.submits).toEqual([])
  expect(h.events().filter((b: any) => b.op === 'submitted')).toEqual([])
})

test('a submission still in flight when its session is cleared never confirms on the next session', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.submitHold.on = true
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests' }])
  await h.answerEvents()
  await cleared($, h, 's2')
  await h.settle()
  await h.answerEvents()
  h.releaseSubmits()
  await h.settle()
  await h.answerEvents()
  expect(h.events().filter((b: any) => b.op === 'submitted')).toEqual([])
})

test('a confirmation lost with its connection is sent again once the connector says hello again', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.submitHold.on = true
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests' }])
  await h.answerEvents()
  h.open('/poll')[0].answer(409)
  await h.settle()
  const hello = h.open('/event')[0]
  expect(hello.body.op).toBe('hello')
  h.releaseSubmits()
  await h.settle()
  hello.answer(200)
  await h.settle()
  await h.answerEvents()
  const sent = h.events().filter((b: any) => b.op === 'submitted')
  expect(sent.map((b: any) => [b.request, b.connection])).toEqual([['r1', hello.body.connection]])
  expect(typeof sent[0].handedAt).toBe('number')
  expect(typeof sent[0].seenAt).toBe('number')
})

for (const said of ['/clear', '!rm -rf build', '  !ls']) {
  test(`a dictation submitted as ${JSON.stringify(said)} reaches the agent as words, never as a command or a shell line`, async ($, on) => {
    const h = harness(on)
    await h.connect($)
    await h.deliver([submitCommand(said)])
    await h.answerEvents()
    expect(h.submits).toEqual(['​' + said])
    expect(outcome(h)).toEqual(['ack', 'submitted'])
  })
}
