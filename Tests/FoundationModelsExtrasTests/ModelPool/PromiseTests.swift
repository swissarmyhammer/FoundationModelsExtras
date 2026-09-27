@testable import FoundationModelsExtras
import Testing

/// A ``Promise`` keeps the first value it gets, and gives it to each waiter.
@Suite("Promise: one value, any number of waiters")
struct PromiseTests {
    @Test("a value that comes before the wait is the value of the wait")
    func valueBeforeTheWait() async {
        let promise = Promise<String>()

        promise.fulfill("early")

        #expect(await promise.value == "early")
    }

    @Test("a value that comes after the wait ends the wait")
    func valueAfterTheWait() async {
        let promise = Promise<String>()
        let waiter = Task { await promise.value }
        #expect(await BoundedWait.conditionReached("the waiter waits") { promise.waiterCount == 1 })

        promise.fulfill("late")

        #expect(await waiter.value == "late")
    }

    @Test("two waiters get the same value")
    func twoWaitersGetTheSameValue() async {
        let promise = Promise<String>()
        let first = Task { await promise.value }
        let second = Task { await promise.value }
        #expect(await BoundedWait.conditionReached("both waiters wait") { promise.waiterCount == 2 })

        promise.fulfill("shared")

        #expect(await first.value == "shared")
        #expect(await second.value == "shared")
    }

    @Test("a second fulfill does nothing")
    func secondFulfillDoesNothing() async {
        let promise = Promise<String>()

        promise.fulfill("first")
        promise.fulfill("second")

        #expect(await promise.value == "first")
    }
}
