/// Waits for a state that a different task makes.
///
/// A test polls with a short sleep, and the time limit of its suite stops a
/// wait that never ends. Thus a test needs no gate type.
enum Waiting {
    /// The sleep between two checks.
    private static let pollInterval = Duration.milliseconds(10)

    /// Returns when `condition` is true.
    ///
    /// - Parameter condition: The state to wait for.
    /// - Throws: `CancellationError` when the task is cancelled, for example
    ///   by the time limit.
    static func until(_ condition: () async -> Bool) async throws {
        while !(await condition()) {
            try await Task.sleep(for: pollInterval)
        }
    }
}
