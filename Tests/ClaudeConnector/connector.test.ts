import { expect, mock, test } from 'claude-code/testing'

type Request = { path: string, body: any, auth: string, answer: (status: number, text?: string) => void, refuse: () => void, settled: boolean }

function harness(on: any) {
  const clock = mock.clock(on)
  const requests: Request[] = []
  const submits: string[] = []
  const statuses: string[] = []
  const store = new Map<string, unknown>()
  const live = { session: 's1' }
  const env: Record<string, string | undefined> = {}
  const downstream: Record<string, any> = {}
  const reads: Array<() => void> = []
  const box = { text: '', held: false }
  const files: Record<string, string | undefined> = {
    '/plugin/keyscribe.json': JSON.stringify({ protocol: 2, socketPath: '/tmp/ks.sock', tokenPath: '/tmp/ks-token', readyPath: '/tmp/ks-ready.json', installation: 'I1' }),
    '/tmp/ks-token': 'secret\n',
    '/tmp/ks-ready.json': JSON.stringify({ launch: 'L1', protocol: 2 }),
  }
  const fileReads: string[] = []
  const releases: Array<() => void> = []
  const heldReads = new Set<string>()
  const holdReads = (path: string) => { heldReads.add(path) }

  on('fs.read', ($: any, e: any) => {
    const path = e.path.endsWith('keyscribe.json') ? '/plugin/keyscribe.json' : e.path
    fileReads.push(path)
    const text = files[path]
    const answer = text === undefined ? { deny: 'ENOENT' } : { value: text }
    if (!heldReads.delete(path)) return answer
    return new Promise((resolve) => { releases.push(() => resolve(answer)) })
  })
  on('session.id', () => ({ value: live.session }))
  on('env.get', ($: any, e: any) => ({ value: env[e.name] }))
  on('store.get', ($: any, e: any) => ({ value: store.get(e.key) }))
  on('store.set', ($: any, e: any) => {
    store.set(e.key, e.value)
    return { value: undefined }
  })
  on('ui.status', ($: any, e: any) => {
    statuses.push(e && typeof e === 'object' && 'text' in e ? e.text : e)
    return { value: undefined }
  })
  const logs: string[] = []
  on('ui.log', ($: any, e: any) => {
    if (!e.to || e.to === 'transcript') logs.push(e.text)
    return { value: undefined }
  })
  on('http.fetch', ($: any, e: any) => new Promise((resolve) => {
    const request: Request = {
      path: new URL(e.url).pathname,
      body: JSON.parse(e.init.body),
      auth: e.init.headers.authorization,
      settled: false,
      answer: (status, text = '{}') => {
        request.settled = true
        resolve({ value: { status, ok: status >= 200 && status < 300, headers: {}, text } })
      },
      refuse: () => {
        request.settled = true
        resolve({ deny: 'connect ECONNREFUSED' })
      },
    }
    requests.push(request)
  }))
  on('session.start', () => ({ cwd: '/work' }))
  on('session.end', ($: any, e: any) => ({ sessionId: e.sessionId }))
  on('classic.SessionStart', () => ({}))
  const heldSubmits: Array<() => void> = []
  const submitHold = { on: false }
  on('prompt.submit', async ($: any, e: any) => {
    if (e.origin && e.origin.kind === 'plugin') {
      submits.push(e.text)
      if (submitHold.on) await new Promise<void>((resolve) => { heldSubmits.push(resolve) })
    }
    const answer = downstream['prompt.submit']
    return (typeof answer === 'function' ? answer(e) : answer) ?? { text: e.text }
  })
  on('turn.start', ($: any, e: any) => ({ turnId: e.turnId }))
  on('turn.complete', () => downstream['turn.complete'] ?? { text: '' })
  on('turn.abort', () => ({ value: undefined }))
  const fills: string[] = []
  const fillRefusal: { reason?: string } = {}
  on('prompt.fill', ($: any, e: any) => {
    fills.push(e.text)
    if (fillRefusal.reason) return { isFilled: false, refusal: fillRefusal.reason }
    box.text = e.text
    return { isFilled: true }
  })
  on('prompt.read', () => {
    const answer = () => ({ value: { text: box.text, cursor: box.text.length } })
    if (!box.held) return answer()
    return new Promise((resolve) => { reads.push(() => resolve(answer())) })
  })

  const settle = async () => {
    for (let i = 0; i < 20; i++) {
      await clock.settle()
      await new Promise((resolve) => setTimeout(resolve, 0))
    }
  }
  const open = (path?: string) => requests.filter((r) => !r.settled && (!path || r.path === path))
  const events = () => requests.filter((r) => r.path === '/event').map((r) => r.body)
  const ops = () => events().map((b) => b.op)

  async function connect($: any) {
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
    await settle()
    const hello = open('/event')[0]
    expect(hello.body.op).toBe('hello')
    hello.answer(200)
    await settle()
    expect(open('/poll').length).toBe(1)
  }

  async function deliver(commands: any[]) {
    open('/poll')[0].answer(200, JSON.stringify(commands))
    await settle()
  }

  async function answerEvents() {
    for (let i = 0; i < 100 && open('/event').length; i++) {
      open('/event')[0].answer(200)
      await settle()
    }
  }

  const typed = ($: any, text = 'typed by me') => $.prompt.submit({ text, origin: { kind: 'composer' }, wait: false })

  const readyChecks = () => fileReads.filter((p) => p === '/tmp/ks-ready.json').length
  const ready = (launch?: string, protocol = 2) => { files['/tmp/ks-ready.json'] = launch === undefined ? undefined : JSON.stringify({ launch, protocol }) }

  const releaseSubmits = () => { for (const release of heldSubmits.splice(0)) release() }
  return { fills, fillRefusal, logs, env, store, files, fileReads, holdReads, releases, readyChecks, ready, clock, requests, submits, statuses, live, downstream, reads, box, settle, open, events, ops, connect, deliver, answerEvents, typed, submitHold, releaseSubmits }
}

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
  expect(h.events()[3]).toMatchObject({ op: 'turnComplete', session: 's1', reason: 'answer', answer: 'secret answer' })
  expect(Object.keys(h.events()[3]).sort()).toEqual(['answer', 'connection', 'instance', 'op', 'reason', 'session'])
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

  await $.session.end({ reason: 'clear', sessionId: 's1', resume: { id: 's1' } })
  await $.classic.SessionStart({ source: 'clear', session_id: 's2' })
  await h.settle()
  expect(h.events().slice(-1)[0]).toMatchObject({ op: 'hello', session: 's2' })
})

async function staleHelloFailure($: any, on: any, fail: 'reject' | 'refuse' | 'late') {
  const h = harness(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await h.settle()
  const old = h.open('/event')[0]
  expect(old.body.session).toBe('s1')

  await $.session.end({ reason: 'clear', sessionId: 's1', resume: { id: 's1' } })
  await $.classic.SessionStart({ source: 'clear', session_id: 's2' })
  h.live.session = 's2'
  await h.settle()
  if (fail === 'reject') old.answer(401)
  if (fail === 'refuse') old.refuse()
  if (fail === 'late') {
    await h.clock.advance(2000)
    await h.settle()
    old.answer(200)
  }
  await h.settle()

  const replacement = h.open('/event')[0]
  expect(replacement.body).toMatchObject({ op: 'hello', session: 's2' })
  replacement.answer(200)
  await h.settle()
  expect(h.open('/poll').map((r) => r.body.session)).toEqual(['s2'])

  h.open('/poll')[0].answer(409)
  await h.settle()
  expect(h.open('/event').map((r) => r.body)).toMatchObject([{ op: 'hello', session: 's2' }])
}

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
  await $.session.end({ reason: 'clear', sessionId: 's1', resume: { id: 's1' } })
  await $.classic.SessionStart({ source: 'clear', session_id: 's2' })
  h.live.session = 's2'
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
  await $.session.end({ reason: 'clear', sessionId: 's1', resume: { id: 's1' } })
  await $.classic.SessionStart({ source: 'clear', session_id: 's2' })
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
  await $.session.end({ reason: 'clear', sessionId: 's1', resume: { id: 's1' } })
  await $.classic.SessionStart({ source: 'clear', session_id: 's2' })
  h.live.session = 's2'
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'old dictation', expectedPrompts: 0 }])
  await h.answerEvents()

  expect(h.submits).toEqual([])
  expect(h.events().some((b) => b.request === 'r1' && b.op === 'submitted')).toBe(false)
})

test('a typed prompt overtaking queued dictation holds it while the sender is blocked', async ($, on) => {
  const h = harness(on)
  await h.connect($)

  await h.typed($)
  await h.settle()
  expect(h.open('/event').length).toBe(1)
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests', expectedPrompts: 0 }])
  expect(h.submits).toEqual([])

  await h.answerEvents()
  expect(h.events().filter((b) => b.request === 'r1')).toMatchObject([
    { op: 'ack', request: 'r1' },
    { op: 'refused', request: 'r1', reason: 'typedSince' },
  ])
})

const stopped = 'Cannot submit: the session was stopped by the user.'
const submitCommand = (text = 'run the tests') => ({ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text, expectedPrompts: 0 })
const outcome = (h: any) => h.events().filter((b: any) => b.request === 'r1').map((b: any) => b.reason ?? b.op)

test('a submission Claude Code turns away because a stop stands is put in the empty prompt box for the user to send', async ($, on) => {
  const h = harness(on)
  h.downstream['prompt.submit'] = { drop: stopped }
  await h.connect($)
  await h.deliver([submitCommand()])
  await h.answerEvents()
  expect(h.fills).toEqual(['run the tests'])
  expect(h.box.text).toBe('run the tests')
  expect(outcome(h)).toEqual(['ack', 'filled'])
})

test('a stopped submission keeps a slash command from running when the box is sent', async ($, on) => {
  const h = harness(on)
  h.downstream['prompt.submit'] = { drop: stopped }
  await h.connect($)
  await h.deliver([submitCommand('/resume')])
  await h.answerEvents()
  expect(h.fills).toEqual(['\u200b/resume'])
})

test('a stopped submission never fills over what the user started typing meanwhile', async ($, on) => {
  const h = harness(on)
  h.downstream['prompt.submit'] = () => {
    h.box.text = 'half a thought'
    return { drop: stopped }
  }
  await h.connect($)
  await h.deliver([submitCommand()])
  await h.answerEvents()
  expect(h.fills).toEqual([])
  expect(h.box.text).toBe('half a thought')
  expect(outcome(h)).toEqual(['ack', 'stopped'])
})

test('a stopped submission the prompt box will not take is reported as stopped', async ($, on) => {
  const h = harness(on)
  h.downstream['prompt.submit'] = { drop: stopped }
  h.fillRefusal.reason = 'dialog'
  await h.connect($)
  await h.deliver([submitCommand()])
  await h.answerEvents()
  expect(outcome(h)).toEqual(['ack', 'stopped'])
})

test('a submission turned away for any other reason never touches the prompt box', async ($, on) => {
  const h = harness(on)
  h.downstream['prompt.submit'] = { drop: 'another plugin dropped it' }
  await h.connect($)
  await h.deliver([submitCommand()])
  await h.answerEvents()
  expect(h.fills).toEqual([])
  expect(outcome(h)).toEqual(['ack', 'another plugin dropped it'])
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

test('a turn starting while the draft is being read holds the dictation until it finishes', async ($, on) => {
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

test('a submission whose deadline passes while the draft is being read is refused as expired and never submits', async ($, on) => {
  const h = harness(on)
  await $.classic.SessionStart({ source: 'startup', session_id: 's1' })
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
  await $.classic.SessionStart({ source: 'startup', session_id: 's1' })
  await h.connect($)
  h.box.held = true
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests', expectedPrompts: 0 }])
  expect(h.reads.length).toBe(1)
  h.live.session = 's2'
  await $.classic.SessionStart({ source: 'clear', session_id: 's2' })
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

async function staleReply($: any, on: any, released: 'beforeHello' | 'afterHello') {
  const h = harness(on)
  await h.connect($)
  const first = h.events()[0].connection
  h.box.held = true
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'use approach B' }])
  await h.answerEvents()
  expect(h.reads.length).toBe(1)

  h.open('/poll')[0].answer(409)
  await h.settle()
  const replacement = h.open('/event')[0]
  expect(replacement.body.op).toBe('hello')
  if (released === 'beforeHello') {
    h.reads[0]()
    await h.settle()
  }
  replacement.answer(200)
  await h.settle()
  if (released === 'afterHello') {
    h.reads[0]()
    await h.settle()
  }
  await h.answerEvents()

  expect(h.events().filter((b) => b.request === 'r1').map((b) => [b.op, b.connection])).toEqual([['ack', first]])
  expect(h.ops().filter((op) => op === 'hello').length).toBe(2)
  expect(h.open('/poll').map((r) => r.body.connection)).toEqual([replacement.body.connection])
  expect(h.submits).toEqual([])
}

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
  const quick = async () => {
    await h.clock.settle()
    await new Promise((resolve) => setTimeout(resolve, 0))
  }
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

test('a hello names the installation the connector was loaded from', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  expect(h.events()[0].installation).toBe('I1')
})

test('a retire ends the connector for good without answering, even for a new session', async ($, on) => {
  const h = harness(on)
  await $.classic.SessionStart({ source: 'startup', session_id: 's1' })
  await h.connect($)
  await h.deliver([{ op: 'retire', id: 'x1' }])
  await h.answerEvents()
  const seen = h.requests.length
  const checks = h.readyChecks()
  expect(h.events().some((b) => b.request === 'x1')).toBe(false)

  await h.clock.advance(120000)
  await h.settle()
  h.live.session = 's2'
  await $.classic.SessionStart({ source: 'clear', session_id: 's2' })
  await h.settle()
  await h.clock.advance(120000)
  await h.settle()
  expect(h.requests.length).toBe(seen)
  expect(h.readyChecks()).toBe(checks)
})

test('a connector whose installation was replaced never reconnects, even for a new session', async ($, on) => {
  const h = harness(on)
  await $.classic.SessionStart({ source: 'startup', session_id: 's1' })
  await h.connect($)
  h.files['/plugin/keyscribe.json'] = JSON.stringify({ protocol: 2, socketPath: '/tmp/ks.sock', tokenPath: '/tmp/ks-token', readyPath: '/tmp/ks-ready.json', installation: 'I2' })
  h.open('/poll')[0].answer(409)
  await h.settle()
  h.open('/event')[0].answer(403)
  await h.settle()
  const seen = h.requests.length

  h.live.session = 's2'
  await $.classic.SessionStart({ source: 'clear', session_id: 's2' })
  await h.settle()
  await h.clock.advance(60000)
  await h.settle()
  expect(h.requests.length).toBe(seen)
})

test('a connector whose unchanged installation is refused never reconnects, even for a new session', async ($, on) => {
  const h = harness(on)
  await $.classic.SessionStart({ source: 'startup', session_id: 's1' })
  await h.connect($)
  h.open('/poll')[0].answer(409)
  await h.settle()
  h.open('/event')[0].answer(403)
  await h.settle()
  const seen = h.requests.length

  h.live.session = 's2'
  await $.classic.SessionStart({ source: 'clear', session_id: 's2' })
  await h.settle()
  await h.clock.advance(60000)
  await h.settle()
  expect(h.requests.length).toBe(seen)
})

test('an empty status from the app clears the line instead of leaving it blank', async ($, on) => {
  const h = harness(on)
  await $.classic.SessionStart({ source: 'startup', session_id: 's1' })
  await h.connect($)
  await h.deliver([{ op: 'status', id: 'r1', expectedSession: 's1', text: 'Dictating' }, { op: 'status', id: 'r2', expectedSession: 's1', text: '' }])
  await h.answerEvents()
  expect(h.statuses).toEqual(['Dictating', undefined])
})

test('a session the module saw start says hello as fresh and idle', async ($, on) => {
  const h = harness(on)
  await $.classic.SessionStart({ source: 'startup', session_id: 's1' })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await h.settle()
  expect(h.events()[0]).toMatchObject({ op: 'hello', session: 's1', gap: false, idle: true, features: ['focus', 'label', 'readiness', 'notify', 'fill'] })
})

test('hello reports the zellij pane its session runs in, which only its own process can read', async ($, on) => {
  const h = harness(on)
  h.env.ZELLIJ_PANE_ID = '3'
  h.env.ZELLIJ_SESSION_NAME = 'quiet-otter'
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await h.settle()
  expect(h.events()[0]).toMatchObject({ op: 'hello', environment: { ZELLIJ_PANE_ID: '3' } })
  expect(Object.keys(h.events()[0].environment)).toEqual(['ZELLIJ_PANE_ID'])
})

test('hello outside zellij reports no terminal environment', async ($, on) => {
  const h = harness(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await h.settle()
  expect(h.events()[0].op).toBe('hello')
  expect(h.events()[0].environment).toBeUndefined()
})

test('a reloaded module does not know its turn and says hello as resuming after a gap', async ($, on) => {
  const h = harness(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await h.settle()
  expect(h.events()[0]).toMatchObject({ op: 'hello', session: 's1', gap: true, idle: false })
})

test('a resumed session says hello as resuming after a gap', async ($, on) => {
  const h = harness(on)
  await $.classic.SessionStart({ source: 'startup', session_id: 's1' })
  await h.connect($)
  await $.session.end({ reason: 'resume', sessionId: 's1', resume: { id: 's1' } })
  await $.classic.SessionStart({ source: 'resume', session_id: 's0' })
  await h.settle()
  expect(h.events().slice(-1)[0]).toMatchObject({ op: 'hello', session: 's0', gap: true })
})

test('a turn running when dictation arrives is reported, not interrupted', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  await h.answerEvents()
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests', expectedPrompts: 0 }])
  await h.answerEvents()
  expect(h.submits).toEqual([])
  expect(h.events().filter((b) => b.request === 'r1')).toMatchObject([
    { op: 'ack', request: 'r1' },
    { op: 'refused', request: 'r1', reason: 'working' },
  ])
})

test('a connection lost during a turn reconnects busy, refuses dictation as working, and accepts it again once the turn ends', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: 'typed by me', turnId: 't1' })
  await h.answerEvents()
  const first = h.events()[0].connection

  h.open('/poll')[0].answer(409)
  await h.settle()
  const hello = h.open('/event')[0]
  expect(hello.body).toMatchObject({ op: 'hello', idle: false, gap: true })
  expect(hello.body.connection).not.toBe(first)
  hello.answer(200)
  await h.settle()

  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests', expectedPrompts: 0 }])
  await h.answerEvents()
  await $.turn.complete({ turnId: 't1', answer: '', durationMs: 5, isAborted: false, usage: null, reason: 'answer' })
  await h.answerEvents()

  expect(h.submits).toEqual([])
  const after = h.events().slice(h.events().indexOf(hello.body) + 1)
  expect(after.map((b) => [b.op === 'refused' ? b.reason : b.op, b.connection])).toEqual([
    ['ack', hello.body.connection],
    ['working', hello.body.connection],
    ['turnComplete', hello.body.connection],
  ])
  expect(h.open('/poll').map((r) => r.body.connection)).toEqual([hello.body.connection])

  await h.deliver([{ op: 'submit', id: 'r2', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests', expectedPrompts: 0 }])
  await h.answerEvents()
  expect(h.submits).toEqual(['run the tests'])
  expect(h.events().filter((b) => b.request === 'r2').map((b) => [b.op, b.connection])).toEqual([
    ['ack', hello.body.connection],
    ['submitted', hello.body.connection],
  ])
})

test('an older completion never clears a newer turn', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: 'one', turnId: 't1' })
  await $.turn.start({ text: 'two', turnId: 't2' })
  await $.turn.complete({ turnId: 't1', answer: '', durationMs: 5, isAborted: false, usage: null, reason: 'answer' })
  await h.answerEvents()
  expect(h.ops()).toEqual(['hello', 'turnStarted', 'turnStarted'])

  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'three' }])
  await h.answerEvents()
  expect(h.events().filter((b) => b.request === 'r1').map((b) => b.reason ?? b.op)).toEqual(['ack', 'working'])
})

test('a hello answered quietly keeps polling but sends nothing about the conversation', async ($, on) => {
  const h = harness(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await h.settle()
  h.open('/event')[0].answer(200, JSON.stringify({ ok: true, quiet: true }))
  await h.settle()
  expect(h.open('/poll').length).toBe(1)
  await h.typed($)
  await $.turn.start({ text: 'typed by me', turnId: 't1' })
  await $.turn.complete({ turnId: 't1', answer: 'secret answer', durationMs: 5, isAborted: false, usage: null, reason: 'answer' })
  await h.settle()
  expect(h.ops()).toEqual(['hello'])
})

test('a quiet command stops observing and admit says hello again', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await h.deliver([{ op: 'quiet', id: 'q1', expectedSession: 's1' }])
  await h.answerEvents()
  const before = h.events().length
  await h.typed($)
  await h.settle()
  expect(h.events().length).toBe(before)
  await h.deliver([{ op: 'admit', id: 'a1', expectedSession: 's1' }])
  await h.clock.advance(1000)
  await h.settle()
  expect(h.events().filter((b) => b.op === 'hello').length).toBe(2)
  await h.answerEvents()
  await h.typed($, 'again')
  await h.answerEvents()
  expect(h.events().some((b) => b.op === 'typed')).toBe(true)
})

const readAloudTool = 'mcp__keyscribe-connector-test__tell_me_when_done'
const readAloudCommand = 'keyscribe-connector-test'

async function askedToReadAloud(h: any, call: Promise<any>, answer: string | null) {
  await h.settle()
  const notify = h.open('/event').find((r: any) => r.body.op === 'notify')
  expect(notify).toBeTruthy()
  if (answer !== null) notify.answer(200, answer)
  await h.settle()
  return { body: notify.body, result: await call }
}

test('hello says the connector can read a reply aloud and names the turn it is running', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  expect(h.events()[0].features).toContain('notify')
  expect(h.events()[0].turn).toBeUndefined()
  await $.turn.start({ text: 'work', turnId: 't1' })
  await h.answerEvents()
  h.open('/poll')[0].answer(409)
  await h.settle()
  const again = h.events().slice(-1)[0]
  expect(again.op).toBe('hello')
  expect(again.turn).toBe('t1')
})

test('the read-aloud tool asks for the running turn and tells the model only what the app answered', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: 'work', turnId: 't1' })
  await h.answerEvents()
  const cases: Array<[string | null, RegExp]> = [
    ['{"ok":true,"spoken":true}', /will read your final reply aloud/],
    ['{"ok":true,"spoken":false}', /Spoken replies are off/],
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
  expect(String((await call).result)).toMatch(/didn’t confirm the request/)
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
  expect(h.logs.slice(-1)[0]).toMatch(/won’t read this reply/)
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
