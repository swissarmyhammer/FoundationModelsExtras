import FoundationModelsExtras

/// An `MLXModelLoader` that records each load that ends.
///
/// A test counts the loads of a pool with it.
struct RecordingLoader: PooledModelLoader {
    /// The model of each load that ended, in the order in which the loads
    /// ended.
    private let loads = EventLog<ModelPoolKey>()

    /// The loader that does the real work.
    private let loader = MLXModelLoader()

    /// The model of each completed load, in the order in which the loads
    /// ended.
    var loadedKeys: [ModelPoolKey] {
        get async { await loads.events }
    }

    /// Loads the model of `key` with `MLXModelLoader`, and records the end of
    /// the load.
    ///
    /// - Parameter key: The model and its role.
    /// - Returns: The loaded container.
    /// - Throws: The error of the load. A failed load records nothing.
    func load(_ key: ModelPoolKey) async throws -> any Sendable {
        let container = try await loader.load(key)
        await loads.append(key)
        return container
    }

    /// Evicts the container with `MLXModelLoader`.
    ///
    /// - Parameter container: A container that ``load(_:)`` returned.
    func evict(_ container: any Sendable) async {
        await loader.evict(container)
    }
}
