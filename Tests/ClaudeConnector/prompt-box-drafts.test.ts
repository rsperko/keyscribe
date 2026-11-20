import { expect, test } from 'claude-code/testing'
import { absorbedText, boxCommand, checkCommand, digest, harness, held, mergeCommand, outcome, promptBox, readyBox, steered, submitCommand, toolCall, queuedCommand, cleared } from './support'

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

test('a prompt-box dictation the running turn takes in is reported as absorbed into that turn', async ($, on) => {
  const h = harness(on)
  await readyBox($, h)
  await h.typed($, 'run the tests', 't1')
  await $.session.append(queuedCommand('run the tests') as any)
  await h.answerEvents()
  expect(h.events().filter((b: any) => b.op === 'absorbed')).toMatchObject([{ op: 'absorbed', session: 's1', turn: 't1', prompt: expect.any(String), request: 'r1' }])
})

test('another message the running turn takes in is never reported as the dictation', async ($, on) => {
  const h = harness(on)
  await readyBox($, h)
  await $.session.append(queuedCommand('something else') as any)
  await h.answerEvents()
  expect(h.events().filter((b: any) => b.op === 'absorbed')).toEqual([])
})

for (const said of ['!echo hi', '  /clear']) {
  test(`a dictation of ${JSON.stringify(said)} never goes in the prompt box, where Return would run it, and joins the turn as text`, async ($, on) => {
    const h = harness(on)
    await h.connect($)
    await $.turn.start({ text: '', turnId: 't1' })
    await h.deliver([boxCommand(said)])
    await h.answerEvents()
    expect(h.fills).toEqual([])
    expect(outcome(h)).toEqual(['ack', 'submitted'])
    await toolCall($, 'tu1')
    expect(h.appended).toEqual([steered(said)])
  })
}

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
  await cleared($, h, 's2')
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
  await h.typed($, 'half a thought run the tests', 't1')
  await $.session.append(queuedCommand('half a thought run the tests') as any)
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

test('a draft that ends in a tab takes the dictation with no extra space', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  h.box.text = 'first\t'
  await h.deliver([mergeCommand()])
  await h.answerEvents()
  expect(h.box.text).toBe('first\trun the tests')
})
