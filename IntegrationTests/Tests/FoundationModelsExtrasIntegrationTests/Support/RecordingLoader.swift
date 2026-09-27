import FoundationModelsExtras

/// A ``MLXPooledLoader`` that records each load that it completes.
///
/// A test counts the loads, and compares the start and the end of a load with
/// the times of other events.
struct RecordingLoader: PooledModelLoader {
    /// One completed load.
    struct Load: Sendable {
        /// The model that loaded.
        let key: ModelPoolKey
        /// The time when the pool called ``load(_:)``.
        let start: ContinuousClock.Instant
        /// The time when the load returned the container.
        let end: ContinuousClock.Instant
    }

    /// The completed loads, in the order in which they ended.
    let loads = EventLog<Load>()

    /// The loader that does the real work.
    private let loader = MLXPooledLoader()

    /// Loads the model of `key` with ``MLXPooledLoader``, and records the load.
    ///
    /// - Parameter key: The model and its role.
    /// - Returns: The loaded container.
    /// - Throws: The error of the load. A failed load is not recorded.
    func load(_ key: ModelPoolKey) async throws -> any Sendable {
        let start = ContinuousClock.now
        let container = try await loader.load(key)
        await loads.append(Load(key: key, start: start, end: .now))
        return container
    }

    /// Evicts the container with ``MLXPooledLoader``.
    ///
    /// - Parameter container: A container that ``load(_:)`` returned.
    func evict(_ container: any Sendable) async {
        await loader.evict(container)
    }
}
