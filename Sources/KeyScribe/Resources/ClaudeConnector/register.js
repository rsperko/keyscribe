const instance = Math.random().toString(36).slice(2, 10)
const queueLimit = 64
const queueBytesLimit = 16 * 1024
const answerLimit = 8 * 1024
const eventDeadline = 2000
const pollDeadline = 28000
const identityTries = 50
const discoveryInterval = 10000
const admitLimit = 4096
const backoff = [30000, 60000, 120000, 300000]
const late = { late: true }
const unreachable = { unreachable: true }
const freshSources = ['startup', 'clear', 'fork']
const features = ['focus', 'label', 'readiness', 'notify']
const readAloudTool = 'tell_me_when_done'

let config = null
let token = ''
let session = null
let freshSession = null
let endedSession = null
let helloSession = null
let generation = 0
let currentTurn = null
let ownSubmit = null
let turnKnown = false
let prompts = 0
let looping = false
let titleSession = null
let lastTitle = null
let ownedStatus = false
let dormant = false
let launch = null
let refusedLaunch = null
let failures = 0
let cooldown = null
let greeting = null
let nudge = null
let connection = null
const admitted = new Set()
let loadedFrom = null
const appLabel = null
let retired = false
let quiet = false

const outbox = []
let outboxBytes = 0
let wakeSender = null
let wakeIdentity = null
let hello = null
let place = null

async function loadConfig($) {
  const loaded = JSON.parse(await $.fs.read($.plugin.root + '/keyscribe.json'))
  if (loadedFrom === null) loadedFrom = loaded.installation
  config = loaded
  if (loaded.installation !== loadedFrom) retire($)
}

async function terminalPlace($) {
  try {
    const pane = await $.env.get("ZELLIJ_PANE_ID")
    return pane ? { ZELLIJ_PANE_ID: pane } : {}
  } catch (err) {
    return {}
  }
}

async function readiness($) {
  try {
    const ready = JSON.parse(await $.fs.read(config.readyPath))
    return ready && typeof ready.launch === 'string' && ready.launch ? ready : null
  } catch (err) {
    return null
  }
}

function poke() {
  const resolve = nudge
  nudge = null
  wake(resolve)
}

function rest($) {
  return new Promise((resolve) => {
    let timer = null
    const done = () => {
      if (nudge === done) nudge = null
      if (timer) timer.cancel()
      resolve()
    }
    nudge = done
    if (dormant) return
    timer = $.clock.after(discoveryInterval, done)
    if (cooldown) cooldown.over.then(done)
  })
}

function goDormant() {
  dormant = true
  token = ''
  endCooldown()
}

function endCooldown() {
  if (!cooldown) return
  const ending = cooldown
  cooldown = null
  ending.timer.cancel()
  ending.release()
}

function coolDown($) {
  endCooldown()
  failures += 1
  const delay = backoff[Math.min(failures, backoff.length) - 1] * (1 + Math.random() / 4)
  let release = null
  const over = new Promise((resolve) => { release = resolve })
  const timer = $.clock.after(delay, () => {
    if (cooldown && cooldown.over === over) cooldown = null
    release()
  })
  cooldown = { timer, over, release }
}

function post($, path, body) {
  return $.http.fetch('http://keyscribe' + path, {
    method: 'POST',
    body,
    socketPath: config.socketPath,
    headers: { authorization: 'Bearer ' + token },
  })
}

async function within($, request, ms) {
  let timer = null
  const expired = new Promise((resolve) => { timer = $.clock.after(ms, () => resolve(late)) })
  try {
    return await Promise.race([request, expired])
  } finally {
    timer.cancel()
  }
}

async function exchange($, path, body, ms) {
  const request = post($, path, body)
  const settled = request.then(() => {}, () => {})
  let result = null
  try {
    result = await within($, request, ms)
  } catch (err) {
    result = unreachable
  }
  return { result, settled }
}

function quietly(promise) {
  if (promise && promise.catch) promise.catch(() => {})
}

function wake(resolve) {
  if (resolve) resolve()
}

function settle(item, ok) {
  if (item.done) item.done(ok)
}

function drain(keep) {
  for (const item of outbox.splice(0)) {
    if (keep(item)) {
      outbox.push(item)
    } else {
      outboxBytes -= item.body.length
      settle(item, false)
    }
  }
}

function enqueue($, item) {
  if (outbox.length >= queueLimit || outboxBytes + item.body.length > queueBytesLimit) {
    settle(item, false)
    return lose($)
  }
  outbox.push(item)
  outboxBytes += item.body.length
  const resolve = wakeSender
  wakeSender = null
  wake(resolve)
}

function bound(event) {
  return JSON.stringify({ ...event, instance, connection })
}

function observe($, event) {
  if (!session || helloSession !== session || quiet) return
  enqueue($, { kind: 'observe', session, generation, body: bound(event) })
}

function reply($, gen, event) {
  if (gen !== generation || !connection) return
  enqueue($, { kind: 'reply', generation: gen, connection, body: bound(event) })
}

function deliverable(item) {
  if (item.stale || item.generation !== generation) return false
  if (item.kind === 'reply') return item.connection === connection
  if (item.session !== session) return false
  return item.kind === 'hello' || helloSession === item.session
}

async function sender($) {
  for (;;) {
    while (outbox.length === 0) await new Promise((resolve) => { wakeSender = resolve })
    const item = outbox.shift()
    outboxBytes -= item.body.length
    if (!deliverable(item)) {
      settle(item, false)
      continue
    }
    const { result, settled } = await exchange($, '/event', item.render ? item.render() : item.body, eventDeadline)
    if (result === late) {
      settle(item, 'late')
      if (item.kind !== 'hello' && item.generation === generation) lose($)
      await settled
      continue
    }
    const outcome = result === unreachable ? 'unreachable' : result.status === 403 ? 'retired' : !result.ok ? 'rejected' : deliverable(item) ? 'ok' : 'stale'
    if (outcome === 'ok' && item.answer) item.answer(result.text)
    settle(item, outcome)
    if (outcome !== 'ok' && item.kind !== 'hello' && item.generation === generation) lose($)
  }
}

function greet($, target) {
  if (greeting && greeting.target === target && greeting.generation === generation) return greeting.result
  const attempt = { target, generation }
  attempt.result = tryHello($, target).finally(() => {
    if (greeting === attempt) greeting = null
  })
  greeting = attempt
  return attempt.result
}

async function tryHello($, target) {
  if (dormant || !config) return false
  const gen = generation
  const stillWanted = () => !dormant && gen === generation && target === session
  const ready = await readiness($)
  if (!ready || !stillWanted()) return false
  if (ready.protocol !== config.protocol) {
    goDormant()
    return false
  }
  if (ready.launch !== launch) {
    launch = ready.launch
    failures = 0
    token = ''
    endCooldown()
  }
  if (launch === refusedLaunch || cooldown) return false
  if (!token) {
    let read = ''
    try {
      read = (await $.fs.read(config.tokenPath)).trim()
    } catch (err) {
      return false
    }
    if (!stillWanted() || ready.launch !== launch) return false
    token = read
  }
  return sayHello($, target, launch)
}

function heard($, outcome, attemptLaunch) {
  if (outcome === 'ok') {
    failures = 0
    poke()
  } else if (outcome === 'unreachable') {
    refusedLaunch = attemptLaunch
  } else if (outcome === 'rejected') {
    goDormant()
  } else if (outcome === 'late') {
    coolDown($)
  }
}

function sayHello($, target, attemptLaunch) {
  if (hello && hello.target === target && hello.generation === generation) return hello.result
  const attempt = { target, generation, connection: Math.random().toString(36).slice(2, 12) }
  const render = () => JSON.stringify(quiet ? {
    op: 'hello', protocol: config.protocol, installation: config.installation, version: config.version, agent: 'claude', agentVersion: '',
    instance, connection: attempt.connection, session: target, pid: 0,
    features, idle: turnKnown && currentTurn === null, gap: freshSession !== target,
  } : {
    op: 'hello', protocol: config.protocol, installation: config.installation, version: config.version, agent: 'claude', agentVersion: '',
    instance, connection: attempt.connection, session: target, pid: 0,
    features, title: (titleSession === target && lastTitle) || undefined, prompts,
    idle: turnKnown && currentTurn === null, gap: freshSession !== target, turn: currentTurn || undefined,
    environment: place && Object.keys(place).length ? place : undefined,
  })
  attempt.result = new Promise((resolve) => {
    enqueue($, {
      kind: 'hello', session: target, generation, render, body: render(),
      answer: (text) => { goQuiet($, quietIn(text)) },
      done: (outcome) => {
        if (hello === attempt) hello = null
        if (outcome === 'retired') retire($)
        if (outcome === 'ok') {
          helloSession = target
          connection = attempt.connection
          admitted.clear()
        }
        if (attempt.generation === generation && target === session && attemptLaunch === launch) heard($, outcome, attemptLaunch)
        resolve(outcome === 'ok')
      },
    })
  })
  hello = attempt
  return attempt.result
}

function quietIn(text) {
  try {
    return JSON.parse(text).quiet === true
  } catch (err) {
    return false
  }
}

function goQuiet($, on) {
  quiet = on
  if (!on) return
  drain((item) => item.kind !== 'observe')
  clearOwnedUI($)
}

function clearOwnedUI($) {
  if (ownedStatus) {
    ownedStatus = false
    quietly($.ui.status(undefined))
  }
}

function forget() {
  connection = null
  admitted.clear()
}

function lose($) {
  generation += 1
  freshSession = null
  helloSession = null
  forget()
  drain(() => false)
  clearOwnedUI($)
  if (config && session) quietly(greet($, session))
}

function retire($) {
  retired = true
  goDormant()
  generation += 1
  freshSession = null
  helloSession = null
  forget()
  drain(() => false)
  clearOwnedUI($)
}

function leave($, ended) {
  generation += 1
  endedSession = ended || session
  session = null
  freshSession = null
  helloSession = null
  forget()
  currentTurn = null
  drain(() => false)
  clearOwnedUI($)
}

function adopt($, id, source) {
  if (!id || id === session) return
  if (session) leave($, session)
  session = id
  endedSession = null
  if (freshSources.includes(source)) {
    freshSession = id
    turnKnown = true
  }
  if (dormant && !retired) {
    dormant = false
    config = null
    launch = null
    failures = 0
  }
  if (config) quietly(greet($, id))
  poke()
  const resolve = wakeIdentity
  wakeIdentity = null
  wake(resolve)
}

function boundedAnswer(answer) {
  const text = typeof answer === 'string' ? answer : ''
  const gap = '\n[…]\n'
  let budget = answerLimit
  let cut = text
  while (JSON.stringify(cut).length > answerLimit) {
    budget = Math.floor(budget * 0.75)
    const head = Math.floor(budget / 3)
    cut = text.slice(0, head) + gap + text.slice(text.length - Math.max(0, budget - head - gap.length))
  }
  return cut
}

function current(expected, gen) {
  return gen === generation && expected === session
}

function asText(text) {
  return text.startsWith('/') ? '​' + text : text
}

function refusal(reason) {
  const text = String(reason)
  return /the session was stopped/i.test(text) ? 'stopped' : text.slice(0, 500)
}

function ownPrompt(started, sent) {
  const plain = (value) => String(value || '').replace(/^\u200b/, '').trim()
  return plain(started) === plain(sent)
}

async function submit($, id, text, expiresAt, gen, expected) {
  if (!current(expected, gen)) return reply($, gen, { op: 'refused', request: id, reason: 'sessionChanged' })
  if (!((await $.clock.now()) < expiresAt)) return reply($, gen, { op: 'refused', request: id, reason: 'expired' })
  if (quiet) return reply($, gen, { op: 'refused', request: id, reason: 'disconnected' })
  const own = { text: asText(text), turn: null }
  ownSubmit = own
  let result
  try {
    result = await $.prompt.submit({ text: own.text, asUser: true })
  } catch (err) {
    return reply($, gen, { op: 'refused', request: id, reason: refusal(err && err.message || err) })
  } finally {
    if (ownSubmit === own) ownSubmit = null
  }
  if (result && result.drop) return reply($, gen, { op: 'refused', request: id, reason: refusal(result.drop) })
  return reply($, gen, { op: 'submitted', request: id, turn: own.turn || '' })
}

function noteTitle($, e) {
  if (!('session_title' in e)) return
  const target = e.session_id || session
  const next = e.session_title || null
  if (target !== titleSession) {
    titleSession = target
    lastTitle = null
  }
  if (next === lastTitle) return
  lastTitle = next
  if (target === session) observe($, { op: 'title', session: target, text: next || '' })
}

async function focus($, id, expiresAt, gen, expected) {
  const surface = await $.env.get("CMUX_SURFACE_ID")
  if (!surface) return reply($, gen, { op: 'refused', request: id, reason: 'notInCmux' })
  if (!((await $.clock.now()) < expiresAt)) return reply($, gen, { op: 'refused', request: id, reason: 'expired' })
  if (!current(expected, gen)) return reply($, gen, { op: 'refused', request: id, reason: 'sessionChanged' })
  try {
    const result = await $.process.run(['/usr/bin/env', 'cmux', 'focus-panel', '--panel', surface], { timeoutMs: 3000 })
    return reply($, gen, result.exitCode === 0 ? { op: 'focused', request: id } : { op: 'refused', request: id, reason: 'focusFailed' })
  } catch (err) {
    return reply($, gen, { op: 'refused', request: id, reason: 'focusFailed' })
  }
}

async function handle($, cmd, gen) {
  const live = await $.session.id()
  if (!current(cmd.expectedSession, gen) || cmd.expectedSession !== live) {
    return reply($, gen, { op: 'refused', request: cmd.id, reason: 'sessionChanged' })
  }
  if (cmd.op === 'submit') {
    const hold = () => {
      if (quiet) return 'disconnected'
      if (typeof cmd.expectedPrompts === 'number' && cmd.expectedPrompts !== prompts) return 'typedSince'
      if (currentTurn) return 'working'
      return null
    }
    if (hold()) return reply($, gen, { op: 'refused', request: cmd.id, reason: hold() })
    const box = await $.prompt.read()
    if (hold()) return reply($, gen, { op: 'refused', request: cmd.id, reason: hold() })
    if (box.text.trim()) return reply($, gen, { op: 'refused', request: cmd.id, reason: 'draft' })
    return submit($, cmd.id, cmd.text, cmd.expiresAt, gen, cmd.expectedSession)
  }
  if (cmd.op === 'focus') return focus($, cmd.id, cmd.expiresAt, gen, cmd.expectedSession)
  if (cmd.op === 'status') {
    ownedStatus = Boolean(cmd.text)
    quietly($.ui.status(cmd.text || undefined))
    return
  }
}

async function identify($) {
  if (!endedSession) {
    const live = await $.session.id()
    if (!session && !endedSession) session = live
    return
  }
  const ended = endedSession
  for (let i = 0; i < identityTries && !session && endedSession === ended; i++) {
    await $.clock.sleep(100)
    const live = await $.session.id()
    if (live !== ended && !session && endedSession === ended) adopt($, live)
  }
  if (!session) await new Promise((resolve) => { wakeIdentity = resolve })
}

async function pollLoop($) {
  for (;;) {
    if (dormant) {
      await rest($)
      continue
    }
    if (!config) {
      try {
        await loadConfig($)
      } catch (err) {
        config = null
        goDormant()
        quietly($.ui.log('voice connector has no settings: ' + String(err), { to: 'debug' }))
      }
      continue
    }
    if (place === null) place = await terminalPlace($)
    if (!session) {
      await identify($)
      continue
    }
    const target = session
    const gen = generation
    if (target !== helloSession) {
      if (!(await greet($, target)) && session === target && helloSession !== target) await rest($)
      continue
    }
    const { result, settled } = await exchange($, '/poll', JSON.stringify({ session: target, instance, connection }), pollDeadline)
    if (result === late) {
      if (current(target, gen)) lose($)
      await settled
      continue
    }
    if (!current(target, gen)) continue
    if (result === unreachable || !result.ok) {
      if (result !== unreachable && result.status !== 409) coolDown($)
      lose($)
      continue
    }
    let commands = []
    try {
      commands = JSON.parse(result.text)
    } catch (err) {
      lose($)
      continue
    }
    for (const cmd of commands) {
      if (!current(target, gen)) break
      if (cmd.op === 'retire') {
        retire($)
        break
      }
      if (cmd.op === 'quiet' || cmd.op === 'admit') {
        reply($, gen, { op: 'ack', request: cmd.id })
        goQuiet($, cmd.op === 'quiet')
        if (cmd.op === 'admit') {
          lose($)
          break
        }
        continue
      }
      if (admitted.has(cmd.id)) {
        reply($, gen, { op: 'ack', request: cmd.id })
        continue
      }
      if (admitted.size >= admitLimit) {
        lose($)
        break
      }
      admitted.add(cmd.id)
      reply($, gen, { op: 'ack', request: cmd.id })
      quietly(handle($, cmd, gen))
    }
  }
}

function readAloudAnswer(text) {
  try {
    const answer = JSON.parse(text)
    return answer.quiet === true ? 'quiet' : answer.spoken === true
  } catch (err) {
    return null
  }
}

async function askToReadAloud($, on) {
  if (quiet) return 'quiet'
  if (!session || helloSession !== session || !connection) return null
  const turn = currentTurn || ''
  const item = { kind: 'observe', session, generation, body: bound({ op: 'notify', session, turn, on }) }
  const answered = new Promise((resolve) => {
    item.answer = (text) => resolve(readAloudAnswer(text))
    item.done = () => resolve(null)
  })
  enqueue($, item)
  const answer = await within($, answered, eventDeadline * 2)
  if (answer !== late) return answer
  item.stale = true
  return null
}

function appName() {
  return appLabel || 'the voice app'
}

function toolDescription() {
  const app = appName()
  return 'The user has ' + app + ', a voice app on this Mac. Call this only when the user explicitly asks ' + app +
    ', or asks to hear it out loud, to report when the current work is done. Call it once, then keep working. When this turn ends, ' +
    app + ' reads your final reply aloud. If the work is already finished, answer instead of calling it. Not for a plain "let me know".'
}

function toolAnswer(answer) {
  const app = appName()
  if (answer === true) return app + ' will read your final reply aloud when this turn ends. Say so in one short sentence and continue.'
  if (answer === false) {
    return 'Spoken replies are off in ' + app + '. Tell the user to turn on Read replies aloud in ' + app +
      '\u2019s Coding agent settings and ask again. Nothing will be read.'
  }
  if (answer === 'quiet') {
    return 'This conversation is disconnected from ' + app + '. Tell the user to reconnect it in ' + app +
      '\u2019s Coding agent settings. Nothing will be read.'
  }
  return app + ' didn\u2019t confirm the request, so a spoken reply can\u2019t be promised. Tell the user.'
}

function commandAnswer(args, answer, running) {
  const app = appName()
  const cancelling = args === 'cancel'
  if (answer === 'quiet') return 'This conversation is disconnected from ' + app + '. Reconnect it in ' + app + '\u2019s Coding agent settings.'
  if (answer === null) {
    return cancelling ? app + ' didn\u2019t confirm the cancel.' : app + ' didn\u2019t confirm the request, so a spoken reply isn\u2019t certain.'
  }
  if (cancelling) return app + ' won\u2019t read this reply aloud.'
  if (answer === false) return 'Spoken replies are off. Turn on Read replies aloud in ' + app + '\u2019s Coding agent settings.'
  return running ? app + ' will read the result of this work aloud.' : app + ' will read your next reply aloud.'
}

async function offerReadAloud($) {
  try {
    await $.tool.register({
      name: readAloudTool, description: toolDescription(), isDeferred: false,
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    })
  } catch (err) {
    quietly($.ui.log('voice connector could not add its tool: ' + String(err), { to: 'debug' }))
  }
  try {
    await $.command.register({
      name: $.plugin.name, immediate: true, argumentHint: '[cancel]',
      description: 'Have ' + appName() + ' read the reply aloud when this work is done, or cancel that.',
    })
  } catch (err) {
    quietly($.ui.log('voice connector could not add its command: ' + String(err), { to: 'debug' }))
  }
}

const userOrigins = ['composer', 'bridge', 'slack-ping', 'unclassified']

function typedByUser(e) {
  return e.origin && userOrigins.includes(e.origin.kind)
}

export function register(on) {
  on('session.start', async ($, e, next) => {
    await offerReadAloud($)
    const started = await next(e)
    if (!looping) {
      looping = true
      quietly(sender($))
      quietly(pollLoop($))
    }
    return started
  })

  on('tool.call', { tool: /__tell_me_when_done$/ }, async ($, e, next) => {
    if (e.tool !== 'mcp__' + $.plugin.name + '__' + readAloudTool) return next(e)
    return { result: toolAnswer(await askToReadAloud($, true)) }
  })

  on('command.run', async ($, e, next) => {
    if (e.command !== $.plugin.name) return next(e)
    const args = String(e.args || '').trim().toLowerCase()
    const running = currentTurn !== null
    const said = args && args !== 'cancel'
      ? 'Use /' + e.command + ' to hear the reply aloud, or /' + e.command + ' cancel.'
      : commandAnswer(args, await askToReadAloud($, args !== 'cancel'), running)
    quietly($.ui.log(said))
    return {}
  })

  on('session.end', ($, e, next) => {
    leave($, e.sessionId)
    return next(e)
  })

  on('classic.SessionStart', async ($, e, next) => {
    const result = await next(e)
    adopt($, e.session_id, e.source)
    noteTitle($, e)
    return result
  })

  on('classic.UserPromptSubmit', async ($, e, next) => {
    const result = await next(e)
    noteTitle($, e)
    return result
  })

  on('prompt.submit', ($, e, next) => {
    if (typedByUser(e)) {
      prompts += 1
      observe($, { op: 'typed', session, prompts })
    }
    return next(e)
  })

  on('turn.start', ($, e, next) => {
    if (e.agentId === undefined) {
      currentTurn = e.turnId
      turnKnown = true
      if (ownSubmit && ownSubmit.turn === null && ownPrompt(e.text, ownSubmit.text)) ownSubmit.turn = e.turnId
      observe($, { op: 'turnStarted', session, turn: e.turnId })
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId === undefined && (currentTurn === null || currentTurn === e.turnId)) {
      currentTurn = null
      turnKnown = true
      observe($, { op: 'turnComplete', session, reason: e.reason, answer: boundedAnswer(e.answer) })
    }
    return result
  })
}
