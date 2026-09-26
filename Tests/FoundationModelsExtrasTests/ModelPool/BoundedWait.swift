import Testing

/// A bounded wait for a state change that a test cannot await directly.
///
/// This test target sets no `.timeLimit` trait, so a wait with no bound hangs
/// the whole `swift test` run. This wait reads a condition again and again, and
/// stops at a deadline, so a condition that never becomes true fails one test.
enum BoundedWait {
    /// The time that ``spin(until:)`` gives a condition before it stops.
    ///
    /// This is a wall-clock limit, not a count of yields: a loaded machine
    /// gives the waiting task more turns than an idle one, but not more time.
    private static let ceilingNanoseconds: UInt64 = 5_000_000_000

    /// The time that ``spin(until:)`` sleeps between two readings, after its
    /// yields are spent.
    private static let pollIntervalNanoseconds: UInt64 = 5_000_000

    /// The number of yields that ``spin(until:)`` does before it starts to
    /// sleep. A change behind a small number of task hops occurs inside these
    /// yields, so the usual wait takes microseconds.
    private static let yieldsBeforePolling = 1_000

    /// Whether `condition` became true before the deadline.
    ///
    /// - Parameter condition: The state change to wait for.
    /// - Returns: Whether the condition became true before the deadline.
    private static func spin(until condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .nanoseconds(ceilingNanoseconds))
        for _ in 0..<yieldsBeforePolling {
            if await condition() { return true }
            await Task.yield()
        }
        while true {
            if await condition() { return true }
            if ContinuousClock.now >= deadline { return false }
            await waitOnePollInterval()
        }
    }

    /// Waits ``pollIntervalNanoseconds`` before the next reading.
    ///
    /// `Task.sleep` throws at once in a cancelled task. Then this function
    /// yields, so that only the deadline stops the wait.
    private static func waitOnePollInterval() async {
        if (try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)) == nil {
            await Task.yield()
        }
    }

    /// Whether `condition` became true before the deadline. When it did not,
    /// this function records an issue that names `label`.
    ///
    /// - Parameters:
    ///   - label: What must occur, named in the recorded issue.
    ///   - condition: The effect that shows that it occurred.
    /// - Returns: Whether the condition became true before the deadline.
    @discardableResult
    static func conditionReached(_ label: String, when condition: @Sendable () async -> Bool) async -> Bool {
        let reached = await spin(until: condition)
        if !reached {
            Issue.record("\(label) was never observed inside the bound, so the code that makes it happen never ran")
        }
        return reached
    }
}
