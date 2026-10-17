/// The waits that a test does with no clock, no sleep and no poll.
///
/// A test waits for the event that it expects. When the code under test is
/// wrong, that event can never come, thus the test also waits for the event
/// that shows the fault: the call returns, the stream ends, the task ends.
/// ``untilFirstEnds(_:)`` ends at the first of these events. Then the test
/// reads the state, and an expectation fails when the expected event did not
/// come. Thus a wrong program fails the test, and the test does not hang.
enum Waits {
    /// Waits until the first of `waits` ends, then cancels each other wait.
    ///
    /// Each wait runs on a task of its own. A wait that does not stop at the
    /// cancel keeps its task until its event comes, but the caller does not
    /// wait for it.
    ///
    /// - Parameter waits: The waits. Give at least one.
    static func untilFirstEnds(_ waits: @Sendable () async -> Void...) async {
        let first = Latch()
        let tasks = waits.map { wait in
            Task {
                await wait()
                first.open()
            }
        }
        await first.waitUntilOpen()
        for task in tasks {
            task.cancel()
        }
    }
}
