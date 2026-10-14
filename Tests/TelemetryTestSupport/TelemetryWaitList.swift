import Synchronization

/// The waits of one capture for a condition on its records.
///
/// Each wait has a test of its condition. When a record arrives, the list
/// runs the test of each wait, and it resumes each wait whose test is now
/// true. The list runs each test outside its lock, because a test reads the
/// records of the capture, and a record can arrive while the test runs.
///
/// The list uses no clock, no poll and no sleep. A wait ends only when a
/// record arrives and its test is true, or when its task is cancelled.
final class TelemetryWaitList: Sendable {
    /// One wait that did not end.
    private struct Wait {
        /// Tells if the condition of the wait is true now.
        let isSatisfied: @Sendable () -> Bool

        /// Resumes the wait.
        let continuation: CheckedContinuation<Void, Never>
    }

    /// Everything that a wait, a record or a cancel changes.
    private struct State {
        /// Each wait that did not end, by id. A lower id came first.
        var waits: [Int: Wait] = [:]

        /// The id of each wait that has an id but is not in ``waits`` yet.
        var pending: Set<Int> = []

        /// The id of each pending wait whose task was cancelled.
        var cancelled: Set<Int> = []

        /// The id that the next wait gets.
        var nextID = 0

        /// What to resume when the set of waits changes.
        var observers: [CheckedContinuation<Void, Never>] = []
    }

    /// What one wait does after it puts itself in the list.
    private enum WaitStart {
        /// The task was already cancelled.
        case cancelled

        /// The wait is in the list.
        case waiting
    }

    /// The state of the list.
    private let state = Mutex(State())

    /// Waits until `isSatisfied` gives `true`, or until the task is
    /// cancelled.
    ///
    /// The wait runs `isSatisfied` at once. When it gives `true`, the wait
    /// ends at once. Else the wait runs it again after each record.
    ///
    /// - Parameter isSatisfied: The test of the condition. It must not
    ///   block.
    func wait(until isSatisfied: @escaping @Sendable () -> Bool) async {
        guard !isSatisfied() else {
            return
        }
        let id = makeID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                add(Wait(isSatisfied: isSatisfied, continuation: continuation), id: id)
            }
        } onCancel: {
            cancelWait(id: id)
        }
    }

    /// Resumes each wait whose condition is true now.
    ///
    /// Call this after each record that the capture keeps, outside each
    /// lock of the record store.
    func recordDidArrive() {
        let waits = state.withLock { $0.waits }
        for (id, wait) in waits.sorted(by: { $0.key < $1.key }) where wait.isSatisfied() {
            endWait(id: id)
        }
    }

    /// Waits until at least `count` waits did not end.
    ///
    /// - Parameter count: The number of waits.
    func waitForWaits(atLeast count: Int) async {
        while state.withLock({ $0.waits.count < count }) {
            // The observer resumes at the next change of the set of waits,
            // and then the loop counts the waits again.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { current -> Bool in
                    if current.waits.count >= count {
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

    /// Gives a new wait id, and marks it pending.
    ///
    /// - Returns: The id.
    private func makeID() -> Int {
        state.withLock { current -> Int in
            defer { current.nextID += 1 }
            current.pending.insert(current.nextID)
            return current.nextID
        }
    }

    /// Puts one wait in the list, or ends it when its task was cancelled.
    ///
    /// A record can arrive between the first test of the wait and this call.
    /// Thus this call runs the test again after the wait is in the list.
    ///
    /// - Parameters:
    ///   - wait: The wait.
    ///   - id: The id of the wait.
    private func add(_ wait: Wait, id: Int) {
        let start = state.withLock { current -> WaitStart in
            current.pending.remove(id)
            if current.cancelled.remove(id) != nil {
                return .cancelled
            }
            current.waits[id] = wait
            return .waiting
        }
        switch start {
        case .cancelled:
            wait.continuation.resume()
        case .waiting:
            notifyObservers()
            if wait.isSatisfied() {
                endWait(id: id)
            }
        }
    }

    /// Ends one wait, or records the cancel when the wait is not in the list
    /// yet.
    ///
    /// - Parameter id: The id of the wait.
    private func cancelWait(id: Int) {
        let isPending = state.withLock { current -> Bool in
            guard current.pending.contains(id) else {
                return false
            }
            current.cancelled.insert(id)
            return true
        }
        guard !isPending else {
            return
        }
        endWait(id: id)
    }

    /// Removes one wait from the list and resumes it. A wait that already
    /// ended does nothing.
    ///
    /// - Parameter id: The id of the wait.
    private func endWait(id: Int) {
        let wait = state.withLock { $0.waits.removeValue(forKey: id) }
        guard let wait else {
            return
        }
        wait.continuation.resume()
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
