import { expect, test } from 'claude-code/testing'
import { ask, boxCommand, checkCommand, ended, harness, outcome, promptBox, readyBox, stopped, submitCommand, toolCall } from './support'

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

for (const said of ['/resume', '  !ls']) {
  test(`a stopped submission of ${JSON.stringify(said)} is never put in the box, where Return would run it as a command or in the shell`, async ($, on) => {
    const h = harness(on)
    h.downstream['prompt.submit'] = { drop: stopped }
    await h.connect($)
    await h.deliver([submitCommand(said)])
    await h.answerEvents()
    expect(h.fills).toEqual([])
    expect(outcome(h)).toEqual(['ack', 'stopped'])
  })
}

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
