import { expect, test } from 'claude-code/testing'
import { absorbedText, boxCommand, checkCommand, cleared, digest, harness, queuedCommand, readyBox } from './support'

const managed = {
  name: 'org-policy',
  tier: 'prepend' as const,
  register(on: any) {
    on('classic.SessionStart', ($: any, e: any, next: any) => next.to(e, 'append'))
    on('classic.UserPromptSubmit', ($: any, e: any, next: any) => next.to(e, 'append'))
    on('prompt.attachment', ($: any, e: any, next: any) => next.to(e, 'append'))
  },
}

test('beneath a managed plugin that passes its classic hooks by, a launched session says hello as fresh and idle', { plugins: [managed] }, async ($, on) => {
  const h = harness(on)
  await $.classic.SessionStart({ source: 'startup', session_id: 's1' })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await h.settle()
  expect(h.events()[0]).toMatchObject({ op: 'hello', session: 's1', gap: false, idle: true })
})

test('beneath a managed plugin that passes its classic hooks by, a cleared session says hello as fresh', { plugins: [managed] }, async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await cleared($, h, 's2')
  await $.classic.SessionStart({ source: 'clear', session_id: 's2' })
  await h.settle()
  await h.answerEvents()
  expect(h.events().filter((b: any) => b.op === 'hello').slice(-1)[0]).toMatchObject({ session: 's2', gap: false, idle: true })
})

test('beneath a managed plugin that passes its attachments by, a prompt-box dictation the running turn takes in is still reported as absorbed', { plugins: [managed] }, async ($, on) => {
  const h = harness(on)
  await readyBox($, h)
  await h.typed($, 'run the tests', 't1')
  await $.prompt.attachment({ type: 'queued_command', text: absorbedText('run the tests'), origin: { kind: 'engine' } } as any)
  await $.session.append(queuedCommand('run the tests') as any)
  await h.answerEvents()
  expect(h.events().filter((b: any) => b.op === 'absorbed')).toMatchObject([{ op: 'absorbed', session: 's1', turn: 't1' }])
})

test('a session read that finishes after a newer session was taken up never brings the older one back', async ($, on) => {
  const h = harness(on)
  h.rowHold.on = true
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await h.settle()
  expect(h.rowReads.length).toBe(1)
  await cleared($, h, 's2')
  h.rowReads[0]()
  await h.settle()
  await h.answerEvents()
  const hellos = h.events().filter((b: any) => b.op === 'hello').map((b: any) => b.session)
  expect(hellos.slice(-1)).toEqual(['s2'])
  expect(hellos).not.toContain('s1')
})

test('a queued message another plugin rewrites before it is stored is reported as what was stored, not what arrived', async ($, on) => {
  const h = harness(on)
  await readyBox($, h)
  await h.typed($, 'run the tests', 't1')
  h.appendHold.storedAs = '[a message was withheld]'
  await $.session.append(queuedCommand('run the tests') as any)
  await h.answerEvents()
  expect(h.events().filter((b: any) => b.op === 'absorbed')).toEqual([])
})

const completed = (h: any) => h.events().filter((b: any) => b.op === 'turnComplete')

test('a queued message whose append finishes after its session was replaced never changes what the new session’s reply answers', async ($, on) => {
  const h = harness(on)
  await readyBox($, h)
  h.appendHold.gated = true
  const append = $.session.append(queuedCommand('run the tests') as any)
  await h.settle()
  h.appendHold.gated = false
  await cleared($, h, 's2')
  await h.answerEvents()
  await $.turn.start({ text: 'build it', turnId: 't5' })
  for (const release of h.appendHold.gates.splice(0)) release()
  await append
  await $.turn.complete({ turnId: 't5', answer: 'Built.', durationMs: 5, isAborted: false, usage: null, reason: 'answer' })
  await h.answerEvents()
  expect(completed(h).slice(-1)).toMatchObject([{ session: 's2', prompt: digest('build it') }])
})

test('a queued message whose append finishes after its turn ended never changes what the next turn’s reply answers', async ($, on) => {
  const h = harness(on)
  await readyBox($, h)
  h.appendHold.gated = true
  const append = $.session.append(queuedCommand('run the tests') as any)
  await h.settle()
  h.appendHold.gated = false
  await $.turn.complete({ turnId: 't1', answer: 'Done.', durationMs: 5, isAborted: false, usage: null, reason: 'answer' })
  await $.turn.start({ text: 'build it', turnId: 't2' })
  for (const release of h.appendHold.gates.splice(0)) release()
  await append
  await $.turn.complete({ turnId: 't2', answer: 'Built.', durationMs: 5, isAborted: false, usage: null, reason: 'answer' })
  await h.answerEvents()
  expect(completed(h).slice(-1)).toMatchObject([{ prompt: digest('build it') }])
})

test('a queued message with the same words as a dictation in the prompt box is never reported as that dictation, which is named only once it is sent and taken in', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  await $.prompt.submit({ text: 'yes', origin: { kind: 'peer' }, turnId: 't1', wait: false } as any)
  await h.deliver([boxCommand('yes')])
  await h.answerEvents()
  await $.session.append(queuedCommand('yes') as any)
  await h.answerEvents()
  expect(h.events().filter((b: any) => b.op === 'absorbed')).toEqual([])
  await h.typed($, 'yes', 't1')
  await $.session.append(queuedCommand('yes') as any)
  await h.answerEvents()
  expect(h.events().filter((b: any) => b.op === 'absorbed')).toMatchObject([{ turn: 't1', prompt: digest('yes'), request: 'r1' }])
})

test('a dictation left unsent in a prompt box the user then cleared never claims a later dictation with the same words', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  await h.deliver([boxCommand('yes')])
  await h.answerEvents()
  h.box.text = ''
  await h.deliver([{ ...boxCommand('yes'), id: 'r2' }])
  await h.answerEvents()
  await h.typed($, 'yes', 't1')
  await $.session.append(queuedCommand('yes') as any)
  await h.answerEvents()
  expect(h.events().filter((b: any) => b.op === 'absorbed').map((b: any) => b.request)).toEqual(['r2'])
})

test('once the newest dictation in the prompt box is sent, an older unsent one never claims what the user types next', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  await h.deliver([boxCommand('yes')])
  await h.answerEvents()
  h.box.text = ''
  await h.deliver([{ ...boxCommand('yes'), id: 'r2' }])
  await h.answerEvents()
  await h.typed($, 'yes', 't1')
  await $.session.append(queuedCommand('yes') as any)
  await h.typed($, 'yes', 't1')
  await $.session.append(queuedCommand('yes') as any)
  await h.answerEvents()
  expect(h.events().filter((b: any) => b.op === 'absorbed').map((b: any) => b.request)).toEqual(['r2'])
})
