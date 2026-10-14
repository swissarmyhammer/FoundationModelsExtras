import Synchronization

/// The clock of the timers of a run plane: the timeout of a run, and the
/// settle period of a background call.
///
/// A ``RunPlane`` keeps one clock, and each tool that it runs reads that
/// clock. The default is ``ContinuousRunClock``, the real time. A test gives
/// a ``ManualRunClock`` to the run plane, and then moves the time forward
/// with no real sleep.
///
/// The instants are `ContinuousClock.Instant` values, thus a deadline that a
/// context stores is the same type for each clock.
public protocol RunClock: Sendable {
    /// Where the clock stands now.
    var now: ContinuousClock.Instant { get }

    /// Waits until the clock reaches `deadline`, or until the task is
    /// cancelled. A deadline that the clock already passed ends the wait at
    /// once.
    ///
    /// - Parameter deadline: The point at which the wait ends.
    /// - Throws: `CancellationError` when the task is cancelled.
    func sleep(until deadline: ContinuousClock.Instant) async throws
}

/// The real time: a ``RunClock`` on `ContinuousClock`.
public struct ContinuousRunClock: RunClock {
    /// Makes the clock.
    public init() {}

    /// The current instant of `ContinuousClock`.
    public var now: ContinuousClock.Instant {
        ContinuousClock.now
    }

    /// Waits on `ContinuousClock` until `deadline`.
    ///
    /// - Parameter deadline: The point at which the wait ends.
    /// - Throws: `CancellationError` when the task is cancelled.
    public func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await ContinuousClock().sleep(until: deadline, tolerance: nil)
    }
}

/// A ``RunClock`` that moves only when a test advances it.
///
/// Give it to ``RunPlane/init(clock:)``. Then the timeout of each run and the
/// settle period of each background call wait on this clock, and a test ends
/// them with ``advance(by:)`` in a fixed order, with no real sleep. A test
/// that must advance only after a timer waits calls
/// ``waitForSleepers(atLeast:)`` first.
public final class ManualRunClock: RunClock {
    /// One wait for a deadline.
    private struct Sleeper {
        /// The point at which the wait ends.
        let deadline: ContinuousClock.Instant

        /// Resumes the wait.
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// What one call of ``sleep(until:)`` does next.
    private enum SleepStart {
        /// The task was already cancelled.
        case cancelled

        /// The clock already passed the deadline.
        case due

        /// The wait continues until the clock advances.
        case waiting
    }

    /// Everything that a test or a sleeper changes.
    private struct State {
        /// Where the clock stands now.
        var now: ContinuousClock.Instant

        /// Each wait, by id. A lower id came first.
        var sleepers: [Int: Sleeper] = [:]

        /// The id of each wait whose task was cancelled before the wait was
        /// recorded.
        var cancelled: Set<Int> = []

        /// The id that the next wait gets.
        var nextID = 0

        /// What to resume when the set of waits changes.
        var observers: [CheckedContinuation<Void, Never>] = []
    }

    /// The state of the clock.
    private let state: Mutex<State>

    /// Makes a clock that stands at `start`, and does not move by itself.
    ///
    /// - Parameter start: The first instant. The default is the current
    ///   instant of `ContinuousClock`.
    public init(start: ContinuousClock.Instant = .now) {
        state = Mutex(State(now: start))
    }

    /// Where the clock stands now. It moves only in ``advance(by:)``.
    public var now: ContinuousClock.Instant {
        state.withLock { $0.now }
    }

    /// The number of waits that did not end.
    public var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    /// Waits until the clock reaches `deadline`, or until the task is
    /// cancelled.
    ///
    /// - Parameter deadline: The point at which the wait ends.
    /// - Throws: `CancellationError` when the task is cancelled.
    public func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = state.withLock { current -> Int in
            defer { current.nextID += 1 }
            return current.nextID
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

    /// Moves the clock forward, and ends each wait whose deadline the new
    /// instant reaches. The waits end in deadline order, and two waits with
    /// the same deadline end in the order they started.
    ///
    /// - Parameter duration: How far the clock moves. A negative value does
    ///   not move it.
    public func advance(by duration: Duration) {
        let due = state.withLock { current -> [Sleeper] in
            current.now = current.now.advanced(by: max(.zero, duration))
            let now = current.now
            let reached = current.sleepers
                .filter { $0.value.deadline <= now }
                .sorted { ($0.value.deadline, $0.key) < ($1.value.deadline, $1.key) }
            for (id, _) in reached {
                current.sleepers.removeValue(forKey: id)
            }
            return reached.map(\.value)
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
        notifyObservers()
    }

    /// Waits until at least `count` waits did not end.
    ///
    /// - Parameter count: The number of waits.
    public func waitForSleepers(atLeast count: Int) async {
        while state.withLock({ $0.sleepers.count < count }) {
            // The observer resumes at the next change of the set of waits,
            // and then the loop counts the waits again.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { current -> Bool in
                    if current.sleepers.count >= count {
                        return true
                    }
                    current.observers.append(continuation)
                    return false
                }
                if ready {
                    continuation.resume()
                }
            }
        }
    }

    /// Ends one wait with `CancellationError`, or records the cancel when the
    /// wait is not recorded yet.
    ///
    /// - Parameter id: The id of the wait.
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

    /// Resumes each observer, outside the lock.
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
