import { expect, test } from 'claude-code/testing'
import { band, checkCommand, digest, ended, harness, held, lateOutcome, outcome, promptBox, steered, step, stopped, submitCommand, toolCall } from './support'

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
