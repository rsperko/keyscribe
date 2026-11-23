import { expect, test } from 'claude-code/testing'
import { boxCommand, cleared, digest, harness, step, stored } from './support'

const completed = (h: any) => h.events().filter((b: any) => b.op === 'turnComplete')
const absorbed = (h: any) => h.events().filter((b: any) => b.op === 'absorbed').map((b: any) => [b.turn, b.request])

async function boxed($: any, h: any, opening = '') {
  await h.connect($)
  await $.turn.start({ text: opening, turnId: 't1' })
  await h.deliver([boxCommand()])
  await h.answerEvents()
}

const end = (turnId: string, answer = 'Done.') => ({ turnId, answer, durationMs: 5, isAborted: false, usage: null, reason: 'answer' })

type Ordering = {
  name: string
  opening?: string
  run: ($: any, h: any) => Promise<void>
  absorbed: string[][]
  reply: { session?: string, prompt?: string }
  reads?: number
  endsItsTurns?: boolean
}

const orderings: Ordering[] = [
  {
    name: 'a tool result followed by the queued dictation is read as that dictation',
    run: async ($, h) => {
      await h.typed($, 'run the tests', 't1')
      stored(h, 'run the tests')
      await step($)
    },
    absorbed: [['t1', 'r1']],
    reply: { prompt: digest('run the tests') },
  },
  {
    name: 'two queued inputs one step carries are both taken, and the reply follows the later one',
    run: async ($, h) => {
      await h.typed($, 'run the tests', 't1')
      await h.typed($, 'and lint it', 't1')
      stored(h, 'run the tests', 'and lint it')
      await step($)
    },
    absorbed: [['t1', 'r1']],
    reply: { prompt: digest('and lint it') },
  },
  {
    name: 'the same tail read again, as a retried step reads it, changes nothing it already took',
    run: async ($, h) => {
      await h.typed($, 'run the tests', 't1')
      stored(h, 'run the tests')
      await step($)
      await h.typed($, 'not taken in yet', 't1')
      await step($)
    },
    absorbed: [['t1', 'r1']],
    reply: { prompt: digest('run the tests') },
  },
  {
    name: 'a first step retried before any answer still reads nothing from the opening prompt',
    opening: 'please\nrun the tests\nthanks',
    run: async ($, h) => {
      await h.typed($, 'run the tests', 't1')
      await step($)
      await step($)
      await h.answerEvents()
      expect(absorbed(h)).toEqual([])
      stored(h, 'run the tests')
      await step($)
    },
    absorbed: [['t1', 'r1']],
    reply: { prompt: digest('run the tests') },
  },
  {
    name: 'the first step reads nothing from the opening prompt, even words a queued input repeats',
    opening: 'please\nrun the tests\nthanks',
    run: async ($, h) => {
      await h.typed($, 'run the tests', 't1')
      await step($)
      stored(h, 'run the tests')
      await step($)
    },
    absorbed: [['t1', 'r1']],
    reply: { prompt: digest('run the tests') },
  },
  {
    name: 'a read that finishes after its turn ended is dropped',
    run: async ($, h) => {
      await h.typed($, 'run the tests', 't1')
      stored(h, 'run the tests')
      h.rowHold.on = true
      const stepping = step($)
      await h.settle()
      expect(h.rowReads.length).toBe(1)
      await $.turn.complete(end('t1'))
      await $.turn.start({ text: 'build it', turnId: 't2' })
      h.rowReads[0]()
      await stepping
      await $.turn.complete(end('t2', 'Built.'))
    },
    absorbed: [],
    reply: { prompt: digest('build it') },
    endsItsTurns: true,
  },
  {
    name: 'a read that finishes after its session was replaced is dropped',
    run: async ($, h) => {
      await h.typed($, 'run the tests', 't1')
      stored(h, 'run the tests')
      h.rowHold.on = true
      const stepping = step($)
      await h.settle()
      expect(h.rowReads.length).toBe(1)
      await cleared($, h, 's2')
      await h.answerEvents()
      await $.turn.start({ text: 'build it', turnId: 't5' })
      h.rowReads[0]()
      await stepping
      await $.turn.complete(end('t5', 'Built.'))
    },
    absorbed: [],
    reply: { session: 's2', prompt: digest('build it') },
    endsItsTurns: true,
  },
  {
    name: 'a step with nothing noted since the turn began reads nothing',
    run: async ($, h) => {
      stored(h, 'from nowhere')
      await step($)
    },
    absorbed: [],
    reply: {},
    reads: 0,
  },
  {
    name: 'a read past its bound lets the step go on, and its late answer is dropped',
    run: async ($, h) => {
      await h.typed($, 'run the tests', 't1')
      stored(h, 'run the tests')
      h.rowHold.on = true
      let stepped = false
      const stepping = step($).then(() => { stepped = true })
      await h.settle()
      expect(h.rowReads.length).toBe(1)
      await h.clock.advance(500)
      await h.settle()
      expect(stepped).toBe(true)
      h.rowReads[0]()
      await stepping
    },
    absorbed: [],
    reply: {},
  },
]

for (const ordering of orderings) {
  test(ordering.name, async ($, on) => {
    const h = harness(on)
    await boxed($, h, ordering.opening)
    await ordering.run($, h)
    if (!ordering.endsItsTurns) await $.turn.complete(end('t1'))
    await h.answerEvents()
    expect(absorbed(h)).toEqual(ordering.absorbed)
    const last = completed(h).slice(-1)[0]
    expect(last.prompt).toBe(ordering.reply.prompt ?? (ordering.opening ? digest(ordering.opening) : undefined))
    if (ordering.reply.session) expect(last.session).toBe(ordering.reply.session)
    if (ordering.reads !== undefined) expect(h.apiReads.length).toBe(ordering.reads)
  })
}
