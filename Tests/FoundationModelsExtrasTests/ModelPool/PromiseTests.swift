@testable import FoundationModelsExtras
import Testing

/// A ``Promise`` keeps the first value it gets, and gives it to each waiter.
///
/// A waiter starts with `Task.immediate`: its body runs on the task of the
/// test until it suspends in the wait. Thus the wait is recorded when the
/// start returns, and the test needs no poll.
@Suite("Promise: one value, any number of waiters")
struct PromiseTests {
    /// The number of waiters of the test with two waiters.
    private static let twoWaiters = 2

    @Test("a value that comes before the wait is the value of the wait")
    func valueBeforeTheWait() async {
        let promise = Promise<String>()

        promise.fulfill("early")

        #expect(await promise.value == "early")
    }

    @Test("a value that comes after the wait ends the wait")
    func valueAfterTheWait() async throws {
        let promise = Promise<String>()
        let waiter = Task.immediate { await promise.value }
        try #require(promise.waiterCount == 1)

        promise.fulfill("late")

        #expect(await waiter.value == "late")
    }

    @Test("two waiters get the same value")
    func twoWaitersGetTheSameValue() async throws {
        let promise = Promise<String>()
        let first = Task.immediate { await promise.value }
        let second = Task.immediate { await promise.value }
        try #require(promise.waiterCount == Self.twoWaiters)

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
