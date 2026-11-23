import { expect, mock } from 'claude-code/testing'

export type Request = { path: string, body: any, auth: string, answer: (status: number, text?: string) => void, refuse: () => void, settled: boolean }

export const surfaces = {
  environmentKeys: ['CMUX_SURFACE_ID', 'MUX_PANE', 'ZELLIJ_PANE_ID'],
  focusDefinitions: [
    { id: 'cmux', requiresEnv: ['CMUX_SURFACE_ID'], argv: ['/usr/bin/env', 'cmux', 'focus-panel', '--panel', '{CMUX_SURFACE_ID}'] },
    { id: 'mux', requiresEnv: ['MUX_PANE'], argv: ['/opt/mux/bin/mux', 'focus', '--pane={MUX_PANE}', '{MUX_PANE}'] },
    { id: 'stray', requiresEnv: ['MUX_PANE'], argv: ['/opt/mux/bin/mux', '{TMUX}'] },
    { id: 'relative', requiresEnv: ['MUX_PANE'], argv: ['mux', '{MUX_PANE}'] },
  ],
}

export function harness(on: any) {
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
  const live = { session: 's1', rows: [] as any[], api: [] as any[] }
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
  const rowReads: Array<() => void> = []
  const rowHold = { on: false }
  const apiReads: number[] = []
  on('session.messages', ($: any, e: any) => {
    if (e && e.as === 'api') apiReads.push(e.last)
    const answer = { value: e && e.as === 'api' ? lastOf(live.api, e.last) : live.rows }
    if (!rowHold.on) return answer
    rowHold.on = false
    return new Promise((resolve) => { rowReads.push(() => resolve(answer)) })
  })
  const switches: Record<string, { session: string, rows: any[] }> = {}
  on('command.run', ($: any, e: any) => {
    const to = switches[e.command]
    if (!to) return {}
    delete switches[e.command]
    live.session = to.session
    live.rows = to.rows
    return {}
  })
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
  on('turn.start', ($: any, e: any) => {
    live.api.push({ role: 'user', content: [{ type: 'text', text: e.text }] })
    return { turnId: e.turnId }
  })
  on('turn.complete', () => downstream['turn.complete'] ?? { text: '' })
  on('turn.abort', () => ({ value: undefined }))
  on('tool.check', { tool: 'Bash' }, () => ({ decision: 'ask' }))
  on('tool.check', { tool: 'AskUserQuestion' }, () => ({ decision: 'allow' }))
  on('tool.check', { tool: 'ExitPlanMode' }, () => ({ decision: 'allow' }))
  on('classic.Elicitation', () => ({}))
  on('prompt.attachment', ($: any, e: any) => ({ text: e.text }))
  const fills: string[] = []
  const fillRefusal: { reason?: string; typedFirst?: string; throws?: boolean } = {}
  const heldFills: Array<() => void> = []
  const fillHold = { on: false }
  on('prompt.fill', async ($: any, e: any) => {
    fills.push(e.text)
    if (fillHold.on && e.text) await new Promise<void>((resolve) => { heldFills.push(resolve) })
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
  on('session.append', ($: any, e: any, next: any) => {
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

  const typed = ($: any, text = 'typed by me', turnId?: string) => $.prompt.submit({ text, origin: { kind: 'composer' }, wait: false, ...(turnId ? { turnId } : {}) })

  const readyChecks = () => fileReads.filter((p) => p === '/tmp/ks-ready.json').length
  const ready = (launch?: string, protocol = 2) => { files['/tmp/ks-ready.json'] = launch === undefined ? undefined : JSON.stringify({ launch, protocol }) }

  const releaseSubmits = () => { for (const release of heldSubmits.splice(0)) release() }
  const releaseFills = () => { for (const release of heldFills.splice(0)) release() }
  return { apiReads, fillHold, releaseFills, rowHold, rowReads, switches, appended, runs, run, clockHold, fills, fillRefusal, logs, env, store, files, fileReads, holdReads, releases, readyChecks, ready, clock, requests, submits, statuses, live, downstream, reads, box, settle, open, events, ops, connect, deliver, answerEvents, typed, submitHold, releaseSubmits }
}

function opensTurn(m: any) {
  return m.role === 'user' && !(Array.isArray(m.content) && m.content.some((block: any) => block.type === 'tool_result'))
}

function lastOf(rows: any[], last?: number) {
  if (last === undefined || rows.length <= last) return rows
  const cut = rows.length - last
  const before = rows.slice(0, cut + 1).findLastIndex(opensTurn)
  const start = before === -1 ? rows.findIndex(opensTurn) : before
  return rows.slice(start === -1 ? cut : start)
}

export function digest(text: string) {
  let hash = 0xcbf29ce484222325n
  for (const byte of new TextEncoder().encode(text)) hash = ((hash ^ BigInt(byte)) * 0x100000001b3n) & 0xffffffffffffffffn
  return hash.toString(16).padStart(16, '0')
}

export async function staleHelloFailure($: any, on: any, fail: 'reject' | 'refuse' | 'late') {
  const h = harness(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await h.settle()
  const old = h.open('/event')[0]
  expect(old.body.session).toBe('s1')

  await cleared($, h, 's2')
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

export const stopped = 'Cannot submit: the session was stopped by the user.'

export const submitCommand = (text = 'run the tests') => ({ op: 'submit', id: 'r1', expectedSession: 's1', expiresAt: Number.MAX_SAFE_INTEGER, text, expectedPrompts: 0 })

export const outcome = (h: any) => h.events().filter((b: any) => b.request === 'r1').map((b: any) => b.reason ?? b.op)

export const boxCommand = (text = 'run the tests') => ({ ...submitCommand(text), box: true })

export const checkCommand = (id: string) => ({ op: 'check', id, expectedSession: 's1', request: 'r1', expiresAt: Number.MAX_SAFE_INTEGER })

export const promptBox = (h: any, check: string) => h.events().find((b: any) => b.op === 'checked' && b.check === check)?.promptBox

export const ask = ($: any) => $.tool.check({ tool: 'Bash', input: { command: 'touch x' }, tool_use_id: 'u1' } as any)

export const readyBox = async ($: any, h: any) => {
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  await h.deliver([boxCommand()])
  await h.answerEvents()
  await h.deliver([checkCommand('c1')])
  await h.answerEvents()
  expect(promptBox(h, 'c1')).toBe('ready')
}

export async function cleared($: any, h: any, next: string) {
  await switched($, h, 'clear', next, [])
}

export async function resumed($: any, h: any, next: string) {
  await switched($, h, 'resume', next, [{ type: 'user', uuid: 'u1' }])
}

async function switched($: any, h: any, command: 'clear' | 'resume', next: string, rows: any[]) {
  const ended = h.live.session
  h.switches[command] = { session: next, rows }
  await $.session.end({ reason: command, sessionId: ended, resume: { id: ended } })
  await $.command.run({ command, args: '' } as any)
  await h.settle()
}

export function stored(h: any, ...texts: string[]) {
  h.live.api.push({ role: 'assistant', content: [{ type: 'tool_use', id: 'tu' + h.live.api.length, name: 'Read', input: {} }] })
  h.live.api.push({ role: 'user', content: [{ type: 'tool_result', tool_use_id: 'tu' + (h.live.api.length - 1), content: 'tool output' }, ...texts.map((text) => ({ type: 'text', text: absorbedText(text) }))] })
}

export async function takenIn($: any, h: any, text: string, turnId = 't1') {
  stored(h, text)
  await step($, turnId)
}

export const absorbedText = (text: string) => `The user sent a new message while you were working:\n${text}\n\nThis is how Claude Code surfaces messages the user sends mid-turn.`

export const mergeCommand = (text = 'run the tests') => ({ ...submitCommand(text), merge: true })

export const toolCall = ($: any, id: string, extra: any = {}) => $.tool.call({ tool: 'Read', input: { file_path: '/work/f' }, tool_use_id: id, ...extra } as any)

export async function step($: any, turnId = 't1', extra: any = {}) {
  const stream = $.turn.step({ turnId, index: 1, model: 'm', messageCount: 3, ...extra } as any)
  for await (const _ of stream) { }
}

export const ended = (reason = 'answer') => ({ turnId: 't1', answer: '', durationMs: 5, isAborted: reason === 'aborted', usage: null, reason })



export async function dropConnection(h: any) {
  h.open('/poll')[0].answer(409)
  await h.settle()
  const hello = h.open('/event').find((r: any) => r.body.op === 'hello')
  hello.answer(200)
  await h.settle()
  await h.answerEvents()
}


export async function staleReply($: any, on: any, released: 'beforeHello' | 'afterHello') {
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

export const readAloudTool = 'mcp__keyscribe-connector-test__tell_me_when_done'

export const readAloudCommand = 'keyscribe-connector-test'

export async function askedToReadAloud(h: any, call: Promise<any>, answer: string | null) {
  await h.settle()
  const notify = h.open('/event').find((r: any) => r.body.op === 'notify')
  expect(notify).toBeTruthy()
  if (answer !== null) notify.answer(200, answer)
  await h.settle()
  return { body: notify.body, result: await call }
}
