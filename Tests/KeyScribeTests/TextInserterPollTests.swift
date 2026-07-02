import Testing
@testable import KeyScribe

@MainActor
struct TextInserterPollTests {
    @Test func returnsTrueImmediatelyWhenConditionIsAlreadyTrue() async {
        let result = await TextInserter.poll(timeoutMs: 100, stepMs: 10) { true }
        #expect(result)
    }

    @Test func returnsTrueOnceConditionBecomesTrueBeforeTimeout() async {
        final class Counter { var value = 0 }
        let counter = Counter()
        let result = await TextInserter.poll(timeoutMs: 200, stepMs: 10) {
            counter.value += 1
            return counter.value >= 3
        }
        #expect(result)
        #expect(counter.value == 3)
    }

    @Test func returnsFalseWhenConditionNeverBecomesTrueWithinTimeout() async {
        final class Counter { var value = 0 }
        let counter = Counter()
        let result = await TextInserter.poll(timeoutMs: 40, stepMs: 10) {
            counter.value += 1
            return false
        }
        #expect(!result)
        #expect(counter.value > 1)
    }
}
