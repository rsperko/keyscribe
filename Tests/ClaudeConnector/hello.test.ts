import { expect, test } from 'claude-code/testing'
import { harness, surfaces } from './support'

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
