import Synchronization

/// A list of events that concurrent tasks append to, in the order of arrival.
///
/// A task can wait until the events meet a condition. Each append tests the
/// condition of each waiting task, thus the wait reads no clock and does no
/// poll. One lock keeps the list and the waits, thus a test needs no lock of
/// its own.
final class EventLog<Event: Sendable>: Sendable {
    /// One task that waits until the events meet its condition.
    private struct Waiter {
        /// The condition that ends the wait.
        let condition: @Sendable ([Event]) -> Bool

        /// Resumes the task.
        let continuation: CheckedContinuation<Void, Never>
    }

    /// The events and the waiting tasks.
    private struct State {
        /// The events, first in first.
        var events: [Event] = []

        /// Each waiting task, by the id of its wait.
        var waiters: [Int: Waiter] = [:]

        /// The id of each wait whose task was cancelled before the wait was
        /// recorded.
        var cancelled: Set<Int> = []

        /// The id that the next wait gets.
        var nextID = 0
    }

    /// The events and the waiting tasks.
    private let state = Mutex(State())

    /// The events, first in first.
    var events: [Event] {
        get async { recorded }
    }

    /// The events, first in first, for a caller that cannot wait.
    var recorded: [Event] {
        state.withLock { $0.events }
    }

    /// Adds `event` at the end of the list.
    ///
    /// - Parameter event: The event that occurred.
    func append(_ event: Event) async {
        record(event)
    }

    /// Adds `event` at the end of the list, and resumes each task whose
    /// condition the events now meet. A caller that cannot wait, such as a
    /// cancellation handler, calls this function.
    ///
    /// - Parameter event: The event that occurred.
    func record(_ event: Event) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.events.append(event)
            let events = state.events
            let met = state.waiters.filter { $0.value.condition(events) }
            for id in met.keys {
                state.waiters.removeValue(forKey: id)
            }
            return met.values.map(\.continuation)
        }
        for continuation in ready {
            continuation.resume()
        }
    }

    /// Waits until the events meet `condition`, or until the task is
    /// cancelled. Returns at once when the events meet it now.
    ///
    /// - Parameter condition: The condition on the events, in append order.
    /// - Returns: The events when the wait ended. The caller reads them to
    ///   know which end came.
    @discardableResult
    func waitUntil(_ condition: @escaping @Sendable ([Event]) -> Bool) async -> [Event] {
        let id = state.withLock { state -> Int in
            defer { state.nextID += 1 }
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let isWaiting = state.withLock { state -> Bool in
                    guard state.cancelled.remove(id) == nil, !condition(state.events) else { return false }
                    state.waiters[id] = Waiter(condition: condition, continuation: continuation)
                    return true
                }
                if !isWaiting {
                    continuation.resume()
                }
            }
        } onCancel: {
            endWait(id: id)
        }
        return recorded
    }

    /// Ends the wait `id` at a cancel, or records the cancel when the wait is
    /// not recorded yet.
    ///
    /// - Parameter id: The id of the wait.
    private func endWait(id: Int) {
        let waiter = state.withLock { state -> Waiter? in
            if let found = state.waiters.removeValue(forKey: id) {
                return found
            }
            state.cancelled.insert(id)
            return nil
        }
        waiter?.continuation.resume()
    }
}
