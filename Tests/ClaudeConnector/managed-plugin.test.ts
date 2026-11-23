import { expect, test } from 'claude-code/testing'
import { boxCommand, cleared, digest, harness, readyBox, step, stored, takenIn } from './support'
import { register } from '../hooks/register.js'

const managed = {
  name: 'org-policy',
  tier: 'prepend' as const,
  register(on: any) {
    on('classic.SessionStart', ($: any, e: any, next: any) => next.to(e, 'append'))
    on('classic.UserPromptSubmit', ($: any, e: any, next: any) => next.to(e, 'append'))
    on('prompt.attachment', ($: any, e: any, next: any) => next.to(e, 'append'))
    on('session.append', ($: any, e: any, next: any) => next.to(e, 'append'))
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

test('beneath a managed plugin that passes its attachments and appended rows by, a prompt-box dictation the running turn takes in is still reported as absorbed', { plugins: [managed] }, async ($, on) => {
  const h = harness(on)
  await readyBox($, h)
  await h.typed($, 'run the tests', 't1')
  await takenIn($, h, 'run the tests')
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
  await takenIn($, h, '[a message was withheld]')
  await h.answerEvents()
  expect(h.events().filter((b: any) => b.op === 'absorbed')).toEqual([])
})

const completed = (h: any) => h.events().filter((b: any) => b.op === 'turnComplete')

test('a queued message with the same words as a dictation in the prompt box is never reported as that dictation, which is named only once it is sent and taken in', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  await $.prompt.submit({ text: 'yes', origin: { kind: 'peer' }, turnId: 't1', wait: false } as any)
  await h.deliver([boxCommand('yes')])
  await h.answerEvents()
  await takenIn($, h, 'yes')
  await h.answerEvents()
  expect(h.events().filter((b: any) => b.op === 'absorbed')).toEqual([])
  await h.typed($, 'yes', 't1')
  await takenIn($, h, 'yes')
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
  await takenIn($, h, 'yes')
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
  await takenIn($, h, 'yes')
  await h.typed($, 'yes', 't1')
  await takenIn($, h, 'yes')
  await h.answerEvents()
  expect(h.events().filter((b: any) => b.op === 'absorbed').map((b: any) => b.request)).toEqual(['r2'])
})

const registered = [
  'classic.Elicitation', 'command.run', 'prompt.submit', 'session.end', 'session.start', 'tool.call', 'tool.check', 'turn.complete', 'turn.start',
  'turn.step',
]

test('the connector hooks only the events it chose, never session.append, which a managed plugin is known to pass by', async () => {
  const names: string[] = []
  register((name: string) => {
    names.push(name)
    return { catch: () => {} }
  })
  expect([...new Set(names)].sort()).toEqual(registered)
})
