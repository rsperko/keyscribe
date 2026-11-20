import { expect, test } from 'claude-code/testing'
import { type Request, digest, harness, staleHelloFailure, cleared } from './support'

test('agent hooks return while the bridge never answers, through one sender', async ($, on) => {
  const h = harness(on)
  await h.connect($)

  expect(await h.typed($)).toEqual({ text: 'typed by me' })
  expect(await $.turn.start({ text: 'typed by me', turnId: 't1' })).toEqual({ turnId: 't1' })
  h.downstream['turn.complete'] = { text: 'shown below' }
  expect(await $.turn.complete({ turnId: 't1', answer: 'secret answer', durationMs: 5, isAborted: false, usage: null, reason: 'answer' })).toEqual({ text: 'shown below' })
  expect(await h.typed($, 'again')).toEqual({ text: 'again' })
  await h.settle()

  expect(h.open('/event').length).toBe(1)
  expect(h.open('/event')[0].body.op).toBe('typed')
})

test('downstream answers pass through unchanged', async ($, on) => {
  const h = harness(on)
  h.downstream['prompt.submit'] = { drop: 'another plugin dropped it' }
  await h.connect($)
  expect(await h.typed($)).toEqual({ drop: 'another plugin dropped it' })
})

test('events keep their order and a completion carries the final answer', async ($, on) => {
  const h = harness(on)
  await h.connect($)

  await h.typed($)
  await $.turn.start({ text: 'typed by me', turnId: 't1' })
  await $.turn.complete({ turnId: 't1', answer: 'secret answer', durationMs: 5, isAborted: false, usage: null, reason: 'answer' })
  await h.answerEvents()

  expect(h.ops()).toEqual(['hello', 'typed', 'turnStarted', 'turnComplete'])
  expect(h.events()[1]).toMatchObject({ op: 'typed', session: 's1', prompts: 1 })
  expect(h.events()[3]).toMatchObject({
    op: 'turnComplete', session: 's1', reason: 'answer', answer: 'secret answer', prompt: digest('typed by me'),
  })
  expect(Object.keys(h.events()[3]).sort()).toEqual(['answer', 'connection', 'instance', 'op', 'prompt', 'reason', 'session'])
  expect(JSON.stringify(h.events()[3])).not.toContain('typed by me')
})

test('a turn start names its prompt only by the digest the app matches a sent message against', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: 'reply with the single word fig', turnId: 't1' })
  await $.turn.start({ text: '\u200b/clear  ', turnId: 't2' })
  await $.turn.start({ text: 'café', turnId: 't3' })
  await h.answerEvents()

  const started = h.events().filter((e: any) => e.op === 'turnStarted')
  expect(started.map((e: any) => e.prompt)).toEqual([
    'de3139ee91e5afc4', digest('/clear'), '48e8823acfa40d89',
  ])
  expect(JSON.stringify(h.events())).not.toContain('fig')
  expect(h.events()[0].features).toContain('promptDigest')
})

test('an answer full of characters JSON must escape still fits the event queue and arrives', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await h.typed($)
  await $.turn.start({ text: 'typed by me', turnId: 't1' })
  await $.turn.complete({ turnId: 't1', answer: '"'.repeat(20000), durationMs: 5, isAborted: false, usage: null, reason: 'answer' })
  await h.answerEvents()
  const done = h.events().filter((b: any) => b.op === 'turnComplete')
  expect(done.length).toBe(1)
  expect(JSON.stringify(done[0].answer).length).toBeLessThanOrEqual(8 * 1024)
  expect(h.events().filter((b: any) => b.op === 'hello').length).toBe(1)
})

test('a long answer crosses the bridge bounded to its opening and its ending', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await h.typed($)
  await $.turn.start({ text: 'typed by me', turnId: 't1' })
  const answer = 'a'.repeat(5000) + 'b'.repeat(5000) + 'c'.repeat(5000)
  await $.turn.complete({ turnId: 't1', answer, durationMs: 5, isAborted: false, usage: null, reason: 'answer' })
  await h.answerEvents()
  const done = h.events().find((b: any) => b.op === 'turnComplete')
  expect(done.answer.length).toBeLessThanOrEqual(8 * 1024)
  expect(done.answer.startsWith('a'.repeat(100))).toBe(true)
  expect(done.answer.endsWith('c'.repeat(100))).toBe(true)
  expect(done.answer.includes('[…]')).toBe(true)
})

test('what happens before hello is dropped, never replayed, and hello reports the prompt count', async ($, on) => {
  const h = harness(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await h.settle()
  await h.typed($)
  await $.turn.start({ text: 'typed by me', turnId: 't1' })
  await h.settle()

  expect(h.ops()).toEqual(['hello'])
  h.open('/event')[0].answer(200)
  await h.settle()
  expect(h.ops()).toEqual(['hello'])
  expect(h.open('/poll').length).toBe(1)

  h.open('/poll')[0].answer(409)
  await h.settle()
  expect(h.ops()).toEqual(['hello', 'hello'])
  expect(h.events()[1].prompts).toBe(1)
})

test('a refused launch is never tried again until the bridge relaunches', async ($, on) => {
  const h = harness(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await h.settle()
  h.open('/event')[0].refuse()
  await h.settle()

  expect(h.requests.filter((r) => r.path === '/poll').length).toBe(0)
  await h.clock.advance(120000)
  await h.settle()
  expect(h.ops()).toEqual(['hello'])

  h.ready('L2')
  await h.clock.advance(10000)
  await h.settle()
  expect(h.ops()).toEqual(['hello', 'hello'])
})

test('without readiness nothing connects, and only a local check runs about every ten seconds', async ($, on) => {
  const h = harness(on)
  h.ready(undefined)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await h.settle()
  expect(h.requests.length).toBe(0)
  expect(h.readyChecks()).toBe(1)

  await h.clock.advance(9999)
  await h.settle()
  expect(h.readyChecks()).toBe(1)
  await h.clock.advance(1)
  await h.settle()
  expect(h.readyChecks()).toBe(2)
  await h.typed($)
  await $.turn.start({ text: 'typed by me', turnId: 't1' })
  await h.settle()
  expect(h.requests.length).toBe(0)

  h.ready('L1')
  await h.clock.advance(10000)
  await h.settle()
  expect(h.ops()).toEqual(['hello'])
})

test('a normal quit while connected causes no connection attempts', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.ready(undefined)
  h.open('/poll')[0].refuse()
  await h.settle()
  await h.clock.advance(120000)
  await h.settle()
  expect(h.requests.length).toBe(2)
})

test('a bridge that keeps hanging is retried with growing waits, not a storm', { timeoutMs: 60000 }, async ($, on) => {
  const h = harness(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await h.settle()
  const sentAt: number[] = []
  const seen = new Map<Request, number>()
  for (let second = 0; second < 900; second++) {
    for (const r of h.open('/event')) {
      if (!seen.has(r)) {
        seen.set(r, second)
        sentAt.push(second)
      } else if (second - seen.get(r)! >= 3) {
        r.answer(200)
      }
    }
    await h.clock.advance(1000)
    for (let i = 0; i < 4; i++) {
      await h.clock.settle()
      await new Promise((resolve) => setTimeout(resolve, 0))
    }
  }

  expect(h.requests.filter((r) => r.path === '/poll').length).toBe(0)
  const gaps = sentAt.slice(1).map((at, i) => at - sentAt[i])
  ;[30, 60, 120, 300].forEach((base, i) => {
    expect(gaps[i]).toBeGreaterThanOrEqual(2 + base)
    expect(gaps[i]).toBeLessThanOrEqual(4 + base * 1.25)
  })
})

test('a relaunched bridge ends the wait', async ($, on) => {
  const h = harness(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await h.settle()
  await h.clock.advance(2000)
  await h.settle()
  h.open('/event')[0].answer(200)
  await h.settle()
  h.ready('L2')
  await h.clock.advance(10000)
  await h.settle()
  expect(h.ops()).toEqual(['hello', 'hello'])
})

test('a rejected hello goes quiet until a new session', async ($, on) => {
  const h = harness(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await h.settle()
  h.open('/event')[0].answer(401)
  await h.settle()
  const checks = h.readyChecks()
  await h.typed($)
  await h.clock.advance(600000)
  await h.settle()
  expect(h.requests.filter((r) => r.path === '/poll').length).toBe(0)
  expect(h.ops()).toEqual(['hello'])
  expect(h.readyChecks()).toBe(checks)

  await cleared($, h, 's2')
  await h.settle()
  expect(h.events().slice(-1)[0]).toMatchObject({ op: 'hello', session: 's2' })
})

test('a rejection meant for a replaced session never silences the new one', ($, on) => staleHelloFailure($, on, 'reject'))

test('a refusal meant for a replaced session never blocks the new one', ($, on) => staleHelloFailure($, on, 'refuse'))

test('a timeout meant for a replaced session never delays the new one', ($, on) => staleHelloFailure($, on, 'late'))

test('a token read for a replaced session never replaces the new session token', async ($, on) => {
  const h = harness(on)
  h.holdReads('/tmp/ks-token')
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await h.settle()
  expect(h.releases.length).toBe(1)

  h.files['/tmp/ks-token'] = 'fresh\n'
  await cleared($, h, 's2')
  await h.settle()
  h.open('/event')[0].answer(200)
  await h.settle()

  h.releases[0]()
  await h.settle()
  h.open('/poll')[0].answer(200, '[]')
  await h.settle()
  expect(h.requests.map((r) => r.auth)).toEqual(['Bearer fresh', 'Bearer fresh', 'Bearer fresh'])
})

test('a bridge on another protocol is left alone', async ($, on) => {
  const h = harness(on)
  h.ready('L1', 1)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await h.settle()
  await h.clock.advance(600000)
  await h.settle()
  expect(h.requests.length).toBe(0)
  expect(h.readyChecks()).toBe(1)
})

test('a connector without its settings stays dormant', async ($, on) => {
  const h = harness(on)
  h.files['/plugin/keyscribe.json'] = undefined
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await h.settle()
  const reads = h.fileReads.length
  await h.clock.advance(600000)
  await h.settle()
  expect(h.fileReads.length).toBe(reads)
  expect(h.requests.length).toBe(0)
})

test('losing the connection clears only the status this connector set, once', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await h.clock.advance(28000)
  await h.settle()
  expect(h.statuses).toEqual([])

  h.open('/event')[0].answer(200)
  await h.settle()
  h.open('/poll')[0].answer(200, '[]')
  await h.settle()
  await h.deliver([{ op: 'status', id: 'r1', expectedSession: 's1', text: 'Dictating' }])
  await h.answerEvents()
  expect(h.statuses).toEqual(['Dictating'])
  await h.clock.advance(28000)
  await h.settle()
  await h.clock.advance(2000)
  await h.settle()
  expect(h.statuses).toEqual(['Dictating', undefined])
})

test('a replaced session never emits the old id, even while the host still reports it', async ($, on) => {
  const h = harness(on)
  await h.connect($)

  await h.typed($, 'first')
  await h.typed($, 'second')
  await cleared($, h, 's2')
  await h.answerEvents()
  await h.typed($, 'third')
  await h.answerEvents()

  const sent = h.events()
  const firstAfterEnd = sent.findIndex((b) => b.op === 'hello' && b.session === 's2')
  expect(firstAfterEnd).toBe(2)
  expect(sent.slice(firstAfterEnd).some((b) => b.session === 's1')).toBe(false)
  expect(sent.map((b) => b.op)).toEqual(['hello', 'typed', 'hello', 'typed'])
  expect(sent[3]).toMatchObject({ op: 'typed', session: 's2', prompts: 3 })
})

test('a command for a replaced session is refused without acting', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await cleared($, h, 's2')
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'old dictation', expectedPrompts: 0 }])
  await h.answerEvents()

  expect(h.submits).toEqual([])
  expect(h.events().some((b) => b.request === 'r1' && b.op === 'submitted')).toBe(false)
})
