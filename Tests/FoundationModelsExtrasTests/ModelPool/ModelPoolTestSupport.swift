import Dispatch
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

/// The error of a footprint measure that a ``RecordingLoader`` makes fail.
struct FakeMeasureError: Error {}

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

/// Counts the calls that tasks start. Each copy of a fake that keeps a counter
/// shares the same count, so the counter is a class.
final class Counter: Sendable {
    /// The number of calls that started.
    private let count = Mutex(0)

    /// Adds one to the count.
    ///
    /// - Returns: The count after the addition. The first call gives 1.
    func next() -> Int {
        count.withLock { count in
            count += 1
            return count
        }
    }
}

/// A loader that writes each load and each eviction to a log.
///
/// A load writes `"load <ref> by <name>"`, then waits until `loadsMayEnd`
/// finishes. The first `failingLoads` loads then throw ``FakeLoadError``. An
/// eviction writes `"evict <name of the loader that made the model>"`. A
/// footprint measure writes `"measure <ref>"`, and gives `measuredBytes`.
struct RecordingLoader: PooledModelLoader {
    /// The name that the log and each model of this loader carry.
    let name: String

    /// The log of the loads and the evictions.
    private let log: Recorder<String>

    /// A load ends only after this stream finishes.
    private let loadsMayEnd: AsyncStream<Void>

    /// The number of first loads that fail.
    private let failingLoads: Int

    /// The bytes that each footprint measure gives.
    private let measuredBytes: Int64

    /// The number of first footprint measures that fail.
    private let failingMeasures: Int

    /// The number of loads that started.
    private let startedLoads = Counter()

    /// The number of footprint measures that started.
    private let startedMeasures = Counter()

    /// Makes a loader.
    ///
    /// - Parameters:
    ///   - name: The name that the log and each model carry.
    ///   - log: The log of the loads and the evictions.
    ///   - loadsMayEnd: A load ends only after this stream finishes. The
    ///     default stream is finished, so a load ends at once.
    ///   - failingLoads: The number of first loads that fail.
    ///   - measuredBytes: The bytes that each footprint measure gives.
    ///   - failingMeasures: The number of first footprint measures that fail.
    init(
        name: String,
        log: Recorder<String>,
        loadsMayEnd: AsyncStream<Void> = AsyncStream { $0.finish() },
        failingLoads: Int = 0,
        measuredBytes: Int64 = 0,
        failingMeasures: Int = 0
    ) {
        self.name = name
        self.log = log
        self.loadsMayEnd = loadsMayEnd
        self.failingLoads = failingLoads
        self.measuredBytes = measuredBytes
        self.failingMeasures = failingMeasures
    }

    /// Writes the measure to the log, and gives the bytes of the loader or
    /// fails.
    ///
    /// - Parameter key: The key to measure.
    /// - Returns: The bytes that the loader was made with.
    /// - Throws: ``FakeMeasureError`` for each of the first `failingMeasures`
    ///   measures.
    func footprintBytes(of key: ModelPoolKey) async throws -> Int64 {
        let attempt = startedMeasures.next()
        log.append("measure \(key.ref.stringValue)")
        if attempt <= failingMeasures {
            throw FakeMeasureError()
        }
        return measuredBytes
    }

    /// Writes the load to the log, waits for `loadsMayEnd`, and makes a model
    /// or fails.
    ///
    /// - Parameter key: The key to load.
    /// - Returns: A new ``FakeModel``.
    /// - Throws: ``FakeLoadError`` for each of the first `failingLoads` loads.
    func load(_ key: ModelPoolKey) async throws -> any Sendable {
        let attempt = startedLoads.next()
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

/// An embedding model that gives one fixed vector for each text, and writes
/// each call to a log.
///
/// A call writes `"begin <texts>"` and then `"end <texts>"`. The first call
/// waits between the two writes until `firstCallMayEnd` finishes, and then
/// throws `CancellationError` when its task is cancelled.
struct FakeEmbedding: PooledEmbedding {
    /// The vector of each text.
    let vector: [Float]

    /// The log of the calls.
    private let log: Recorder<String>

    /// The first call ends only after this stream finishes.
    private let firstCallMayEnd: AsyncStream<Void>

    /// The number of calls that started.
    private let startedCalls = Counter()

    /// The length of ``vector``.
    var dimension: Int { vector.count }

    /// Makes a model.
    ///
    /// - Parameters:
    ///   - vector: The vector of each text.
    ///   - log: The log of the calls.
    ///   - firstCallMayEnd: The first call ends only after this stream
    ///     finishes. The default stream is finished, so the first call ends at once.
    init(vector: [Float], log: Recorder<String>, firstCallMayEnd: AsyncStream<Void> = AsyncStream { $0.finish() }) {
        self.vector = vector
        self.log = log
        self.firstCallMayEnd = firstCallMayEnd
    }

    /// Writes the call to the log, and gives ``vector`` for each text.
    ///
    /// - Parameter texts: The texts.
    /// - Returns: One copy of ``vector`` for each text.
    /// - Throws: `CancellationError` when the task is cancelled.
    func embed(texts: [String]) async throws -> [[Float]] {
        let call = startedCalls.next()
        let name = texts.joined(separator: " ")
        log.append("begin \(name)")
        if call == 1 {
            for await _ in firstCallMayEnd {}
        }
        try Task.checkCancellation()
        log.append("end \(name)")
        return texts.map { _ in vector }
    }
}

/// A task executor that runs each job on a dispatch queue of its own, not on
/// the cooperative thread pool.
///
/// A deadlock blocks the threads of the tasks that it stops. When those tasks
/// run on the cooperative pool, the deadlock can block all its threads, and
/// then a ``BoundedWait`` never runs again and the test hangs. A task with a
/// preference for this executor blocks a thread of this queue, so a bounded
/// wait on the cooperative pool still ends and fails the test.
final class DedicatedTaskExecutor: TaskExecutor {
    /// The queue that runs the jobs.
    private let queue = DispatchQueue(label: "DedicatedTaskExecutor", attributes: .concurrent)

    /// Runs `job` on the queue.
    ///
    /// - Parameter job: The job to run.
    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async { unownedJob.runSynchronously(on: executor) }
    }
}

/// A loader that gives one container that the test makes. Its eviction does nothing.
struct FixedLoader: PooledModelLoader {
    /// The container that each load gives.
    let container: any Sendable

    /// Gives ``container``.
    ///
    /// - Parameter key: The key to load.
    /// - Returns: ``container``.
    func load(_ key: ModelPoolKey) async throws -> any Sendable { container }

    /// Does nothing.
    ///
    /// - Parameter container: The container to evict.
    func evict(_ container: any Sendable) async {}
}
