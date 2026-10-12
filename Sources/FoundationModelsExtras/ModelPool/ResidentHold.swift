import Synchronization

/// The one hold of a pooled model made from a name, which all copies of that
/// model share. The first call to ``loaded()`` acquires the model, one time
/// only, also when first calls run at the same time. The hold goes when the
/// last copy goes.
final class ResidentHold<Loaded: Sendable>: Sendable {
    /// Acquires the model from its pool.
    typealias Load = @Sendable () async throws -> Loaded

    /// The steps of the hold: no load yet, one load that runs, or the hold.
    private enum State {
        /// No hold. The next call loads.
        case unloaded(Load)
        /// A load runs. Each call waits for it. When it fails, the state goes
        /// back to `unloaded` with the same load.
        case loading(Load, Task<Loaded, any Error>)
        /// The hold.
        case loaded(Loaded)
    }

    /// What a call does after it reads the state.
    private enum Access {
        /// Use the hold.
        case ready(Loaded)
        /// Wait for the load that this call started.
        case started(Task<Loaded, any Error>)
        /// Wait for the load that another call started.
        case joined(Task<Loaded, any Error>)
    }

    /// The state, under one lock.
    private let state: Mutex<State>

    /// Makes a hold that calls `load` on the first call.
    ///
    /// - Parameter load: Acquires the model from its pool.
    init(load: @escaping Load) {
        state = Mutex(.unloaded(load))
    }

    /// Makes a hold that has its model already.
    ///
    /// - Parameter loaded: The hold of the model.
    init(loaded: Loaded) {
        state = Mutex(.loaded(loaded))
    }

    /// Gives the hold. The first call starts the load, and each call waits
    /// for that one load. The wait is not cancellable, the same as
    /// `Task.value`.
    ///
    /// Each call that waits for a load that another call started adds one
    /// count to ``ExtrasTelemetry/MetricName/poolLoadJoins``, after the lock.
    ///
    /// - Returns: The hold of the model.
    /// - Throws: The error of the load. After a failed load, the next call
    ///   loads again.
    func loaded() async throws -> Loaded {
        try await loadedReportingWait().loaded
    }

    /// Gives the hold, and tells whether this call waited for a load. The
    /// first call starts the load, and each call waits for that one load, as
    /// in ``loaded()``.
    ///
    /// - Returns: The hold of the model, and `true` when this call started
    ///   the load or joined the load that another call started. A call that
    ///   found the hold gives `false`.
    /// - Throws: The error of the load. After a failed load, the next call
    ///   loads again.
    func loadedReportingWait() async throws -> (loaded: Loaded, waitedForLoad: Bool) {
        switch state.withLock({ Self.access(state: &$0) }) {
        case .ready(let loaded):
            return (loaded, false)
        case .started(let task):
            return (try await finish(load: task), true)
        case .joined(let task):
            PoolTelemetry.recordLoadJoin()
            return (try await finish(load: task), true)
        }
    }

    /// Reads `state`, and starts the load when there is no hold and no load.
    ///
    /// - Parameter state: The state of the hold.
    /// - Returns: The hold, the load that this call started, or the load
    ///   that another call started.
    private static func access(state: inout State) -> Access {
        switch state {
        case .loaded(let loaded):
            return .ready(loaded)
        case .loading(_, let task):
            return .joined(task)
        case .unloaded(let load):
            let task = Task { try await load() }
            state = .loading(load, task)
            return .started(task)
        }
    }

    /// Waits for `task`, and keeps its result when `task` is still the load
    /// of the state.
    ///
    /// - Parameter task: The load that the state holds, or held.
    /// - Returns: The hold of the model.
    /// - Throws: The error of `task`.
    private func finish(load task: Task<Loaded, any Error>) async throws -> Loaded {
        let result = await task.result
        state.withLock { state in
            guard case .loading(let load, let currentTask) = state, currentTask == task else { return }
            switch result {
            case .success(let loaded):
                state = .loaded(loaded)
            case .failure:
                state = .unloaded(load)
            }
        }
        return try result.get()
    }
}
