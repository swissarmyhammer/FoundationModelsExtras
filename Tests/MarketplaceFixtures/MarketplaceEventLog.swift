import Marketplace

/// Records the events of a ``MarketplaceStore`` and lets a test wait for one
/// (marketplace.md §6.2).
///
/// A test takes the stream before it calls `start()`, thus the log holds every
/// event of the run. The wait follows the events themselves, thus no test
/// waits for a fixed time.
public actor MarketplaceEventLog {
  /// Every event so far, in order.
  public private(set) var recorded: [MarketplaceEvent] = []

  /// What to resume when a new event arrives.
  private var observers: [CheckedContinuation<Void, Never>] = []

  /// Makes a log with no event yet.
  public init() {}

  /// Starts a task that records every event of one stream.
  ///
  /// - Parameter stream: The stream to follow. A caller takes it from
  ///   ``MarketplaceStore/events``.
  /// - Returns: The task, which the test cancels when it is done.
  public nonisolated func follow(_ stream: AsyncStream<MarketplaceEvent>) -> Task<Void, Never> {
    Task {
      for await event in stream {
        await self.append(event)
      }
    }
  }

  /// Waits until one recorded event matches.
  ///
  /// - Parameter match: Gives `true` for the event that the test waits for.
  /// - Returns: The first matching event.
  public func waitForEvent(where match: @Sendable (MarketplaceEvent) -> Bool) async -> MarketplaceEvent {
    while true {
      if let found = recorded.first(where: match) {
        return found
      }
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        observers.append(continuation)
      }
    }
  }

  /// Records one event and wakes every waiter.
  ///
  /// - Parameter event: The event that the store published.
  private func append(_ event: MarketplaceEvent) {
    recorded.append(event)
    let waiting = observers
    observers.removeAll()
    for observer in waiting {
      observer.resume()
    }
  }
}
