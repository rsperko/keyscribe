export function eventOrders<T>(streams: readonly (readonly T[])[], limit = 120): T[][] {
  const result: T[][] = []
  const positions = streams.map(() => 0)
  const count = streams.reduce((total, stream) => total + stream.length, 0)
  function visit(prefix: T[]) {
    if (prefix.length === count) {
      if (result.length >= limit) throw new Error(`event ordering limit ${limit} exceeded; split the independent scenarios`)
      result.push(prefix)
      return
    }
    for (let i = 0; i < streams.length; i++) {
      if (positions[i] >= streams[i].length) continue
      const next = streams[i][positions[i]++]
      visit([...prefix, next])
      positions[i]--
    }
  }
  visit([])
  return result
}
