import { expect, test } from 'claude-code/testing'
import { dropConnection, ended, harness, held, lateOutcome, steered, step, stopped, submitCommand, toolCall } from './support'

test('a conversation disconnected while held dictations are being added gets none of the rest, and none comes back', async ($, on) => {
  const h = harness(on)
  await held($, h, [submitCommand('first'), { ...submitCommand('second'), id: 'r2' }])
  h.appendHold.gated = true
  const call = toolCall($, 'tu1')
  await h.settle()
  await h.deliver([{ op: 'quiet', id: 'q1', expectedSession: 's1' }])
  h.appendHold.gated = false
  for (const release of h.appendHold.gates.splice(0)) release()
  await call
  await h.settle()
  await toolCall($, 'tu2')
  await $.turn.complete(ended())
  await h.settle()
  expect(h.appended).toEqual([steered('first')])
  expect(h.submits).toEqual([])
})

test('a dictation held when the connection drops still joins the turn, as a steer the agent accepted does', async ($, on) => {
  const h = harness(on)
  await held($, h)
  await dropConnection(h)
  await toolCall($, 'tu1')
  await step($)
  await h.answerEvents()
  expect(h.appended).toEqual([steered('run the tests')])
  expect(lateOutcome(h, 'r1')).toEqual([])
  expect(h.events().filter((b: any) => b.op === 'absorbed').length).toBe(1)
})

test('a connection that drops while held dictations are being added still adds them all and reports them read', async ($, on) => {
  const h = harness(on)
  await held($, h, [submitCommand('first'), { ...submitCommand('second'), id: 'r2' }])
  h.appendHold.gated = true
  const call = toolCall($, 'tu1')
  await h.settle()
  h.appendHold.gated = false
  await dropConnection(h)
  for (const release of h.appendHold.gates.splice(0)) release()
  await call
  await step($)
  await h.settle()
  await h.answerEvents()
  expect(h.appended).toEqual([steered('first'), steered('second')])
  expect(h.events().filter((b: any) => b.op === 'absorbed').length).toBe(2)
})

test('a turn that ends while held dictations are being added sends the rest as the next prompt and never reports a late row as read', async ($, on) => {
  const h = harness(on)
  await held($, h, [submitCommand('first'), { ...submitCommand('second'), id: 'r2' }])
  h.appendHold.gated = true
  const call = toolCall($, 'tu1')
  await h.settle()
  await $.turn.complete(ended())
  h.appendHold.gated = false
  for (const release of h.appendHold.gates.splice(0)) release()
  await call
  await h.settle()
  await $.turn.start({ text: 'second', turnId: 't2' })
  await step($, 't2')
  await h.answerEvents()
  expect(h.appended).toEqual([steered('first')])
  expect(h.submits).toEqual(['second'])
  expect(h.events().filter((b: any) => b.op === 'absorbed')).toEqual([])
})

test('a dictation that arrives while a batch is being added and its turn ends goes after that batch\'s rest', async ($, on) => {
  const h = harness(on)
  await held($, h, [submitCommand('first'), { ...submitCommand('second'), id: 'r2' }])
  h.appendHold.gated = true
  const call = toolCall($, 'tu1')
  await h.settle()
  await h.deliver([{ ...submitCommand('third'), id: 'r3' }])
  await h.answerEvents()
  await $.turn.complete(ended())
  await h.settle()
  h.appendHold.gated = false
  for (const release of h.appendHold.gates.splice(0)) release()
  await call
  await h.settle()
  expect(h.appended).toEqual([steered('first')])
  expect(h.submits).toEqual(['second', 'third'])
})

test('a session cleared while held dictations wait for the prompt box after Esc reports none of them', async ($, on) => {
  const h = harness(on)
  await held($, h, [submitCommand('plain words'), { ...submitCommand('/resume'), id: 'r2' }])
  h.submitHold.on = true
  h.downstream['prompt.submit'] = { drop: stopped }
  await $.turn.complete(ended('aborted'))
  await h.settle()
  await $.classic.SessionStart({ source: 'clear', session_id: 's2' })
  await h.settle()
  h.submitHold.on = false
  h.releaseSubmits()
  await h.settle()
  await h.answerEvents()
  expect(h.fills).toEqual([])
  expect([lateOutcome(h, 'r1'), lateOutcome(h, 'r2')]).toEqual([[], []])
})

test('a connection that drops while held dictations are being submitted at the turn\'s end still submits them all', async ($, on) => {
  const h = harness(on)
  await held($, h, [submitCommand('first'), { ...submitCommand('second'), id: 'r2' }])
  h.submitHold.on = true
  await $.turn.complete(ended())
  await h.settle()
  await h.answerEvents()
  h.submitHold.on = false
  await dropConnection(h)
  h.releaseSubmits()
  await h.settle()
  h.releaseSubmits()
  await h.settle()
  await h.answerEvents()
  expect(h.submits).toEqual(['first', 'second'])
  expect(lateOutcome(h, 'r2')).toEqual([])
})

test('a held dictation whose prompt box cannot be read at the turn\'s end is reported, never silently lost', async ($, on) => {
  const h = harness(on)
  await held($, h)
  h.box.readThrows = true
  await $.turn.complete(ended())
  await h.settle()
  await h.answerEvents()
  expect(h.submits).toEqual([])
  expect(lateOutcome(h, 'r1')).toEqual(['stopped'])
})

test('a held dictation the prompt box fails to take after Esc is reported, never silently lost', async ($, on) => {
  const h = harness(on)
  await held($, h)
  h.downstream['prompt.submit'] = { drop: stopped }
  h.fillRefusal.throws = true
  await $.turn.complete(ended('aborted'))
  await h.settle()
  await h.answerEvents()
  expect(lateOutcome(h, 'r1')).toEqual(['stopped'])
})

test('a late refusal whose connection drops before it lands is sent again on the next connection', async ($, on) => {
  const h = harness(on)
  await held($, h)
  h.box.text = 'half typed'
  await $.turn.complete(ended())
  await h.settle()
  for (let i = 0; i < 20 && h.open('/event')[0] && h.open('/event')[0].body.op !== 'refused'; i++) {
    h.open('/event')[0].answer(200)
    await h.settle()
  }
  const lost = h.open('/event')[0]
  expect(lost.body).toMatchObject({ op: 'refused', request: 'r1', reason: 'draft' })
  h.open('/poll')[0].answer(409)
  await h.settle()
  lost.answer(200)
  await h.settle()
  const hello = h.open('/event').find((r: any) => r.body.op === 'hello')
  hello.answer(200)
  await h.settle()
  await h.answerEvents()
  const refusals = h.events().filter((b: any) => b.request === 'r1' && b.op === 'refused')
  expect(refusals.slice(-1)[0]).toMatchObject({ reason: 'draft', connection: hello.body.connection })
})

test('after Esc a held dictation that starts with a slash is reported, never put in the box, while the plain ones still are', async ($, on) => {
  const h = harness(on)
  await held($, h, [submitCommand('plain words'), { ...submitCommand('/resume'), id: 'r2' }])
  h.downstream['prompt.submit'] = { drop: stopped }
  await $.turn.complete(ended('aborted'))
  await h.settle()
  await h.answerEvents()
  expect(h.box.text).toBe('plain words')
  expect([lateOutcome(h, 'r1'), lateOutcome(h, 'r2')]).toEqual([['filled'], ['stopped']])
})

test('a held dictation that starts with a slash starts the next turn as text, never as a command', async ($, on) => {
  const h = harness(on)
  await held($, h, [submitCommand('/resume')])
  await $.turn.complete(ended())
  await h.settle()
  expect(h.submits).toEqual(['​/resume'])
})

test('a held dictation never reaches a session that replaced its own', async ($, on) => {
  const h = harness(on)
  await held($, h)
  await $.classic.SessionStart({ source: 'clear', session_id: 's2' })
  await h.settle()
  await toolCall($, 'tu1')
  await $.turn.complete(ended())
  await h.settle()
  expect(h.appended).toEqual([])
  expect(h.submits).toEqual([])
})

test('a held dictation never reaches a conversation disconnected meanwhile', async ($, on) => {
  const h = harness(on)
  await held($, h)
  await h.deliver([{ op: 'quiet', id: 'q1', expectedSession: 's1' }])
  await toolCall($, 'tu1')
  await $.turn.complete(ended())
  await h.settle()
  expect(h.appended).toEqual([])
  expect(h.submits).toEqual([])
})

test('an append that fails still returns the tool\'s result and leaves the dictation for the turn\'s end', async ($, on) => {
  const h = harness(on)
  await held($, h)
  h.appendHold.throws = true
  expect(await toolCall($, 'tu1')).toMatchObject({ result: 'tool output' })
  await $.turn.complete(ended())
  await h.settle()
  expect(h.submits).toEqual(['run the tests'])
})

test('a dictation arriving as its turn ends is submitted rather than left waiting for a tool call', async ($, on) => {
  const h = harness(on)
  await h.connect($)
  await $.turn.start({ text: '', turnId: 't1' })
  h.clockHold.on = true
  await h.deliver([submitCommand()])
  h.clockHold.on = false
  const ending = $.turn.complete(ended())
  await h.settle()
  for (const release of h.clockHold.held.splice(0)) release()
  await ending
  await h.answerEvents()
  expect(h.submits).toEqual(['run the tests'])
  expect(h.events().filter((b: any) => b.request === 'r1' && b.op === 'submitted').length).toBe(1)
})
