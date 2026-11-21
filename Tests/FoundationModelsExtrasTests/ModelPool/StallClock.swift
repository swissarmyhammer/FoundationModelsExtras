import Foundation
import Synchronization

@testable import FoundationModelsExtras

/// The sleep function of the retry policy of a download in a test. It never
/// waits on the wall clock.
///
/// A sleep of the stall interval is the watch of a transfer. It ends when the
/// next stall of the ``HubStub`` occurred and the download wrote each byte
/// that the stalled request sent. A request that does not stall thus never
/// ends the watch, and the transfer completes first.
///
/// Each other sleep is a backoff before a retry. It ends at once, and the
/// clock records its duration. Each backoff follows one stall, thus the
/// count of the backoffs tells which stall the next watch waits for.
final class StallClock: Sendable {
    /// The seconds of the stall interval of the policy.
    private static let stallSeconds = 30

    /// The stall interval of the policy.
    static let stallInterval = Duration.seconds(stallSeconds)

    /// The first backoff of the policy. It differs from the stall interval,
    /// thus the clock can tell a backoff from a watch.
    static let initialBackoff = Duration.seconds(1)

    /// The stub whose stalls end the watches.
    private let stub: HubStub

    /// The retry limit of the policy.
    private let retryLimit: Int

    /// The network retry limit of the policy.
    private let networkRetryLimit: Int

    /// The duration of each backoff, in order.
    private let recordedBackoffs = Mutex<[Duration]>([])

    /// Makes a clock over the stalls of `stub`.
    ///
    /// - Parameters:
    ///   - stub: The stub whose stalls end the watches.
    ///   - retryLimit: The retry limit of the policy.
    ///   - networkRetryLimit: The network retry limit of the policy. The
    ///     default is the limit of the default policy.
    init(stub: HubStub, retryLimit: Int, networkRetryLimit: Int = DownloadRetryPolicy.defaultNetworkRetryLimit) {
        self.stub = stub
        self.retryLimit = retryLimit
        self.networkRetryLimit = networkRetryLimit
    }

    /// The duration of each backoff, in order.
    var backoffs: [Duration] {
        recordedBackoffs.withLock { $0 }
    }

    /// The retry policy whose sleeps go to this clock.
    var policy: DownloadRetryPolicy {
        DownloadRetryPolicy(
            stallInterval: Self.stallInterval, initialBackoff: Self.initialBackoff, retryLimit: retryLimit,
            networkRetryLimit: networkRetryLimit
        ) { [self] duration in
            try await sleep(for: duration)
        }
    }

    /// Ends a watch when the next stall occurred, and ends a backoff at once.
    ///
    /// - Parameter duration: The duration of the sleep.
    /// - Throws: `CancellationError` when the task of a watch is cancelled.
    private func sleep(for duration: Duration) async throws {
        guard duration == Self.stallInterval else {
            recordedBackoffs.withLock { $0.append(duration) }
            return
        }
        try await stub.waitForStall(number: backoffs.count + 1)
    }
}
