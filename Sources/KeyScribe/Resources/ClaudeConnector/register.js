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
const submissionLimit = 64
const receiptLimit = 16
const receiptKeep = 60000
const stallSlack = 1000
const stallRetries = 3
const late = { late: true }
const unreachable = { unreachable: true }
const freshSources = ['startup', 'clear', 'fork']
const features = ['focus', 'focusDefinitions', 'label', 'readiness', 'notify', 'fill', 'check', 'promptDigest', 'box', 'steer', 'merge']
const readAloudTool = 'tell_me_when_done'
const inputLimit = 16
const senders = {
  peer: 'agent', 'peer-send-message': 'agent', 'projects-relay': 'agent', coordinator: 'agent', observer: 'agent', 'observer-activity': 'agent',
  'task-notification': 'task', 'scheduled-trigger': 'schedule', channel: 'other',
}

let config = null
let token = ''
let session = null
let freshSession = null
let endedSession = null
let helloSession = null
let generation = 0
let currentTurn = null
let lastInput = null
let opening = []
let during = []
let ownSubmit = null
let turnKnown = false
let prompts = 0
let looping = false
const laterWork = []
let wakeLater = null
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
const submissions = new Map()
const returnGuard = 1000
const drawGrace = 500
const personTools = new Set(['AskUserQuestion', 'ExitPlanMode'])
let guard = null
let lastAskAt = -Infinity
let boxFill = null
const receipts = []
const steerLimit = 16
const shownLimit = 64
let steers = []
let joined = []
let batch = null
const shown = new Map()
let loadedFrom = null
const appLabel = null
const builtVersion = null
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

async function readEnvironment($) {
  const keys = []
  try {
    const reads = await Promise.all([
    ])
    return Object.fromEntries(keys.map((key, index) => [key, reads[index]]))
  } catch (err) {
    return {}
  }
}

async function terminalPlace($) {
  const values = await readEnvironment($)
  const place = {}
  for (const key of (config && config.environmentKeys) || []) {
    if (typeof values[key] === 'string' && values[key]) place[key] = values[key]
  }
  return place
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
  let settled = false
  const expired = new Promise((resolve) => {
    const arm = async (stalls) => {
      const due = (await $.clock.now()) + ms
      if (settled) return
      timer = $.clock.after(ms, async () => {
        const stalled = (await $.clock.now()) - due >= stallSlack && stalls < stallRetries
        if (settled) return
        if (stalled) arm(stalls + 1)
        else resolve(late)
      })
    }
    quietly(arm(0))
  })
  try {
    return await Promise.race([request, expired])
  } finally {
    settled = true
    if (timer) timer.cancel()
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
    op: 'hello', protocol: config.protocol, installation: config.installation, codeVersion: builtVersion ?? undefined, agent: 'claude', agentVersion: '',
    instance, connection: attempt.connection, session: target, pid: 0,
    features, idle: turnKnown && currentTurn === null, gap: freshSession !== target,
  } : {
    op: 'hello', protocol: config.protocol, installation: config.installation, codeVersion: builtVersion ?? undefined, agent: 'claude', agentVersion: '',
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
          quietly(sendReceipts($))
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
  dropSteers($)
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

function dropSubmissions() {
  submissions.clear()
  receipts.length = 0
}

function track(id, change) {
  const was = submissions.get(id)
  submissions.delete(id)
  submissions.set(id, { ...(was || { state: 'holding' }), ...change })
  for (const old of submissions.keys()) {
    if (submissions.size <= submissionLimit) break
    submissions.delete(old)
  }
}

function report(id) {
  const sub = submissions.get(id)
  if (!sub) return { state: 'unknown' }
  return { state: sub.state, reason: sub.reason, turn: sub.turn, handedAt: sub.handedAt, seenAt: sub.seenAt }
}

function confirm($, id, at) {
  receipts.push({ id, at, sending: false })
  while (receipts.length > receiptLimit) receipts.shift()
  return sendReceipts($)
}

async function sendReceipts($) {
  const now = await $.clock.now()
  for (let i = receipts.length - 1; i >= 0; i--) {
    if (now - receipts[i].at > receiptKeep) receipts.splice(i, 1)
  }
  if (!connection) return
  for (let i = receipts.length - 1; i >= 0; i--) {
    const outdated = receipts[i].reason === 'filled' && (submissions.get(receipts[i].id) || {}).boxSent
    if (outdated && !receipts[i].sending) receipts.splice(i, 1)
  }
  for (const receipt of receipts) {
    if (receipt.sending) continue
    const sub = submissions.get(receipt.id) || {}
    receipt.sending = true
    enqueue($, {
      kind: 'reply', generation, connection,
      body: bound(receipt.reason
        ? { op: 'refused', request: receipt.id, reason: receipt.reason }
        : { op: 'submitted', request: receipt.id, turn: sub.turn || '', handedAt: sub.handedAt, seenAt: sub.seenAt }),
      done: (outcome) => {
        receipt.sending = false
        if (outcome !== 'ok') return
        const index = receipts.indexOf(receipt)
        if (index >= 0) receipts.splice(index, 1)
      },
    })
  }
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
  dropSubmissions()
  dropSteers($)
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
  dropSubmissions()
  dropSteers($)
  currentTurn = null
  lastInput = null
  opening = []
  during = []
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

function plainPrompt(value) {
  return String(value || '').replace(/^\u200b/, '').trim()
}

function ownPrompt(started, sent) {
  return plainPrompt(started) === plainPrompt(sent)
}

function promptDigest(text) {
  let hash = 0xcbf29ce484222325n
  for (const byte of new TextEncoder().encode(plainPrompt(text))) hash = ((hash ^ BigInt(byte)) * 0x100000001b3n) & 0xffffffffffffffffn
  return hash.toString(16).padStart(16, '0')
}

function refuse($, gen, id, reason) {
  if (submissions.has(id)) track(id, { state: 'refused', reason })
  return reply($, gen, { op: 'refused', request: id, reason })
}

async function submit($, id, text, expiresAt, gen, expected) {
  const handedAt = await $.clock.now()
  if (!current(expected, gen)) return refuse($, gen, id, 'sessionChanged')
  if (!(handedAt < expiresAt)) return refuse($, gen, id, 'expired')
  if (quiet) return refuse($, gen, id, 'disconnected')
  const own = { text: asText(text), turn: null }
  ownSubmit = own
  track(id, { state: 'handed', handedAt })
  let result
  try {
    result = await $.prompt.submit({ text: own.text, asUser: true })
  } catch (err) {
    if (!submissions.has(id)) return
    return refused($, gen, id, own.text, refusal(err && err.message || err))
  } finally {
    if (ownSubmit === own) ownSubmit = null
  }
  const seenAt = await $.clock.now()
  if (!submissions.has(id)) return
  if (result && result.drop) return refused($, gen, id, own.text, refusal(result.drop))
  track(id, { state: 'seen', turn: own.turn || '', seenAt })
  return confirm($, id, seenAt)
}

function steerFrame(text) {
  return 'The user sent a new message while you were working:\n' + text + '\n\nThis is how Claude Code surfaces messages the user sends mid-turn — within the running turn, often alongside the next tool result, rather than as a separate conversation turn. Address the message above as you continue this turn.'
}

function dropSteers($) {
  if (!steers.length && !joined.length) return
  steers = []
  joined = []
  quietly($.ui.invalidate('ui.render'))
}

async function holdSteer($, id, text, expiresAt, gen, expected) {
  const now = await $.clock.now()
  if (!current(expected, gen)) return refuse($, gen, id, 'sessionChanged')
  if (!(now < expiresAt)) return refuse($, gen, id, 'expired')
  if (quiet) return refuse($, gen, id, 'disconnected')
  if (!currentTurn) return submit($, id, text, expiresAt, gen, expected)
  if (steers.length >= steerLimit) return refuse($, gen, id, 'working')
  steers.push({ id, text })
  quietly($.ui.invalidate('ui.render'))
  track(id, { state: 'seen', turn: '', handedAt: now, seenAt: now })
  return confirm($, id, now)
}

async function steerIn($, toolUseId) {
  const target = session
  const turn = currentTurn
  const taking = steers
  steers = []
  const mine = { after: [] }
  batch = mine
  try {
    for (let i = 0; i < taking.length; i++) {
      if (!stillFor(target)) return
      if (currentTurn !== turn) return afterTurn([...taking.slice(i), ...mine.after.splice(0)], target)
      let appended = null
      try {
        appended = await $.session.append({ message: { type: 'user', content: [{ type: 'text', text: steerFrame(taking[i].text) }] } })
      } catch (err) {
        appended = null
      }
      if (!stillFor(target)) return
      if (!appended || appended.deny) {
        if (currentTurn !== turn) return afterTurn([...taking.slice(i), ...mine.after.splice(0)], target)
        steers = [...taking.slice(i), ...steers]
        return
      }
      const one = { ...taking[i], toolUseId }
      if (currentTurn === turn) {
        lastInput = { prompt: promptDigest(taking[i].text) }
        joined.push(one)
      } else {
        remember([one])
      }
    }
    if (mine.after.length && stillFor(target)) afterTurn(mine.after.splice(0), target)
  } finally {
    if (batch === mine) batch = null
  }
}

function afterTurn(held, target) {
  laterWork.push({ held, target })
  wake(wakeLater)
  wakeLater = null
}

async function later($) {
  for (;;) {
    while (laterWork.length === 0) await new Promise((resolve) => { wakeLater = resolve })
    const { held, target } = laterWork.shift()
    quietly(submitSteers($, held, target))
  }
}

function remember(read) {
  for (const one of read) {
    if (!one.toolUseId) continue
    shown.set(one.toolUseId, [...(shown.get(one.toolUseId) || []), one.text])
  }
  for (const old of shown.keys()) {
    if (shown.size <= shownLimit) break
    shown.delete(old)
  }
}

function confirmJoined($, turn) {
  const read = joined
  joined = []
  for (const one of read) observe($, { op: 'absorbed', session, turn, prompt: promptDigest(one.text) })
  remember(read)
  quietly($.ui.invalidate('ui.render'))
}

function endTurnSteers($) {
  remember(joined)
  joined = []
  const held = steers
  steers = []
  quietly($.ui.invalidate('ui.render'))
  if (batch) batch.after.push(...held)
  else if (held.length) quietly(submitSteers($, held, session))
}

async function lateRefuse($, held, reason) {
  const at = await $.clock.now()
  for (const one of held) {
    track(one.id, { state: 'refused', reason })
    receipts.push({ id: one.id, at, sending: false, reason })
  }
  while (receipts.length > receiptLimit) receipts.shift()
  return sendReceipts($)
}

function stillFor(target) {
  return session === target && !quiet && !retired
}

async function emptyBox($) {
  try {
    return !(await $.prompt.read()).text.trim()
  } catch (err) {
    return null
  }
}

async function submitSteers($, held, target) {
  const empty = await emptyBox($)
  if (!stillFor(target)) return
  if (empty === null) return lateRefuse($, held, 'stopped')
  if (!empty) return lateRefuse($, held, 'draft')
  for (let i = 0; i < held.length; i++) {
    if (!stillFor(target)) return
    let result = null
    try {
      result = await $.prompt.submit({ text: asText(held[i].text), asUser: true })
    } catch (err) {
      result = { drop: String(err && err.message || err) }
    }
    if (!result || !result.drop) continue
    if (refusal(result.drop) === 'stopped') return leaveInBox($, held.slice(i), target)
    await lateRefuse($, [held[i]], refusal(result.drop))
  }
}

async function leaveInBox($, held, target) {
  if (!stillFor(target)) return
  const runs = (one) => /^[/!]/.test(one.text)
  const commands = held.filter(runs)
  if (commands.length) await lateRefuse($, commands, 'stopped')
  const fillable = held.filter((one) => !runs(one))
  if (!fillable.length) return
  const empty = await emptyBox($)
  if (!stillFor(target)) return
  if (empty === null) return lateRefuse($, fillable, 'stopped')
  if (!empty) return lateRefuse($, fillable, 'draft')
  const text = fillable.map((one) => one.text).join('\n')
  let filled = null
  try {
    filled = await $.prompt.fill({ text, mode: 'append' })
  } catch (err) {
    filled = null
  }
  const reason = !filled || !filled.isFilled ? 'stopped' : filled.text === text ? 'filled' : 'added'
  if (reason === 'filled') for (const one of fillable) track(one.id, { box: text })
  return lateRefuse($, fillable, reason)
}

function noteBoxSent(text) {
  if (typeof text !== 'string') return
  const sent = [...submissions].filter(([, sub]) => sub.box !== undefined && plainPrompt(sub.box) === plainPrompt(text))
  for (const [id] of sent) track(id, { boxSent: true })
}

function shownUnder(ids) {
  if (!shown.size) return []
  return ids.flatMap((id) => (id && shown.get(id)) || [])
}

async function withShownRows($, e, next, ids) {
  const texts = shownUnder(ids)
  if (!texts.length) return next(e)
  const { Box } = $.ui.resolve(e)
  return h(Box, { flexDirection: 'column' }, await next(e), ...texts.map((text) => promptRow($, e, text)))
}

function promptRow($, e, text) {
  const { Box, Text } = $.ui.resolve(e)
  return h(Box, { backgroundColor: 'userMessageBackground' }, h(Text, { color: 'inactive' }, '❯ '), h(Text, { color: 'text' }, text))
}

async function fillBox($, id, text, expiresAt, gen, expected) {
  if (/^[/!]/.test(text)) return holdSteer($, id, text, expiresAt, gen, expected)
  const now = await $.clock.now()
  if (!(now < expiresAt)) return refuse($, gen, id, 'expired')
  if (!current(expected, gen)) return refuse($, gen, id, 'sessionChanged')
  if (quiet) return refuse($, gen, id, 'disconnected')
  track(id, { state: 'handed', handedAt: now })
  let filled
  try {
    filled = await $.prompt.fill({ text, mode: 'append' })
  } catch (err) {
    return
  }
  if (!filled || !filled.isFilled) {
    if (filled && filled.refusal === 'dialog') return refuse($, gen, id, 'dialog')
    return holdSteer($, id, text, expiresAt, gen, expected)
  }
  if (filled.text !== text) return refuse($, gen, id, 'added')
  track(id, { box: text })
  boxFill = { text, prompt: text }
  return refuse($, gen, id, 'filled')
}

function runsAsCommand(text) {
  return /^[/!]/.test(text.trimStart())
}

async function joinDraft($, id, draft, text, expiresAt, gen, expected) {
  const now = await $.clock.now()
  if (!(now < expiresAt)) return refuse($, gen, id, 'expired')
  if (!current(expected, gen)) return refuse($, gen, id, 'sessionChanged')
  if (quiet) return refuse($, gen, id, 'disconnected')
  track(id, { state: 'handed', handedAt: now })
  const joined = draft + (draft && !/\s$/.test(draft) ? ' ' : '') + text
  let box
  try {
    box = await $.prompt.fill({ text: joined.slice(draft.length), mode: 'append' })
  } catch (err) {
    return refuse($, gen, id, 'draft')
  }
  if (!box || !box.isFilled) return refuse($, gen, id, box && box.refusal === 'dialog' ? 'dialog' : 'draft')
  if (box.text !== joined) return refuse($, gen, id, 'added')
  track(id, { box: joined })
  if (!currentTurn) return refuse($, gen, id, 'joined')
  boxFill = { text: joined, prompt: text }
  return refuse($, gen, id, 'joinedMidTurn')
}

async function promptBoxState($, id) {
  const sub = submissions.get(id)
  if (!sub || sub.box === undefined) return undefined
  armGuard(await $.clock.now())
  let state
  try {
    const box = await $.prompt.fill({ text: '', mode: 'append' })
    if (!box || !box.isFilled) state = box && box.refusal === 'dialog' ? 'asking' : 'changed'
    else state = box.text === sub.box ? 'ready' : 'changed'
  } catch (err) {
    state = 'changed'
  }
  if (state === 'ready' && (await $.clock.now()) - lastAskAt < drawGrace) state = 'asking'
  if (state !== 'ready') dropGuard()
  return state
}

function armGuard(now) {
  dropGuard()
  let release
  const done = new Promise((resolve) => { release = resolve })
  guard = { until: now + returnGuard, release, done }
}

function dropGuard() {
  if (guard) guard.release()
  guard = null
}

async function heldForReturn($) {
  const held = guard
  if (!held) return
  const left = held.until - await $.clock.now()
  if (left > 0) await Promise.race([held.done, $.clock.sleep(left)])
}

async function refused($, gen, id, text, reason) {
  if (reason === 'stopped' && await leftInEmptyBox($, id, text)) reason = 'filled'
  if (!submissions.has(id)) return
  return refuse($, gen, id, reason)
}

async function leftInEmptyBox($, id, text) {
  if (/^\u200b?[/!]/.test(text)) return false
  try {
    const box = await $.prompt.read()
    if (box.text.trim() || !submissions.has(id)) return false
    const filled = await $.prompt.fill({ text })
    if (filled && filled.isFilled && filled.text === text) track(id, { box: text })
    return Boolean(filled && filled.isFilled)
  } catch (err) {
    return false
  }
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

async function focusArgv($, name) {
  const definition = ((config && config.focusDefinitions) || []).find((d) => d.id === name)
  if (!name || !definition || !Array.isArray(definition.argv) || !Array.isArray(definition.requiresEnv)) return { reason: 'unknownFocus' }
  const environment = await readEnvironment($)
  const values = {}
  for (const key of definition.requiresEnv) {
    const value = Object.prototype.hasOwnProperty.call(environment, key) ? environment[key] : null
    if (typeof value !== 'string' || !value) return { reason: 'notInPlace' }
    if (value.startsWith('-')) return { reason: 'unsafeValue' }
    values[key] = value
  }
  const argv = definition.argv.map((arg) => {
    const key = /^\{([^{}]+)\}$/.exec(arg)
    return key ? values[key[1]] : arg
  })
  if (!argv.length || argv.some((arg) => typeof arg !== 'string') || !argv[0].startsWith('/')) return { reason: 'unknownFocus' }
  return { argv }
}

async function focus($, id, name, expiresAt, gen, expected) {
  const found = await focusArgv($, name)
  if (!found.argv) return reply($, gen, { op: 'refused', request: id, reason: found.reason })
  if (!((await $.clock.now()) < expiresAt)) return reply($, gen, { op: 'refused', request: id, reason: 'expired' })
  if (!current(expected, gen)) return reply($, gen, { op: 'refused', request: id, reason: 'sessionChanged' })
  try {
    const result = await $.process.run(found.argv, { timeoutMs: 3000 })
    return reply($, gen, result.exitCode === 0 ? { op: 'focused', request: id } : { op: 'refused', request: id, reason: 'focusFailed' })
  } catch (err) {
    return reply($, gen, { op: 'refused', request: id, reason: 'focusFailed' })
  }
}

async function handle($, cmd, gen) {
  if (cmd.op === 'submit') track(cmd.id, { state: 'holding' })
  const live = await $.session.id()
  if (!current(cmd.expectedSession, gen) || cmd.expectedSession !== live) return refuse($, gen, cmd.id, 'sessionChanged')
  if (cmd.op === 'submit') {
    const hold = () => {
      if (quiet) return 'disconnected'
      if (typeof cmd.expectedPrompts === 'number' && cmd.expectedPrompts !== prompts) return 'typedSince'
      return null
    }
    if (hold()) return refuse($, gen, cmd.id, hold())
    const box = await $.prompt.read()
    if (hold()) return refuse($, gen, cmd.id, hold())
    if (box.text.trim()) {
      if (!cmd.merge || runsAsCommand(cmd.text) || runsAsCommand(box.text)) return refuse($, gen, cmd.id, 'draft')
      return joinDraft($, cmd.id, box.text, cmd.text, cmd.expiresAt, gen, cmd.expectedSession)
    }
    if (currentTurn && !cmd.box) return holdSteer($, cmd.id, cmd.text, cmd.expiresAt, gen, cmd.expectedSession)
    if (cmd.box && currentTurn) return fillBox($, cmd.id, cmd.text, cmd.expiresAt, gen, cmd.expectedSession)
    return submit($, cmd.id, cmd.text, cmd.expiresAt, gen, cmd.expectedSession)
  }
  if (cmd.op === 'check') {
    const request = cmd.request || ''
    return reply($, gen, { op: 'checked', request, check: cmd.id, ...report(request), promptBox: await promptBoxState($, request) })
  }
  if (cmd.op === 'focus') return focus($, cmd.id, cmd.definition, cmd.expiresAt, gen, cmd.expectedSession)
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
    app + ' reports your final reply. If the work is already finished, answer instead of calling it. Not for a plain "let me know".'
}

function toolAnswer(answer) {
  const app = appName()
  if (answer === true) return app + ' will report your final reply when this turn ends. Say so in one short sentence and continue.'
  if (answer === false) {
    return 'Read Agent Replies Aloud is off in ' + app + '. Tell the user to turn on Read Agent Replies Aloud in ' + app +
      '\u2019s Agent settings and ask again. Nothing will be reported.'
  }
  if (answer === 'quiet') {
    return 'This conversation is disconnected from ' + app + '. Tell the user to reconnect it in ' + app +
      '\u2019s Agent settings. Nothing will be reported.'
  }
  return app + ' didn\u2019t confirm the request, so the reply may not be reported. Tell the user.'
}

function commandAnswer(args, answer, running) {
  const app = appName()
  const cancelling = args === 'cancel'
  if (answer === 'quiet') return 'This conversation is disconnected from ' + app + '. Reconnect it in ' + app + '\u2019s Agent settings.'
  if (answer === null) {
    return cancelling ? app + ' didn\u2019t confirm the cancel.' : app + ' didn\u2019t confirm the request, so you may not get this reply.'
  }
  if (cancelling) return app + ' won\u2019t report this reply.'
  if (answer === false) return 'Read Agent Replies Aloud is off. Turn on Read Agent Replies Aloud in ' + app + '\u2019s Agent settings.'
  return running ? app + ' will report the result of this work.' : app + ' will report your next reply.'
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
      description: 'Have ' + appName() + ' report the reply when this work is done, or cancel that.',
    })
  } catch (err) {
    quietly($.ui.log('voice connector could not add its command: ' + String(err), { to: 'debug' }))
  }
}

const userOrigins = ['composer', 'bridge', 'slack-ping', 'unclassified']

function senderOf(origin) {
  if (!origin) return undefined
  if (origin.kind === 'plugin') return origin.asUser ? undefined : 'other'
  return senders[origin.kind]
}

function noteInput(e) {
  const text = plainPrompt(e.text)
  if (!text) return
  const list = e.turnId ? during : opening
  list.push({ text, from: senderOf(e.origin) })
  while (list.length > inputLimit) list.shift()
}

function matched(list, text) {
  const block = '\n' + plainPrompt(text) + '\n'
  let found = -1
  let at = -1
  list.forEach((input, index) => {
    const where = block.lastIndexOf('\n' + input.text + '\n')
    if (where >= 0 && where >= at) {
      found = index
      at = where
    }
  })
  if (found < 0) return null
  const [input] = list.splice(found, 1)
  return { from: input.from, prompt: promptDigest(input.text) }
}

function typedByUser(e) {
  return e.origin && userOrigins.includes(e.origin.kind)
}

export function register(on) {
  on('tool.call', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId !== undefined || !steers.length || (next.signal && next.signal.aborted)) return result
    try {
      await steerIn($, e.tool_use_id)
    } catch (err) {}
    return result
  })

  on('turn.step', async function* ($, e, next) {
    if (e.agentId === undefined && joined.length) confirmJoined($, e.turnId)
    return yield* next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const waiting = [...joined, ...steers]
    if (!waiting.length || e.props.hasSurvey || (e.plugin && e.plugin !== $.plugin.name)) return next(e)
    const { Box } = $.ui.resolve(e)
    return h(Box, { flexDirection: 'column' }, ...waiting.map((s) => promptRow($, e, s.text)))
  })

  on('ui.render', { component: 'ToolGroup' }, ($, e, next) =>
    e.props.isExpanded ? next(e) : withShownRows($, e, next, e.props.calls.map((c) => c.tool_use_id)))

  on('ui.render', { component: 'ToolResult' }, ($, e, next) => withShownRows($, e, next, [e.props.tool_use_id]))

  on('session.start', async ($, e, next) => {
    await offerReadAloud($)
    const started = await next(e)
    if (!looping) {
      looping = true
      quietly(sender($))
      quietly(later($))
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
      ? 'Use /' + e.command + ' to get the reply when this work is done, or /' + e.command + ' cancel.'
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

  on('tool.check', async ($, e, next) => {
    const verdict = await next(e)
    if ((verdict && verdict.decision === 'ask') || personTools.has(e.tool)) {
      lastAskAt = await $.clock.now()
      await heldForReturn($)
    }
    return verdict
  })

  on('classic.Elicitation', async ($, e, next) => {
    lastAskAt = await $.clock.now()
    await heldForReturn($)
    return next(e)
  }).catch(($, e, next) => next(e))

  on('prompt.attachment', { type: 'queued_command' }, async ($, e, next) => {
    const result = await next(e)
    if (currentTurn !== null && typeof e.text === 'string') lastInput = matched(during, e.text) || {}
    if (boxFill && typeof e.text === 'string' && e.text.includes(boxFill.text)) {
      const { prompt } = boxFill
      boxFill = null
      observe($, { op: 'absorbed', session, turn: currentTurn || '', prompt: promptDigest(prompt) })
    }
    return result
  })

  on('prompt.submit', ($, e, next) => {
    noteInput(e)
    if (typedByUser(e)) {
      noteBoxSent(e.text)
      dropGuard()
      prompts += 1
      observe($, { op: 'typed', session, prompts })
    }
    return next(e)
  })

  on('turn.start', ($, e, next) => {
    if (e.agentId === undefined) {
      currentTurn = e.turnId
      turnKnown = true
      const own = ownSubmit && ownSubmit.turn === null && ownPrompt(e.text, ownSubmit.text)
      if (own) ownSubmit.turn = e.turnId
      const named = matched(opening, e.text)
      lastInput = plainPrompt(e.text) ? (!own && named) || { prompt: promptDigest(e.text) } : null
      observe($, { op: 'turnStarted', session, turn: e.turnId, prompt: promptDigest(e.text) })
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId === undefined && (currentTurn === null || currentTurn === e.turnId)) {
      boxFill = null
      currentTurn = null
      turnKnown = true
      const after = lastInput || {}
      lastInput = null
      opening = during
      during = []
      observe($, { op: 'turnComplete', session, reason: e.reason, answer: boundedAnswer(e.answer), from: after.from, prompt: after.prompt })
      endTurnSteers($)
    }
    return result
  })
}
