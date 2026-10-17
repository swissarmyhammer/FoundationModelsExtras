import FoundationModelsExtras

/// One step that a pool test records, in the order of the steps.
///
/// A ``RecordingLoader`` writes the start and the end of each load, and the
/// test writes its own steps into the same log. Thus the order of the log
/// shows which step came first, and the test reads no clock.
enum PoolStep: Equatable, Sendable {
    /// The pool called the loader for the model.
    case loadStarted(ModelPoolKey)
    /// The loader returned the container of the model.
    case loadEnded(ModelPoolKey)
    /// A step of the test itself, by name.
    case test(String)
}

/// An `MLXModelLoader` that records the start and the end of each load.
///
/// A test counts the loads, and compares the order of the loads with the
/// order of its own steps.
struct RecordingLoader: PooledModelLoader {
    /// The steps of the loads, and of the test when it shares this log.
    let steps: EventLog<PoolStep>

    /// The loader that does the real work.
    private let loader = MLXModelLoader()

    /// Makes a loader that records into `steps`.
    ///
    /// - Parameter steps: The log of the steps. The default is a new log.
    init(steps: EventLog<PoolStep> = EventLog()) {
        self.steps = steps
    }

    /// The model of each completed load, in the order in which the loads
    /// ended.
    var loadedKeys: [ModelPoolKey] {
        get async {
            await steps.events.compactMap { step in
                guard case .loadEnded(let key) = step else { return nil }
                return key
            }
        }
    }

    /// Loads the model of `key` with `MLXModelLoader`, and records the start
    /// and the end of the load.
    ///
    /// - Parameter key: The model and its role.
    /// - Returns: The loaded container.
    /// - Throws: The error of the load. A failed load records no end.
    func load(_ key: ModelPoolKey) async throws -> any Sendable {
        await steps.append(.loadStarted(key))
        let container = try await loader.load(key)
        await steps.append(.loadEnded(key))
        return container
    }

    /// Evicts the container with `MLXModelLoader`.
    ///
    /// - Parameter container: A container that ``load(_:)`` returned.
    func evict(_ container: any Sendable) async {
        await loader.evict(container)
    }
}
