import Foundation

/// When the download of one model file stops and tries again.
///
/// A transfer stalls when no bytes arrive for ``stallInterval``. The download
/// then stops the request and sends a new one that asks for the bytes after
/// the bytes it already wrote. Before retry `n`, it waits
/// `initialBackoff * 2^(n - 1)`, and not more than ``maximumBackoff``. After
/// ``retryLimit`` retries, a stall stops the download with
/// ``ModelDownloadError/stalled(repository:file:attempts:)``.
///
/// A transfer that fails with a transient network error (see
/// ``isTransient(_:)``), for example a lost connection, also gets a new
/// request after the backoff. These retries have their own count and their
/// own limit, ``networkRetryLimit``. An attempt that wrote new bytes before
/// the error sets the count to zero again. Thus a long download survives a
/// connection that drops many times, and a time with no network that is
/// shorter than the sum of the backoffs. After the limit, the download
/// throws the network error.
struct DownloadRetryPolicy: Sendable {
    /// The seconds of the stall interval of the default policy.
    private static let defaultStallSeconds = 30

    /// The stall interval of the default policy.
    static let defaultStallInterval = Duration.seconds(defaultStallSeconds)

    /// The backoff before the first retry of the default policy.
    static let defaultInitialBackoff = Duration.seconds(1)

    /// The retry limit of the default policy.
    static let defaultRetryLimit = 5

    /// The network retry limit of the default policy. With the default
    /// backoffs, the retries of one error wait for about seven minutes in
    /// total.
    static let defaultNetworkRetryLimit = 12

    /// The seconds of the maximum backoff of the default policy.
    private static let defaultMaximumBackoffSeconds = 60

    /// The maximum backoff of the default policy.
    static let defaultMaximumBackoff = Duration.seconds(defaultMaximumBackoffSeconds)

    /// The codes of the network errors that a new request can correct: a
    /// time-out, a host that cannot be found or reached, a lost connection,
    /// no network, and a network that does not allow data.
    static let transientErrorCodes: Set<URLError.Code> = [
        .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
        .notConnectedToInternet, .dataNotAllowed,
    ]

    /// The factor of each backoff over the backoff before it.
    private static let backoffFactor = 2

    /// The time with no new bytes after which a transfer stalls.
    let stallInterval: Duration

    /// The wait before the first retry.
    let initialBackoff: Duration

    /// The number of retries after the first attempt, for a stall.
    let retryLimit: Int

    /// The number of retries after a transient network error, since the
    /// last attempt that wrote new bytes.
    let networkRetryLimit: Int

    /// The longest wait before a retry.
    let maximumBackoff: Duration

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
    ///   - retryLimit: The number of retries after the first attempt, for a
    ///     stall.
    ///   - networkRetryLimit: The number of retries after a transient network
    ///     error, since the last attempt that wrote new bytes.
    ///   - maximumBackoff: The longest wait before a retry.
    ///   - sleep: Waits for a duration. The default waits with
    ///     `Task.sleep(for:)`.
    init(
        stallInterval: Duration = defaultStallInterval,
        initialBackoff: Duration = defaultInitialBackoff,
        retryLimit: Int = defaultRetryLimit,
        networkRetryLimit: Int = defaultNetworkRetryLimit,
        maximumBackoff: Duration = defaultMaximumBackoff,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.stallInterval = stallInterval
        self.initialBackoff = initialBackoff
        self.retryLimit = retryLimit
        self.networkRetryLimit = networkRetryLimit
        self.maximumBackoff = maximumBackoff
        self.sleep = sleep
    }

    /// The wait before a retry: ``initialBackoff`` before the first retry,
    /// and two times the wait before the last retry after that, but not more
    /// than ``maximumBackoff``.
    ///
    /// - Parameter retry: The number of the retry, from 1. A lower number
    ///   gives ``initialBackoff``.
    /// - Returns: The wait.
    func backoff(beforeRetry retry: Int) -> Duration {
        (1..<max(retry, 1)).reduce(min(initialBackoff, maximumBackoff)) { backoff, _ in
            min(backoff * Self.backoffFactor, maximumBackoff)
        }
    }

    /// Whether a new request can correct the error of a transfer: the error
    /// is a `URLError` with a code of ``transientErrorCodes``.
    ///
    /// - Parameter error: The error of the transfer.
    /// - Returns: `true` for a transient network error.
    static func isTransient(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return transientErrorCodes.contains(error.code)
    }
}
