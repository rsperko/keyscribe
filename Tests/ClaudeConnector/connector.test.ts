import { expect, mock, test } from 'claude-code/testing'

type Request = { path: string, body: any, auth: string, answer: (status: number, text?: string) => void, refuse: () => void, settled: boolean }

const surfaces = {
  environmentKeys: ['CMUX_SURFACE_ID', 'MUX_PANE', 'ZELLIJ_PANE_ID'],
  focusDefinitions: [
    { id: 'cmux', requiresEnv: ['CMUX_SURFACE_ID'], argv: ['/usr/bin/env', 'cmux', 'focus-panel', '--panel', '{CMUX_SURFACE_ID}'] },
    { id: 'mux', requiresEnv: ['MUX_PANE'], argv: ['/opt/mux/bin/mux', 'focus', '--pane={MUX_PANE}', '{MUX_PANE}'] },
    { id: 'stray', requiresEnv: ['MUX_PANE'], argv: ['/opt/mux/bin/mux', '{TMUX}'] },
    { id: 'relative', requiresEnv: ['MUX_PANE'], argv: ['mux', '{MUX_PANE}'] },
  ],
}

function harness(on: any) {
  const clockHold = { on: false, held: [] as Array<() => void> }
  const clock = mock.clock((name: string, handler: any) => on(name, name !== 'clock.now' ? handler : async ($: any, e: any) => {
    const answer = await handler($, e)
    if (clockHold.on) await new Promise<void>((resolve) => { clockHold.held.push(resolve) })
    return answer
  }))
  const requests: Request[] = []
  const submits: string[] = []
  const statuses: string[] = []
  const store = new Map<string, unknown>()
  const live = { session: 's1' }
  const env: Record<string, string | undefined> = {}
  const downstream: Record<string, any> = {}
  const reads: Array<() => void> = []
  const box = { text: '', held: false, readThrows: false }
  const files: Record<string, string | undefined> = {
    '/plugin/keyscribe.json': JSON.stringify({ protocol: 2, socketPath: '/tmp/ks.sock', tokenPath: '/tmp/ks-token', readyPath: '/tmp/ks-ready.json', installation: 'I1', ...surfaces }),
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
  const runs: any[] = []
  const run = { exitCode: 0 }
  on('process.run', ($: any, e: any) => {
    runs.push(e)
    return { value: { exitCode: run.exitCode, stdout: '', stderr: '' } }
  })
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
  on('tool.check', { tool: 'Bash' }, () => ({ decision: 'ask' }))
  on('tool.check', { tool: 'AskUserQuestion' }, () => ({ decision: 'allow' }))
  on('tool.check', { tool: 'ExitPlanMode' }, () => ({ decision: 'allow' }))
  on('classic.Elicitation', () => ({}))
  on('prompt.attachment', ($: any, e: any) => ({ text: e.text }))
  const fills: string[] = []
  const fillRefusal: { reason?: string; typedFirst?: string; throws?: boolean } = {}
  on('prompt.fill', ($: any, e: any) => {
    fills.push(e.text)
    if (fillRefusal.throws && e.text) throw new Error('fill failed')
    if (fillRefusal.reason) return { isFilled: false, refusal: fillRefusal.reason, text: box.text }
    if (fillRefusal.typedFirst) box.text += fillRefusal.typedFirst
    box.text = e.mode === 'append' ? box.text + e.text : e.text
    return { isFilled: true, text: box.text }
  })
  on('prompt.read', () => {
    if (box.readThrows) throw new Error('read failed')
    const answer = () => ({ value: { text: box.text, cursor: box.text.length } })
    if (!box.held) return answer()
    return new Promise((resolve) => { reads.push(() => resolve(answer())) })
  })

  const appended: string[] = []
  const appendHold = { throws: false, gated: false, gates: [] as Array<() => void> }
  on('session.append', async ($: any, e: any, next: any) => {
    if (appendHold.throws) return { deny: 'append failed' }
    if (appendHold.gated) await new Promise<void>((resolve) => { appendHold.gates.push(resolve) })
    appended.push(e.message.content.map((c: any) => c.text).join(''))
    return next(e)
  })
  on('ui.invalidate', () => ({ value: undefined }))
  on('tool.call', () => downstream['tool.call'] ?? { result: 'tool output' })
  on('turn.step', async function* ($: any, e: any) { return { turnId: e.turnId, index: e.index, answer: '', toolUses: [] } } as any)

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
  return { appended, appendHold, runs, run, clockHold, fills, fillRefusal, logs, env, store, files, fileReads, holdReads, releases, readyChecks, ready, clock, requests, submits, statuses, live, downstream, reads, box, settle, open, events, ops, connect, deliver, answerEvents, typed, submitHold, releaseSubmits }
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

function digest(text: string) {
  let hash = 0xcbf29ce484222325n
  for (const byte of new TextEncoder().encode(text)) hash = ((hash ^ BigInt(byte)) * 0x100000001b3n) & 0xffffffffffffffffn
  return hash.toString(16).padStart(16, '0')
}

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

test('a stopped submission that starts with a slash is never put in the box, where Return would run it as a command', async ($, on) => {
  const h = harness(on)
  h.downstream['prompt.submit'] = { drop: stopped }
  await h.connect($)
  await h.deliver([submitCommand('/resume')])
  await h.answerEvents()
  expect(h.fills).toEqual([])
  expect(outcome(h)).toEqual(['ack', 'stopped'])
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

const boxCommand = (text = 'run the tests') => ({ ...submitCommand(text), box: true })

test('a dictation for the conversation in front, sent while a turn runs, is put in the empty prompt box for Return', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  await h.deliver([boxCommand()])
  await h.answerEvents()
  expect(h.submits).toEqual([])
  expect(h.fills).toEqual(['run the tests'])
  expect(outcome(h)).toEqual(['ack', 'filled'])
})

test('a dictation that starts with a slash never goes in the prompt box, where Return would run it as a command, and joins the turn as text', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  await h.deliver([boxCommand('/resume')])
  await h.answerEvents()
  expect(h.fills).toEqual([])
  expect(outcome(h)).toEqual(['ack', 'submitted'])
  await toolCall($, 'tu1')
  expect(h.appended).toEqual([steered('/resume')])
})

test('a fill that fails sends no answer, so the take reads uncertain rather than refused and is never entered twice', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  h.fillRefusal.throws = true
  await h.deliver([boxCommand()])
  await h.answerEvents()
  expect(h.events().filter((b: any) => ['refused', 'submitted'].includes(b.op))).toEqual([])
  await h.deliver([{ op: 'check', id: 'c1', expectedSession: 's1', request: 'r1', expiresAt: Number.MAX_SAFE_INTEGER }])
  await h.answerEvents()
  expect(h.events().find((b: any) => b.op === 'checked' && b.check === 'c1')).toMatchObject({ state: 'handed' })
})

const checkCommand = (id: string) => ({ op: 'check', id, expectedSession: 's1', request: 'r1', expiresAt: Number.MAX_SAFE_INTEGER })
const promptBox = (h: any, check: string) => h.events().find((b: any) => b.op === 'checked' && b.check === check)?.promptBox

test('a filled prompt box is ready for Return only while it holds exactly the dictation and takes the keys', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  await h.deliver([boxCommand()])
  await h.answerEvents()
  await h.deliver([checkCommand('c1')])
  await h.answerEvents()
  expect(promptBox(h, 'c1')).toBe('ready')
  h.box.text = 'run the tests and'
  await h.deliver([checkCommand('c2')])
  await h.answerEvents()
  expect(promptBox(h, 'c2')).toBe('changed')
  h.box.text = 'run the tests'
  h.fillRefusal.reason = 'dialog'
  await h.deliver([checkCommand('c3')])
  await h.answerEvents()
  expect(promptBox(h, 'c3')).not.toBe('ready')
  expect(h.box.text).toBe('run the tests')
})

const ask = ($: any) => $.tool.check({ tool: 'Bash', input: { command: 'touch x' }, tool_use_id: 'u1' } as any)

const readyBox = async ($: any, h: any) => {
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  await h.deliver([boxCommand()])
  await h.answerEvents()
  await h.deliver([checkCommand('c1')])
  await h.answerEvents()
  expect(promptBox(h, 'c1')).toBe('ready')
}

test('an approval the agent asks for right after the box is ready waits until the Return has landed', async ($, on) => {
  const h = harness(on)
  await readyBox($, h)
  let answered = false
  const verdict = ask($).then((v: any) => { answered = true; return v })
  await h.settle()
  expect(answered).toBe(false)
  await h.typed($, 'run the tests')
  await h.settle()
  expect((await verdict).decision).toBe('ask')
})

test('an approval held for a Return that never lands is let through after a second', async ($, on) => {
  const h = harness(on)
  await readyBox($, h)
  let answered = false
  const verdict = ask($).then((v: any) => { answered = true; return v })
  await h.settle()
  expect(answered).toBe(false)
  await h.clock.advance(1000)
  await h.settle()
  expect((await verdict).decision).toBe('ask')
})

test('an approval with no Return about to land is never held', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  expect((await ask($)).decision).toBe('ask')
})

test('a box is not ready for Return just after the agent asked for an approval that may not be drawn yet', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  await h.deliver([boxCommand()])
  await h.answerEvents()
  await ask($)
  await h.deliver([checkCommand('c1')])
  await h.answerEvents()
  expect(promptBox(h, 'c1')).not.toBe('ready')
  await h.clock.advance(500)
  await h.deliver([checkCommand('c2')])
  await h.answerEvents()
  expect(promptBox(h, 'c2')).toBe('ready')
})

for (const tool of ['AskUserQuestion', 'ExitPlanMode']) {
  test(`a ${tool} dialog core allows still waits until the Return has landed`, async ($, on) => {
    const h = harness(on)
    await readyBox($, h)
    let answered = false
    const verdict = $.tool.check({ tool, input: {}, tool_use_id: 'u2' } as any).then((v: any) => { answered = true; return v })
    await h.settle()
    expect(answered).toBe(false)
    await h.typed($, 'run the tests')
    await h.settle()
    expect(answered).toBe(true)
    await verdict
  })

  test(`a box is not ready for Return just after a ${tool} dialog core allows`, async ($, on) => {
    const h = harness(on)
    await h.connect($)
    await $.turn.start({ text: '', turnId: 't1' })
    await h.deliver([boxCommand()])
    await h.answerEvents()
    await $.tool.check({ tool, input: {}, tool_use_id: 'u2' } as any)
    await h.deliver([checkCommand('c1')])
    await h.answerEvents()
    expect(promptBox(h, 'c1')).not.toBe('ready')
  })
}

test('an MCP question keeps the box from reading ready while it may not be drawn yet', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  await h.deliver([boxCommand()])
  await h.answerEvents()
  await $.classic.Elicitation({ mcp_server_name: 'docs', message: 'Pick one' } as any)
  await h.deliver([checkCommand('c1')])
  await h.answerEvents()
  expect(promptBox(h, 'c1')).not.toBe('ready')
  await h.clock.advance(500)
  await h.deliver([checkCommand('c2')])
  await h.answerEvents()
  expect(promptBox(h, 'c2')).toBe('ready')
})

const absorbedText = (text: string) => `The user sent a new message while you were working:\n${text}\n\nThis is how Claude Code surfaces messages the user sends mid-turn.`

test('a prompt-box dictation the running turn takes in is reported as absorbed into that turn', async ($, on) => {
  const h = harness(on)
  await readyBox($, h)
  await h.typed($, 'run the tests')
  await $.prompt.attachment({ type: 'queued_command', text: absorbedText('run the tests'), origin: { kind: 'engine' } } as any)
  await h.answerEvents()
  expect(h.events().filter((b: any) => b.op === 'absorbed')).toMatchObject([{ op: 'absorbed', session: 's1', turn: 't1', prompt: expect.any(String) }])
})

test('another message the running turn takes in is never reported as the dictation', async ($, on) => {
  const h = harness(on)
  await readyBox($, h)
  await $.prompt.attachment({ type: 'queued_command', text: absorbedText('something else'), origin: { kind: 'engine' } } as any)
  await h.answerEvents()
  expect(h.events().filter((b: any) => b.op === 'absorbed')).toEqual([])
})

test('a dictation that starts with an exclamation mark never goes in the prompt box, where Return would run it in the shell, and joins the turn as text', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  await h.deliver([boxCommand('!echo hi')])
  await h.answerEvents()
  expect(h.fills).toEqual([])
  expect(outcome(h)).toEqual(['ack', 'submitted'])
  await toolCall($, 'tu1')
  expect(h.appended).toEqual([steered('!echo hi')])
})

test('a dictation for the prompt box whose clock read is pending when its session is cleared never fills the next session', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  h.box.held = true
  await h.deliver([boxCommand()])
  await h.answerEvents()
  h.clockHold.on = true
  h.reads[0]()
  await h.settle()
  expect(h.clockHold.held.length).toBeGreaterThan(0)
  h.clockHold.on = false
  await $.session.end({ reason: 'clear', sessionId: 's1', resume: { id: 's1' } })
  await $.classic.SessionStart({ source: 'clear', session_id: 's2' })
  h.live.session = 's2'
  await h.settle()
  for (const release of h.clockHold.held.splice(0)) release()
  await h.settle()
  await h.answerEvents()
  expect(h.fills).toEqual([])
})

test('a submission that was never put in the prompt box reports no prompt box state', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await h.deliver([submitCommand()])
  await h.answerEvents()
  await h.deliver([checkCommand('c1')])
  await h.answerEvents()
  expect(promptBox(h, 'c1')).toBeUndefined()
})

test('a dictation for the prompt box never fills over what the user is typing', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  h.box.text = 'half a thought'
  await h.deliver([boxCommand()])
  await h.answerEvents()
  expect(h.fills).toEqual([])
  expect(h.box.text).toBe('half a thought')
  expect(outcome(h)).toEqual(['ack', 'draft'])
})

const mergeCommand = (text = 'run the tests') => ({ ...submitCommand(text), merge: true })

test('a dictation for the conversation in front joins what the user started typing, and waits for Return', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.box.text = 'half a thought'
  await h.deliver([mergeCommand()])
  await h.answerEvents()
  expect(h.box.text).toBe('half a thought run the tests')
  expect(h.submits).toEqual([])
  expect(outcome(h)).toEqual(['ack', 'joined'])
  await h.deliver([checkCommand('c1')])
  await h.answerEvents()
  expect(promptBox(h, 'c1')).toBe('ready')
})

test('a draft that already ends in a space or a new line takes the dictation with no extra space', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.box.text = 'first line\n'
  await h.deliver([mergeCommand()])
  await h.answerEvents()
  expect(h.box.text).toBe('first line\nrun the tests')
  expect(outcome(h)).toEqual(['ack', 'joined'])
})

test('a dictation joined to a draft while a turn runs is reported absorbed under the dictation it carried', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  h.box.text = 'half a thought'
  await h.deliver([{ ...mergeCommand(), box: true }])
  await h.answerEvents()
  expect(outcome(h)).toEqual(['ack', 'joinedMidTurn'])
  await h.typed($, 'half a thought run the tests')
  await $.prompt.attachment({ type: 'queued_command', text: absorbedText('half a thought run the tests'), origin: { kind: 'engine' } } as any)
  await h.answerEvents()
  expect(h.events().filter((b: any) => b.op === 'absorbed')).toMatchObject([{ turn: 't1', prompt: digest('run the tests') }])
})

test('a dictation that would run as a command is never joined to a draft', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.box.text = 'half a thought'
  await h.deliver([mergeCommand('  /clear')])
  await h.answerEvents()
  expect(h.fills).toEqual([])
  expect(h.box.text).toBe('half a thought')
  expect(outcome(h)).toEqual(['ack', 'draft'])
})

test('a dictation joined while the user keeps typing is left beside their text, never sent', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.box.text = 'half'
  h.fillRefusal.typedFirst = ' more'
  await h.deliver([mergeCommand()])
  await h.answerEvents()
  expect(h.box.text).toBe('half more run the tests')
  expect(outcome(h)).toEqual(['ack', 'added'])
})

test('a draft the prompt box will not add to keeps the dictation out of it', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.box.text = 'half a thought'
  h.fillRefusal.reason = 'dialog'
  await h.deliver([mergeCommand()])
  await h.answerEvents()
  expect(h.box.text).toBe('half a thought')
  expect(h.submits).toEqual([])
  expect(outcome(h)).not.toContain('joined')
  await h.deliver([checkCommand('c1')])
  await h.answerEvents()
  expect(promptBox(h, 'c1')).toBeUndefined()
})

test('a dictation for the prompt box keeps what the user typed as it was filled, and is not sent', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  h.fillRefusal.typedFirst = 'half '
  await h.deliver([boxCommand()])
  await h.answerEvents()
  expect(h.box.text).toBe('half run the tests')
  expect(outcome(h)).toEqual(['ack', 'added'])
})

test('a dictation the prompt box will not take joins the turn instead', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  h.fillRefusal.reason = 'no_composer'
  await h.deliver([boxCommand()])
  await h.answerEvents()
  expect(outcome(h)).toEqual(['ack', 'submitted'])
  await toolCall($, 'tu1')
  expect(h.appended).toEqual([steered('run the tests')])
})

test('a dictation for the prompt box that expired is never filled', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  await h.deliver([{ ...boxCommand(), expiresAt: 0 }])
  await h.answerEvents()
  expect(h.fills).toEqual([])
  expect(outcome(h)).toEqual(['ack', 'expired'])
})

const steered = (text: string) => `The user sent a new message while you were working:\n${text}\n\nThis is how Claude Code surfaces messages the user sends mid-turn — within the running turn, often alongside the next tool result, rather than as a separate conversation turn. Address the message above as you continue this turn.`
const toolCall = ($: any, id: string, extra: any = {}) => $.tool.call({ tool: 'Read', input: { file_path: '/work/f' }, tool_use_id: id, ...extra } as any)
async function step($: any, turnId = 't1', extra: any = {}) {
  const stream = $.turn.step({ turnId, index: 1, model: 'm', messageCount: 3, ...extra } as any)
  for await (const _ of stream) { }
}
const ended = (reason = 'answer') => ({ turnId: 't1', answer: '', durationMs: 5, isAborted: reason === 'aborted', usage: null, reason })

async function held($: any, h: any, commands = [submitCommand()]) {
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  await h.deliver(commands)
  await h.answerEvents()
}

test('a dictation sent while a turn runs is taken and joins the turn after the next tool call, worded as typing is', async ($, on) => {
  const h = harness(on)
  await held($, h)
  expect(outcome(h)).toEqual(['ack', 'submitted'])
  expect(h.events().find((b: any) => b.op === 'submitted' && b.request === 'r1').turn).toBe('')
  expect(h.submits).toEqual([])
  expect(h.fills).toEqual([])
  expect(h.appended).toEqual([])

  expect(await toolCall($, 'tu1')).toMatchObject({ result: 'tool output' })
  await h.answerEvents()
  expect(h.appended).toEqual([steered('run the tests')])
  expect(h.events().filter((b: any) => b.op === 'absorbed')).toEqual([])
  await step($)
  await h.answerEvents()
  expect(h.events().filter((b: any) => b.op === 'absorbed')).toMatchObject([{ session: 's1', turn: 't1', prompt: digest('run the tests') }])
})

test('a dictation added to the conversation but not read before its turn ends stays there for the next turn and is never sent twice', async ($, on) => {
  const h = harness(on)
  await held($, h)
  await toolCall($, 'tu1')
  await $.turn.complete(ended('aborted'))
  await h.settle()
  await h.answerEvents()
  expect(h.submits).toEqual([])
  expect(h.appended).toEqual([steered('run the tests')])
  expect(h.events().filter((b: any) => b.op === 'absorbed')).toEqual([])
})

test('a second tool call from the same step adds nothing once the first carried the dictation', async ($, on) => {
  const h = harness(on)
  await held($, h)
  await Promise.all([toolCall($, 'tu1'), toolCall($, 'tu2')])
  expect(h.appended).toEqual([steered('run the tests')])
})

test('a dictation sent while a turn runs and the user has a draft in the prompt box is kept for review, not added', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  h.box.text = 'half typed'
  await h.deliver([submitCommand()])
  await h.answerEvents()
  expect(outcome(h)).toEqual(['ack', 'draft'])
  await toolCall($, 'tu1')
  expect(h.appended).toEqual([])
})

test('a dictation held while the user starts a draft is not submitted over it at the turn\'s end, and is reported kept', async ($, on) => {
  const h = harness(on)
  await held($, h)
  h.box.text = 'half typed'
  await $.turn.complete(ended())
  await h.settle()
  await h.answerEvents()
  expect(h.submits).toEqual([])
  expect(outcome(h)).toEqual(['ack', 'submitted', 'draft'])
})

test('a held dictation another plugin drops at the turn\'s end is reported, never silently lost', async ($, on) => {
  const h = harness(on)
  await held($, h)
  h.downstream['prompt.submit'] = { drop: 'another plugin dropped it' }
  await $.turn.complete(ended())
  await h.settle()
  await h.answerEvents()
  expect(outcome(h)).toEqual(['ack', 'submitted', 'another plugin dropped it'])
})

test('a subagent\'s model step never confirms a dictation the main loop has not read', async ($, on) => {
  const h = harness(on)
  await held($, h)
  await toolCall($, 'tu1')
  await step($, 't1', { agentId: 'a1' })
  await h.answerEvents()
  expect(h.events().filter((b: any) => b.op === 'absorbed')).toEqual([])
})

test('a tool call with nothing held passes through and adds nothing', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  h.downstream['tool.call'] = { result: 'exact', context: ['kept'] }
  expect(await toolCall($, 'tu1')).toMatchObject({ result: 'exact', context: ['kept'] })
  expect(h.appended).toEqual([])
})

test('dictations held for one turn join it in the order they were said, each as its own message', async ($, on) => {
  const h = harness(on)
  await held($, h, [submitCommand('first'), { ...submitCommand('second'), id: 'r2' }])
  await toolCall($, 'tu1')
  expect(h.appended).toEqual([steered('first'), steered('second')])
})

test('a subagent\'s tool call never carries a held dictation into the subagent', async ($, on) => {
  const h = harness(on)
  await held($, h)
  await toolCall($, 'tu1', { agentId: 'a1' })
  expect(h.appended).toEqual([])
  await toolCall($, 'tu2')
  expect(h.appended).toEqual([steered('run the tests')])
})

test('a dictation still held when the turn ends starts the next turn, as queued typing does', async ($, on) => {
  const h = harness(on)
  await held($, h)
  await $.turn.complete(ended())
  await h.settle()
  expect(h.submits).toEqual(['run the tests'])
  await toolCall($, 'tu1')
  expect(h.appended).toEqual([])
})

test('a dictation held when the user presses Esc is sent as the next prompt, as Claude Code sends queued typing', async ($, on) => {
  const h = harness(on)
  await held($, h)
  await $.turn.complete(ended('aborted'))
  await h.settle()
  expect(h.submits).toEqual(['run the tests'])
})

const lateOutcome = (h: any, id: string) => h.events().filter((b: any) => b.request === id && b.op === 'refused').map((b: any) => b.reason)

test('held dictations Claude Code refuses after Esc wait in the empty prompt box for the user to send, and say so', async ($, on) => {
  const h = harness(on)
  await held($, h, [submitCommand('first'), { ...submitCommand('second'), id: 'r2' }])
  h.downstream['prompt.submit'] = { drop: stopped }
  await $.turn.complete(ended('aborted'))
  await h.settle()
  await h.answerEvents()
  expect(h.box.text).toBe('first\nsecond')
  expect([lateOutcome(h, 'r1'), lateOutcome(h, 'r2')]).toEqual([['filled'], ['filled']])
})

test('a held dictation left in the prompt box after Esc reads ready for the app to press Return', async ($, on) => {
  const h = harness(on)
  await held($, h)
  h.downstream['prompt.submit'] = { drop: stopped }
  await $.turn.complete(ended('aborted'))
  await h.settle()
  await h.answerEvents()
  await h.deliver([checkCommand('c2')])
  await h.answerEvents()
  expect(promptBox(h, 'c2')).toBe('ready')
})

test('a left-in-the-box report still unsent when that box is sent is dropped, never reported after a reconnect', async ($, on) => {
  const h = harness(on)
  await held($, h, [submitCommand('first'), { ...submitCommand('second'), id: 'r2' }])
  h.downstream['prompt.submit'] = (e: any) => e.origin && e.origin.kind === 'plugin' ? { drop: stopped } : { text: e.text }
  await $.turn.complete(ended('aborted'))
  await h.settle()
  for (let i = 0; i < 20 && h.open('/event')[0] && h.open('/event')[0].body.request !== 'r2'; i++) {
    h.open('/event')[0].answer(200)
    await h.settle()
  }
  expect(h.open('/event')[0].body).toMatchObject({ op: 'refused', request: 'r2', reason: 'filled' })
  await h.typed($, 'first\nsecond')
  await h.settle()
  h.open('/event').find((r: any) => r.body.request === 'r2').refuse()
  await h.settle()
  const hello = h.open('/event').find((r: any) => r.body.op === 'hello')
  hello.answer(200)
  await h.settle()
  await h.answerEvents()
  const after = h.events().filter((b: any) => b.connection === hello.body.connection && b.op === 'refused')
  expect(after).toEqual([])
})

test('a held dictation refused after Esc never fills over what the user typed meanwhile, and is reported kept', async ($, on) => {
  const h = harness(on)
  await held($, h)
  h.downstream['prompt.submit'] = (e: any) => {
    h.box.text = 'my own words'
    return { drop: stopped }
  }
  await $.turn.complete(ended('aborted'))
  await h.settle()
  await h.answerEvents()
  expect(h.box.text).toBe('my own words')
  expect(h.fills).toEqual([])
  expect(lateOutcome(h, 'r1')).toEqual(['draft'])
})

test('after Esc a held dictation is added after what the user typed meanwhile, never over it, and says so', async ($, on) => {
  const h = harness(on)
  await held($, h)
  h.downstream['prompt.submit'] = { drop: stopped }
  h.fillRefusal.typedFirst = 'my words '
  await $.turn.complete(ended('aborted'))
  await h.settle()
  await h.answerEvents()
  expect(h.box.text).toBe('my words run the tests')
  expect(lateOutcome(h, 'r1')).toEqual(['added'])
})

test('a conversation disconnected while held dictations are being added gets none of the rest, and none comes back', async ($, on) => {
  const h = harness(on)
  await held($, h, [submitCommand('first'), { ...submitCommand('second'), id: 'r2' }])
  h.appendHold.gated = true
  const call = toolCall($, 'tu1')
  await h.settle()
  await h.deliver([{ op: 'quiet', id: 'q1', expectedSession: 's1' }])
  h.appendHold.gated = false
  for (const release of h.appendHold.gates.splice(0)) release()
  await call
  await h.settle()
  await toolCall($, 'tu2')
  await $.turn.complete(ended())
  await h.settle()
  expect(h.appended).toEqual([steered('first')])
  expect(h.submits).toEqual([])
})

async function dropConnection(h: any) {
  h.open('/poll')[0].answer(409)
  await h.settle()
  const hello = h.open('/event').find((r: any) => r.body.op === 'hello')
  hello.answer(200)
  await h.settle()
  await h.answerEvents()
}

test('a dictation held when the connection drops still joins the turn, as a steer the agent accepted does', async ($, on) => {
  const h = harness(on)
  await held($, h)
  await dropConnection(h)
  await toolCall($, 'tu1')
  await step($)
  await h.answerEvents()
  expect(h.appended).toEqual([steered('run the tests')])
  expect(lateOutcome(h, 'r1')).toEqual([])
  expect(h.events().filter((b: any) => b.op === 'absorbed').length).toBe(1)
})

test('a connection that drops while held dictations are being added still adds them all and reports them read', async ($, on) => {
  const h = harness(on)
  await held($, h, [submitCommand('first'), { ...submitCommand('second'), id: 'r2' }])
  h.appendHold.gated = true
  const call = toolCall($, 'tu1')
  await h.settle()
  h.appendHold.gated = false
  await dropConnection(h)
  for (const release of h.appendHold.gates.splice(0)) release()
  await call
  await step($)
  await h.settle()
  await h.answerEvents()
  expect(h.appended).toEqual([steered('first'), steered('second')])
  expect(h.events().filter((b: any) => b.op === 'absorbed').length).toBe(2)
})

test('a turn that ends while held dictations are being added sends the rest as the next prompt and never reports a late row as read', async ($, on) => {
  const h = harness(on)
  await held($, h, [submitCommand('first'), { ...submitCommand('second'), id: 'r2' }])
  h.appendHold.gated = true
  const call = toolCall($, 'tu1')
  await h.settle()
  await $.turn.complete(ended())
  h.appendHold.gated = false
  for (const release of h.appendHold.gates.splice(0)) release()
  await call
  await h.settle()
  await $.turn.start({ text: 'second', turnId: 't2' })
  await step($, 't2')
  await h.answerEvents()
  expect(h.appended).toEqual([steered('first')])
  expect(h.submits).toEqual(['second'])
  expect(h.events().filter((b: any) => b.op === 'absorbed')).toEqual([])
})

test('a dictation that arrives while a batch is being added and its turn ends goes after that batch\'s rest', async ($, on) => {
  const h = harness(on)
  await held($, h, [submitCommand('first'), { ...submitCommand('second'), id: 'r2' }])
  h.appendHold.gated = true
  const call = toolCall($, 'tu1')
  await h.settle()
  await h.deliver([{ ...submitCommand('third'), id: 'r3' }])
  await h.answerEvents()
  await $.turn.complete(ended())
  await h.settle()
  h.appendHold.gated = false
  for (const release of h.appendHold.gates.splice(0)) release()
  await call
  await h.settle()
  expect(h.appended).toEqual([steered('first')])
  expect(h.submits).toEqual(['second', 'third'])
})

test('a session cleared while held dictations wait for the prompt box after Esc reports none of them', async ($, on) => {
  const h = harness(on)
  await held($, h, [submitCommand('plain words'), { ...submitCommand('/resume'), id: 'r2' }])
  h.submitHold.on = true
  h.downstream['prompt.submit'] = { drop: stopped }
  await $.turn.complete(ended('aborted'))
  await h.settle()
  await $.classic.SessionStart({ source: 'clear', session_id: 's2' })
  await h.settle()
  h.submitHold.on = false
  h.releaseSubmits()
  await h.settle()
  await h.answerEvents()
  expect(h.fills).toEqual([])
  expect([lateOutcome(h, 'r1'), lateOutcome(h, 'r2')]).toEqual([[], []])
})

test('a connection that drops while held dictations are being submitted at the turn\'s end still submits them all', async ($, on) => {
  const h = harness(on)
  await held($, h, [submitCommand('first'), { ...submitCommand('second'), id: 'r2' }])
  h.submitHold.on = true
  await $.turn.complete(ended())
  await h.settle()
  await h.answerEvents()
  h.submitHold.on = false
  await dropConnection(h)
  h.releaseSubmits()
  await h.settle()
  h.releaseSubmits()
  await h.settle()
  await h.answerEvents()
  expect(h.submits).toEqual(['first', 'second'])
  expect(lateOutcome(h, 'r2')).toEqual([])
})

test('a held dictation whose prompt box cannot be read at the turn\'s end is reported, never silently lost', async ($, on) => {
  const h = harness(on)
  await held($, h)
  h.box.readThrows = true
  await $.turn.complete(ended())
  await h.settle()
  await h.answerEvents()
  expect(h.submits).toEqual([])
  expect(lateOutcome(h, 'r1')).toEqual(['stopped'])
})

test('a held dictation the prompt box fails to take after Esc is reported, never silently lost', async ($, on) => {
  const h = harness(on)
  await held($, h)
  h.downstream['prompt.submit'] = { drop: stopped }
  h.fillRefusal.throws = true
  await $.turn.complete(ended('aborted'))
  await h.settle()
  await h.answerEvents()
  expect(lateOutcome(h, 'r1')).toEqual(['stopped'])
})

test('a late refusal whose connection drops before it lands is sent again on the next connection', async ($, on) => {
  const h = harness(on)
  await held($, h)
  h.box.text = 'half typed'
  await $.turn.complete(ended())
  await h.settle()
  for (let i = 0; i < 20 && h.open('/event')[0] && h.open('/event')[0].body.op !== 'refused'; i++) {
    h.open('/event')[0].answer(200)
    await h.settle()
  }
  const lost = h.open('/event')[0]
  expect(lost.body).toMatchObject({ op: 'refused', request: 'r1', reason: 'draft' })
  h.open('/poll')[0].answer(409)
  await h.settle()
  lost.answer(200)
  await h.settle()
  const hello = h.open('/event').find((r: any) => r.body.op === 'hello')
  hello.answer(200)
  await h.settle()
  await h.answerEvents()
  const refusals = h.events().filter((b: any) => b.request === 'r1' && b.op === 'refused')
  expect(refusals.slice(-1)[0]).toMatchObject({ reason: 'draft', connection: hello.body.connection })
})

test('after Esc a held dictation that starts with a slash is reported, never put in the box, while the plain ones still are', async ($, on) => {
  const h = harness(on)
  await held($, h, [submitCommand('plain words'), { ...submitCommand('/resume'), id: 'r2' }])
  h.downstream['prompt.submit'] = { drop: stopped }
  await $.turn.complete(ended('aborted'))
  await h.settle()
  await h.answerEvents()
  expect(h.box.text).toBe('plain words')
  expect([lateOutcome(h, 'r1'), lateOutcome(h, 'r2')]).toEqual([['filled'], ['stopped']])
})

test('a held dictation that starts with a slash starts the next turn as text, never as a command', async ($, on) => {
  const h = harness(on)
  await held($, h, [submitCommand('/resume')])
  await $.turn.complete(ended())
  await h.settle()
  expect(h.submits).toEqual(['​/resume'])
})

test('a held dictation never reaches a session that replaced its own', async ($, on) => {
  const h = harness(on)
  await held($, h)
  await $.classic.SessionStart({ source: 'clear', session_id: 's2' })
  await h.settle()
  await toolCall($, 'tu1')
  await $.turn.complete(ended())
  await h.settle()
  expect(h.appended).toEqual([])
  expect(h.submits).toEqual([])
})

test('a held dictation never reaches a conversation disconnected meanwhile', async ($, on) => {
  const h = harness(on)
  await held($, h)
  await h.deliver([{ op: 'quiet', id: 'q1', expectedSession: 's1' }])
  await toolCall($, 'tu1')
  await $.turn.complete(ended())
  await h.settle()
  expect(h.appended).toEqual([])
  expect(h.submits).toEqual([])
})

test('an append that fails still returns the tool\'s result and leaves the dictation for the turn\'s end', async ($, on) => {
  const h = harness(on)
  await held($, h)
  h.appendHold.throws = true
  expect(await toolCall($, 'tu1')).toMatchObject({ result: 'tool output' })
  await $.turn.complete(ended())
  await h.settle()
  expect(h.submits).toEqual(['run the tests'])
})

test('a dictation arriving as its turn ends is submitted rather than left waiting for a tool call', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  h.clockHold.on = true
  await h.deliver([submitCommand()])
  h.clockHold.on = false
  const ending = $.turn.complete(ended())
  await h.settle()
  for (const release of h.clockHold.held.splice(0)) release()
  await ending
  await h.answerEvents()
  expect(h.submits).toEqual(['run the tests'])
  expect(h.events().filter((b: any) => b.request === 'r1' && b.op === 'submitted').length).toBe(1)
})

const band = { plugin: 'keyscribe-connector-test', component: 'AbovePrompt', requestId: 'band', surface: 'terminal', props: { hasSurvey: false, isCollapsed: false, isWorking: true, bodyRows: 10, bodyColumns: 80 } } as const

test('a held dictation shows above the prompt until the turn takes it in, as queued typing does', async ($, on) => {
  const h = harness(on)
  await held($, h)
  const before = await $.ui.mount(band as any)
  expect((await before.find({ type: 'Text', text: /run the tests/ }))).toBeTruthy()
  await before.unmount()
  await toolCall($, 'tu1')
  await step($)
  const after = await $.ui.mount(band as any)
  expect((await after.find({ type: 'Text', text: /run the tests/ }))).toBeFalsy()
  await after.unmount()
})

test('a dictation that joined the turn is drawn as the user\'s prompt under the tool call that carried it', async ($, on) => {
  const h = harness(on)
  await held($, h)
  await toolCall($, 'tu1')
  await step($)
  await h.settle()
  const group = await $.ui.mount({ plugin: 'keyscribe-connector-test', component: 'ToolGroup', requestId: 'g', surface: 'terminal', props: { calls: [{ tool_use_id: 'tu1', tool: 'Bash' }], isExpanded: false } } as any)
  expect((await group.find({ type: 'Text', text: /run the tests/ }))).toBeTruthy()
  await group.unmount()
  const other = await $.ui.mount({ plugin: 'keyscribe-connector-test', component: 'ToolGroup', requestId: 'g2', surface: 'terminal', props: { calls: [{ tool_use_id: 'tu9', tool: 'Bash' }], isExpanded: false } } as any)
  expect((await other.find({ type: 'Text', text: /run the tests/ }))).toBeFalsy()
  await other.unmount()
})

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

test('a turn starting while the draft is being read takes the dictation into that turn', async ($, on) => {
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
  expect(h.events().filter((b) => b.request === 'r1').map((b) => b.reason ?? b.op)).toEqual(['ack', 'submitted'])
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
  await $.session.end({ reason: 'clear', sessionId: 's1', resume: { id: 's1' } })
  await $.classic.SessionStart({ source: 'clear', session_id: 's2' })
  h.live.session = 's2'
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
  await $.session.end({ reason: 'clear', sessionId: 's1', resume: { id: 's1' } })
  await $.classic.SessionStart({ source: 'clear', session_id: 's2' })
  h.live.session = 's2'
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
  h.files['/plugin/keyscribe.json'] = JSON.stringify({ protocol: 2, socketPath: '/tmp/ks.sock', tokenPath: '/tmp/ks-token', readyPath: '/tmp/ks-ready.json', installation: 'I2', ...surfaces })
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
  expect(h.events()[0]).toMatchObject({ op: 'hello', session: 's1', gap: false, idle: true, features: ['focus', 'focusDefinitions', 'label', 'readiness', 'notify', 'fill', 'check', 'promptDigest', 'box', 'steer', 'merge'] })
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

test('hello reports a variable a newly added route names, and nothing the config does not list', async ($, on) => {
  const h = harness(on)
  h.env.MUX_PANE = '7'
  h.env.TMUX = '/tmp/tmux-501/default,1,0'
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await h.settle()
  expect(h.events()[0]).toMatchObject({ op: 'hello', environment: { MUX_PANE: '7' } })
  expect(Object.keys(h.events()[0].environment)).toEqual(['MUX_PANE'])
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

test('a turn running when dictation arrives is joined, not interrupted', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  await h.answerEvents()
  await h.deliver([{ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests', expectedPrompts: 0 }])
  await h.answerEvents()
  expect(h.submits).toEqual([])
  expect(h.events().filter((b) => b.request === 'r1')).toMatchObject([
    { op: 'ack', request: 'r1' },
    { op: 'submitted', request: 'r1', turn: '' },
  ])
})

test('a connection lost during a turn reconnects busy, holds dictation for the turn, and submits again once the turn ends', async ($, on) => {
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

  expect(h.submits).toEqual(['run the tests'])
  const after = h.events().slice(h.events().indexOf(hello.body) + 1)
  expect(after.map((b) => [b.op === 'refused' ? b.reason : b.op, b.connection])).toEqual([
    ['ack', hello.body.connection],
    ['submitted', hello.body.connection],
    ['turnComplete', hello.body.connection],
  ])
  expect(h.open('/poll').map((r) => r.body.connection)).toEqual([hello.body.connection])

  await h.deliver([{ op: 'submit', id: 'r2', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text: 'run the tests', expectedPrompts: 0 }])
  await h.answerEvents()
  expect(h.submits).toEqual(['run the tests', 'run the tests'])
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
  expect(h.submits).toEqual([])
  expect(h.events().filter((b) => b.request === 'r1').map((b) => b.reason ?? b.op)).toEqual(['ack', 'submitted'])
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

test('a draft that ends in a tab takes the dictation with no extra space', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.box.text = 'first\t'
  await h.deliver([mergeCommand()])
  await h.answerEvents()
  expect(h.box.text).toBe('first\trun the tests')
})
