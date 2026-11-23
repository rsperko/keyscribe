import { expect, test } from 'claude-code/testing'
import { boxCommand, ended, harness, outcome, step, submitCommand, toolCall } from './support'

async function running($: any, h: any) {
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
}

test('a dictation sent while a turn runs is refused as working, for the app to queue, and adds nothing to that turn or the next', async ($, on) => {
  const h = harness(on)
  await running($, h)
  await h.deliver([submitCommand()])
  await h.answerEvents()
  expect(outcome(h)).toEqual(['ack', 'working'])
  await toolCall($, 'tu1')
  await step($)
  await $.turn.complete(ended())
  await h.settle()
  await h.answerEvents()
  expect(h.submits).toEqual([])
  expect(h.fills).toEqual([])
  expect(h.appended).toEqual([])
})

test('a dictation sent while a turn runs and the user has a draft in the prompt box is kept for review, not added', async ($, on) => {
  const h = harness(on)
  await running($, h)
  h.box.text = 'half typed'
  await h.deliver([submitCommand()])
  await h.answerEvents()
  expect(outcome(h)).toEqual(['ack', 'draft'])
  await toolCall($, 'tu1')
  expect(h.appended).toEqual([])
})

for (const said of ['/resume', '!echo hi', '  /clear']) {
  test(`a dictation of ${JSON.stringify(said)} for the prompt box while a turn runs is refused as working, never put where Return would run it`, async ($, on) => {
    const h = harness(on)
    await running($, h)
    await h.deliver([boxCommand(said)])
    await h.answerEvents()
    expect(outcome(h)).toEqual(['ack', 'working'])
    await $.turn.complete(ended())
    await h.settle()
    expect(h.fills).toEqual([])
    expect(h.submits).toEqual([])
  })
}

test('a dictation the prompt box will not take while a turn runs is refused as working', async ($, on) => {
  const h = harness(on)
  await running($, h)
  h.fillRefusal.reason = 'no_composer'
  await h.deliver([boxCommand()])
  await h.answerEvents()
  expect(outcome(h)).toEqual(['ack', 'working'])
  await $.turn.complete(ended())
  await h.settle()
  expect(h.submits).toEqual([])
})

test('a dictation the prompt box turns away after its turn ended is submitted, since no turn is left to wait for', async ($, on) => {
  const h = harness(on)
  await running($, h)
  h.fillHold.on = true
  await h.deliver([boxCommand()])
  expect(h.fills).toEqual(['run the tests'])
  await $.turn.complete(ended())
  h.fillRefusal.reason = 'no_composer'
  h.releaseFills()
  await h.settle()
  await h.answerEvents()
  expect(outcome(h)).toEqual(['ack', 'submitted'])
  expect(h.submits).toEqual(['run the tests'])
})

test('a refusal as working reaches the app before the end of the turn it met, so the app sends the dictation again after it', async ($, on) => {
  const h = harness(on)
  await running($, h)
  let finish = () => {}
  h.downstream['turn.complete'] = new Promise((resolve) => { finish = () => resolve({ text: '' }) })
  h.box.held = true
  await h.deliver([submitCommand()])
  const ending = $.turn.complete(ended())
  await h.settle()
  h.reads[0]()
  await h.settle()
  finish()
  await ending
  await h.answerEvents()
  const order = h.events().filter((b: any) => (b.op === 'refused' && b.request === 'r1') || b.op === 'turnComplete').map((b: any) => b.op === 'refused' ? b.reason : b.op)
  expect(order).toEqual(['working', 'turnComplete'])
  expect(h.submits).toEqual([])
})
