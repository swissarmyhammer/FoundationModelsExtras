import Synchronization

/// A value that one task gives one time, and that any number of tasks wait for.
///
/// The first ``fulfill(_:)`` wins, and later calls do nothing. The wait is not
/// cancellable, the same as `Task.value`.
final class Promise<Value: Sendable>: Sendable {
    /// The steps of a promise: tasks wait, then the value is there.
    private enum State {
        case waiting([CheckedContinuation<Value, Never>])
        case fulfilled(Value)
    }

    /// The state of the promise.
    private let state = Mutex(State.waiting([]))

    /// Gives `value` to each waiter. Only the first call has an effect.
    ///
    /// - Parameter value: The value.
    func fulfill(_ value: Value) {
        let waiters = state.withLock { state -> [CheckedContinuation<Value, Never>] in
            guard case .waiting(let waiters) = state else { return [] }
            state = .fulfilled(value)
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: value)
        }
    }

    /// The value. Waits until ``fulfill(_:)`` gives it.
    var value: Value {
        get async {
            await withCheckedContinuation { waiter in
                let value = state.withLock { state -> Value? in
                    switch state {
                    case .waiting(let waiters):
                        state = .waiting(waiters + [waiter])
                        return nil
                    case .fulfilled(let value):
                        return value
                    }
                }
                if let value {
                    waiter.resume(returning: value)
                }
            }
        }
    }

    /// The value, or `nil` when ``fulfill(_:)`` did not give it yet. It never
    /// waits.
    var fulfilledValue: Value? {
        state.withLock { state in
            guard case .fulfilled(let value) = state else { return nil }
            return value
        }
    }

    /// The number of tasks that wait for the value.
    var waiterCount: Int {
        state.withLock { state in
            guard case .waiting(let waiters) = state else { return 0 }
            return waiters.count
        }
    }
}
