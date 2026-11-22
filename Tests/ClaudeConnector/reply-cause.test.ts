import { expect, test } from 'claude-code/testing'
import { absorbedText, digest, harness, steered, submitCommand, toolCall, queuedCommand } from './support'

const completed = (h: any) => h.events().filter((b: any) => b.op === 'turnComplete')

async function dictated($: any, h: any, text: string) {
  await h.connect($)
  h.submitHold.on = true
  await h.deliver([submitCommand(text)])
  await $.turn.start({ text, turnId: 't1' })
  h.releaseSubmits()
  await h.answerEvents()
}

test('a reply to the dictation that started the turn says it came after that dictation', async ($, on) => {
  const h = harness(on)
  await dictated($, h, 'Yes to all four.')
  await $.turn.complete({ turnId: 't1', answer: 'Done.', durationMs: 5, isAborted: false, usage: null, reason: 'answer' })
  await h.answerEvents()
  const [done] = completed(h)
  expect(done.prompt).toBe(digest('Yes to all four.'))
  expect(done.from).toBeUndefined()
})

test('a reply after another agent’s message the turn took in says it came after that agent', async ($, on) => {
  const h = harness(on)
  await dictated($, h, 'Yes to all four.')
  await $.prompt.submit({ text: 'Found a race in the cache.', origin: { kind: 'peer' }, turnId: 't1', wait: false } as any)
  await $.session.append(queuedCommand('Found a race in the cache.') as any)
  await $.turn.complete({ turnId: 't1', answer: 'The race is real.', durationMs: 5, isAborted: false, usage: null, reason: 'answer' })
  await h.answerEvents()
  expect(completed(h)).toMatchObject([{ from: 'agent', prompt: digest('Found a race in the cache.') }])
})

test('a reply after a background task’s notice says it came after that task, and a turn it started says so too', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.prompt.submit({ text: 'Build finished.', origin: { kind: 'task-notification' }, wait: false } as any)
  await $.turn.start({ text: 'Build finished.', turnId: 't1' })
  await $.turn.complete({ turnId: 't1', answer: 'It built.', durationMs: 5, isAborted: false, usage: null, reason: 'answer' })
  await h.answerEvents()
  expect(completed(h)).toMatchObject([{ from: 'task', prompt: digest('Build finished.') }])
})

test('a background task’s notice a dictated turn takes in never replaces the dictation the reply answers', async ($, on) => {
  const h = harness(on)
  await dictated($, h, 'Yes to all four.')
  await $.prompt.submit({ text: 'Build finished.', origin: { kind: 'task-notification' }, turnId: 't1', wait: false } as any)
  await $.session.append(queuedCommand('Build finished.') as any)
  await $.turn.complete({ turnId: 't1', answer: 'All four are in, and the build passed.', durationMs: 5, isAborted: false, usage: null, reason: 'answer' })
  await h.answerEvents()
  expect(completed(h)).toMatchObject([{ prompt: digest('Yes to all four.') }])
  expect(completed(h)[0].from).toBeUndefined()
})

test('a reply after something the turn took in that nobody can place names neither a sender nor a prompt', async ($, on) => {
  const h = harness(on)
  await dictated($, h, 'Yes to all four.')
  await $.session.append(queuedCommand('from nowhere') as any)
  await $.turn.complete({ turnId: 't1', answer: 'Hm.', durationMs: 5, isAborted: false, usage: null, reason: 'answer' })
  await h.answerEvents()
  const [done] = completed(h)
  expect(done.from).toBeUndefined()
  expect(done.prompt).toBeUndefined()
})

test('a reply after a dictation joined the running turn says it came after that dictation, not the message before it', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.prompt.submit({ text: 'Found a race in the cache.', origin: { kind: 'peer' }, wait: false } as any)
  await $.turn.start({ text: 'Found a race in the cache.', turnId: 't1' })
  await h.deliver([submitCommand('Yes, fix it.')])
  await h.answerEvents()
  await toolCall($, 'tu1')
  await $.turn.complete({ turnId: 't1', answer: 'Fixed.', durationMs: 5, isAborted: false, usage: null, reason: 'answer' })
  await h.answerEvents()
  expect(h.appended).toEqual([steered('Yes, fix it.')])
  const [done] = completed(h)
  expect(done.prompt).toBe(digest('Yes, fix it.'))
  expect(done.from).toBeUndefined()
})

const kinds: Array<[any, string | undefined]> = [
  [{ kind: 'peer-send-message' }, 'agent'], [{ kind: 'projects-relay' }, 'agent'], [{ kind: 'coordinator' }, 'agent'],
  [{ kind: 'observer' }, 'agent'], [{ kind: 'scheduled-trigger' }, 'schedule'], [{ kind: 'channel', server: 'slack' }, 'other'],
  [{ kind: 'plugin', name: 'notes' }, 'other'], [{ kind: 'plugin', name: 'notes', asUser: true }, undefined],
  [{ kind: 'composer' }, undefined], [{ kind: 'unclassified' }, undefined], [{ kind: 'sdk' }, undefined],
]
for (const [origin, from] of kinds) {
  test(`a turn a ${origin.kind}${origin.asUser ? ' message as the user' : ''} started names ${from ?? 'no sender'}`, async ($, on) => {
    const h = harness(on)
    await h.connect($)
    await $.prompt.submit({ text: 'Look at the cache.', origin, wait: false } as any)
    await $.turn.start({ text: 'Look at the cache.', turnId: 't1' })
    await $.turn.complete({ turnId: 't1', answer: 'Looked.', durationMs: 5, isAborted: false, usage: null, reason: 'answer' })
    await h.answerEvents()
    const [done] = completed(h)
    expect(done.from).toBe(from)
    expect(done.prompt).toBe(digest('Look at the cache.'))
  })
}

test('a message from someone else that never joined its turn is forgotten within the next turn, and a short one never matches inside another', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: 'typed by me', turnId: 't1' })
  await $.prompt.submit({ text: 'ok', origin: { kind: 'peer' }, turnId: 't1', wait: false } as any)
  await $.session.append(queuedCommand('ok then, run the tests') as any)
  await $.turn.complete({ turnId: 't1', answer: 'Ran.', durationMs: 5, isAborted: false, usage: null, reason: 'answer' })
  await $.turn.start({ text: 'typed next', turnId: 't2' })
  await $.turn.complete({ turnId: 't2', answer: 'Next.', durationMs: 5, isAborted: false, usage: null, reason: 'answer' })
  await $.turn.start({ text: 'ok', turnId: 't3' })
  await $.turn.complete({ turnId: 't3', answer: 'Ok.', durationMs: 5, isAborted: false, usage: null, reason: 'answer' })
  await h.answerEvents()
  expect(completed(h).map((b: any) => [b.from, b.prompt])).toEqual([
    [undefined, undefined], [undefined, digest('typed next')], [undefined, digest('ok')],
  ])
})
