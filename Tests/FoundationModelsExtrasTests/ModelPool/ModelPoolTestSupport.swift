@testable import FoundationModelsExtras
import Synchronization

/// The model that a ``RecordingLoader`` makes. A test compares two models by
/// identity.
final class FakeModel: Sendable {
    /// The name of the loader that made this model.
    let loaderName: String

    /// Makes the model of the loader `loaderName`.
    ///
    /// - Parameter loaderName: The name of the loader.
    init(loaderName: String) {
        self.loaderName = loaderName
    }
}

/// The error of a load that a ``RecordingLoader`` makes fail.
struct FakeLoadError: Error {}

/// Keeps the values that tasks append, in the order of the appends.
final class Recorder<Value: Sendable>: Sendable {
    /// The values, in order.
    private let stored = Mutex<[Value]>([])

    /// The values, in order.
    var values: [Value] { stored.withLock { $0 } }

    /// Appends `value`.
    ///
    /// - Parameter value: The value to keep.
    func append(_ value: Value) {
        stored.withLock { $0.append(value) }
    }
}

/// A loader that writes each load and each eviction to a log.
///
/// A load writes `"load <ref> by <name>"`, then waits until `loadsMayEnd`
/// finishes. The first `failingLoads` loads then throw ``FakeLoadError``. An
/// eviction writes `"evict <name of the loader that made the model>"`.
final class RecordingLoader: PooledModelLoader {
    /// The name that the log and each model of this loader carry.
    let name: String

    /// The log of the loads and the evictions.
    private let log: Recorder<String>

    /// A load ends only after this stream finishes.
    private let loadsMayEnd: AsyncStream<Void>

    /// The number of first loads that fail.
    private let failingLoads: Int

    /// The number of loads that started.
    private let startedLoads = Mutex(0)

    /// Makes a loader.
    ///
    /// - Parameters:
    ///   - name: The name that the log and each model carry.
    ///   - log: The log of the loads and the evictions.
    ///   - loadsMayEnd: A load ends only after this stream finishes. The
    ///     default stream is finished, so a load ends at once.
    ///   - failingLoads: The number of first loads that fail.
    init(
        name: String,
        log: Recorder<String>,
        loadsMayEnd: AsyncStream<Void> = AsyncStream { $0.finish() },
        failingLoads: Int = 0
    ) {
        self.name = name
        self.log = log
        self.loadsMayEnd = loadsMayEnd
        self.failingLoads = failingLoads
    }

    /// Writes the load to the log, waits for `loadsMayEnd`, and makes a model
    /// or fails.
    ///
    /// - Parameter key: The key to load.
    /// - Returns: A new ``FakeModel``.
    /// - Throws: ``FakeLoadError`` for each of the first `failingLoads` loads.
    func load(_ key: ModelPoolKey) async throws -> any Sendable {
        let attempt = startedLoads.withLock { count in
            count += 1
            return count
        }
        log.append("load \(key.ref.stringValue) by \(name)")
        for await _ in loadsMayEnd {}
        if attempt <= failingLoads {
            throw FakeLoadError()
        }
        return FakeModel(loaderName: name)
    }

    /// Writes the eviction to the log.
    ///
    /// - Parameter container: The model to evict.
    func evict(_ container: any Sendable) async {
        let owner = (container as? FakeModel)?.loaderName ?? "an unknown model"
        log.append("evict \(owner)")
    }
}
