import Synchronization

/// A `Clock` that moves only when a test advances it (marketplace.md §8.2 and
/// decision 13).
///
/// ``MarketplaceStore`` takes a clock, thus its periodic check never waits for
/// real time: a test advances this clock and the next pass runs at once. The
/// clock also counts every sleep that it served, thus a test can prove that a
/// store with no `checkInterval` and no `fetchTimeout` never sleeps at all.
///
/// Every stored property is an immutable `let` of a `Sendable` type: the
/// mutable state lives inside a `Mutex`, which gives the class a plain
/// `Sendable` conformance that the compiler checks.
public final class ManualClock: Clock, Sendable {
  /// One point on the timeline of a ``ManualClock``.
  public struct Instant: InstantProtocol {
    /// How far this point is from the start of the clock.
    public let sinceStart: Duration

    /// Makes a point.
    ///
    /// - Parameter sinceStart: How far the point is from the start of the
    ///   clock.
    public init(sinceStart: Duration) {
      self.sinceStart = sinceStart
    }

    /// The point that is `duration` later than this one.
    ///
    /// - Parameter duration: How much later the new point is.
    /// - Returns: The later point.
    public func advanced(by duration: Duration) -> Instant {
      Instant(sinceStart: sinceStart + duration)
    }

    /// How far another point is from this one.
    ///
    /// - Parameter other: The other point.
    /// - Returns: The distance, which is negative when `other` is earlier.
    public func duration(to other: Instant) -> Duration {
      other.sinceStart - sinceStart
    }

    /// Whether one point is earlier than another.
    ///
    /// - Parameters:
    ///   - lhs: The left point.
    ///   - rhs: The right point.
    /// - Returns: `true` when `lhs` is earlier.
    public static func < (lhs: Instant, rhs: Instant) -> Bool {
      lhs.sinceStart < rhs.sinceStart
    }
  }

  /// One sleep that waits for the clock to reach its deadline.
  private struct Sleeper {
    /// The point at which the sleep ends.
    let deadline: Instant

    /// What to resume when the clock reaches the deadline.
    let continuation: CheckedContinuation<Void, any Error>
  }

  /// What one call of ``sleep(until:tolerance:)`` does next.
  private enum SleepStart {
    /// The task was already cancelled.
    case cancelled

    /// The clock already passed the deadline.
    case due

    /// The sleep waits for the clock to advance.
    case waiting
  }

  /// Everything that a test or a sleeper changes.
  private struct State {
    /// Where the clock stands now.
    var now = Instant(sinceStart: .zero)

    /// Each sleep that waits, by id.
    var sleepers: [Int: Sleeper] = [:]

    /// The id of each sleep whose task was cancelled before the sleep
    /// registered itself.
    var cancelled: Set<Int> = []

    /// The id that the next sleep gets.
    var nextID = 0

    /// How many sleeps the clock served, waiting ones included.
    var sleepCount = 0

    /// What to resume when the set of sleepers changes.
    var observers: [CheckedContinuation<Void, Never>] = []
  }

  /// The state of the clock.
  private let state = Mutex(State())

  /// Makes a clock that stands at its start, with no sleep served yet.
  public init() {}

  /// Where the clock stands now. It moves only in ``advance(by:)``.
  public var now: Instant {
    state.withLock { $0.now }
  }

  /// The smallest step of the clock. A manual clock has no step of its own.
  public var minimumResolution: Duration {
    .zero
  }

  /// How many sleeps the clock served since it was made.
  public var sleepCount: Int {
    state.withLock { $0.sleepCount }
  }

  /// How many sleeps wait now.
  public var sleeperCount: Int {
    state.withLock { $0.sleepers.count }
  }

  /// Waits until the clock reaches a deadline, or until the task is
  /// cancelled.
  ///
  /// - Parameters:
  ///   - deadline: The point at which the sleep ends.
  ///   - tolerance: How much later the sleep may end. A manual clock ends
  ///     each sleep exactly at its deadline, thus the value is not used.
  /// - Throws: `CancellationError` when the task of the sleep is cancelled.
  public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = state.withLock { current -> Int in
      let id = current.nextID
      current.nextID += 1
      current.sleepCount += 1
      return id
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let start = state.withLock { current -> SleepStart in
          if current.cancelled.remove(id) != nil {
            return .cancelled
          }
          if deadline <= current.now {
            return .due
          }
          current.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
          return .waiting
        }
        switch start {
        case .cancelled:
          continuation.resume(throwing: CancellationError())
        case .due:
          continuation.resume()
        case .waiting:
          notifyObservers()
        }
      }
    } onCancel: {
      cancelSleep(id: id)
    }
  }

  /// Moves the clock forward, and ends every sleep that the new point
  /// reaches.
  ///
  /// - Parameter duration: How far forward the clock moves.
  public func advance(by duration: Duration) {
    let due = state.withLock { current -> [Sleeper] in
      current.now = current.now.advanced(by: duration)
      let reached = current.sleepers.filter { $0.value.deadline <= current.now }
      for id in reached.keys {
        current.sleepers.removeValue(forKey: id)
      }
      return Array(reached.values)
    }
    for sleeper in due {
      sleeper.continuation.resume()
    }
    notifyObservers()
  }

  /// Waits until at least one sleep waits on the clock.
  public func waitForSleeper() async {
    await waitUntil { $0 > 0 }
  }

  /// Waits until no sleep waits on the clock.
  public func waitForNoSleeper() async {
    await waitUntil { $0 == 0 }
  }

  /// Waits until the number of waiting sleeps matches.
  ///
  /// - Parameter match: Takes the number of waiting sleeps and gives `true`
  ///   when the wait is over.
  private func waitUntil(_ match: @escaping @Sendable (Int) -> Bool) async {
    while true {
      let ready = state.withLock { match($0.sleepers.count) }
      if ready {
        return
      }
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let done = state.withLock { current -> Bool in
          if match(current.sleepers.count) {
            return true
          }
          current.observers.append(continuation)
          return false
        }
        if done {
          continuation.resume()
        }
      }
    }
  }

  /// Ends one sleep with a cancellation, or records the cancellation when
  /// the sleep did not register itself yet.
  ///
  /// - Parameter id: The sleep to cancel.
  private func cancelSleep(id: Int) {
    let sleeper = state.withLock { current -> Sleeper? in
      if let found = current.sleepers.removeValue(forKey: id) {
        return found
      }
      current.cancelled.insert(id)
      return nil
    }
    sleeper?.continuation.resume(throwing: CancellationError())
    notifyObservers()
  }

  /// Resumes every waiter of ``waitUntil(_:)``, outside the lock.
  private func notifyObservers() {
    let observers = state.withLock { current -> [CheckedContinuation<Void, Never>] in
      defer { current.observers.removeAll() }
      return current.observers
    }
    for observer in observers {
      observer.resume()
    }
  }
}
