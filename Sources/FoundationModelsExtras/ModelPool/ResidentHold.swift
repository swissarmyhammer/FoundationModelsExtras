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
        /// Wait for the load that runs.
        case waiting(Task<Loaded, any Error>)
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
    /// - Returns: The hold of the model.
    /// - Throws: The error of the load. After a failed load, the next call
    ///   loads again.
    func loaded() async throws -> Loaded {
        switch state.withLock({ Self.access(state: &$0) }) {
        case .ready(let loaded):
            return loaded
        case .waiting(let load):
            return try await finish(load: load)
        }
    }

    /// Reads `state`, and starts the load when there is no hold and no load.
    ///
    /// - Parameter state: The state of the hold.
    /// - Returns: The hold, or the load to wait for.
    private static func access(state: inout State) -> Access {
        switch state {
        case .loaded(let loaded):
            return .ready(loaded)
        case .loading(_, let task):
            return .waiting(task)
        case .unloaded(let load):
            let task = Task { try await load() }
            state = .loading(load, task)
            return .waiting(task)
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
            guard case .loading(let load, let current) = state, current == task else { return }
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
