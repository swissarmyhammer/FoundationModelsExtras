import Foundation

/// When the download of one model file stops and tries again.
///
/// A transfer stalls when no bytes arrive for ``stallInterval``. The download
/// then stops the request and sends a new one that asks for the bytes after
/// the bytes it already wrote. Before retry `n`, it waits
/// `initialBackoff * 2^(n - 1)`. After ``retryLimit`` retries, a stall stops
/// the download with ``ModelDownloadError/stalled(repository:file:attempts:)``.
struct DownloadRetryPolicy: Sendable {
    /// The stall interval of the default policy.
    static let defaultStallInterval = Duration.seconds(30)

    /// The backoff before the first retry of the default policy.
    static let defaultInitialBackoff = Duration.seconds(1)

    /// The retry limit of the default policy.
    static let defaultRetryLimit = 5

    /// The factor of each backoff over the backoff before it.
    private static let backoffFactor = 2

    /// The time with no new bytes after which a transfer stalls.
    let stallInterval: Duration

    /// The wait before the first retry.
    let initialBackoff: Duration

    /// The number of retries after the first attempt.
    let retryLimit: Int

    /// Waits for a duration. The watch of a transfer and each backoff wait
    /// with it, thus a test can give a function that does not wait on the
    /// wall clock.
    let sleep: @Sendable (Duration) async throws -> Void

    /// Makes a policy.
    ///
    /// - Parameters:
    ///   - stallInterval: The time with no new bytes after which a transfer
    ///     stalls.
    ///   - initialBackoff: The wait before the first retry.
    ///   - retryLimit: The number of retries after the first attempt.
    ///   - sleep: Waits for a duration. The default waits with
    ///     `Task.sleep(for:)`.
    init(
        stallInterval: Duration = defaultStallInterval,
        initialBackoff: Duration = defaultInitialBackoff,
        retryLimit: Int = defaultRetryLimit,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.stallInterval = stallInterval
        self.initialBackoff = initialBackoff
        self.retryLimit = retryLimit
        self.sleep = sleep
    }

    /// The wait before a retry: ``initialBackoff`` before the first retry,
    /// and two times the wait before the last retry after that.
    ///
    /// - Parameter retry: The number of the retry, from 1. A lower number
    ///   gives ``initialBackoff``.
    /// - Returns: The wait.
    func backoff(beforeRetry retry: Int) -> Duration {
        (1..<max(retry, 1)).reduce(initialBackoff) { backoff, _ in backoff * Self.backoffFactor }
    }
}
