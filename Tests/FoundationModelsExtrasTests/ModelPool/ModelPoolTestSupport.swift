import Dispatch
@testable import FoundationModelsExtras
import InMemoryTracing
import MetricsTestKit
import Synchronization
import TelemetryTestSupport
import Testing

extension GenerationQueue {
    /// Waits until `count` jobs wait in this queue.
    ///
    /// - Parameter count: The number of waiting jobs.
    /// - Throws: An `ExpectationFailedError` when the jobs did not wait.
    func waitForWaitingJobs(count: Int) async throws {
        try #require(await BoundedWait.conditionReached("\(count) calls wait in the queue") {
            await self.waitingCount == count
        })
    }
}

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
/// finishes. The first `failingLoads` loads then throw `loadError`, and
/// each other load gives the model that `makeModel` makes. An eviction writes
/// `"evict <name of the loader that made the model>"`, then waits until
/// `evictionsMayEnd` finishes. A footprint measure writes `"measure <ref>"`,
/// and gives `measuredBytes`.
struct RecordingLoader: PooledModelLoader {
    /// The name that the log and each model of this loader carry.
    let name: String

    /// The log of the loads and the evictions.
    private let log: Recorder<String>

    /// Makes the model of each load from the name of the loader.
    private let makeModel: @Sendable (_ loaderName: String) -> any Sendable

    /// A load ends only after this stream finishes.
    private let loadsMayEnd: AsyncStream<Void>

    /// An eviction ends only after this stream finishes.
    private let evictionsMayEnd: AsyncStream<Void>

    /// The number of first loads that fail.
    private let failingLoads: Int

    /// The error that each of the first `failingLoads` loads throws.
    private let loadError: any Error

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
    ///   - evictionsMayEnd: An eviction ends only after this stream finishes.
    ///     The default stream is finished, so an eviction ends at once.
    ///   - failingLoads: The number of first loads that fail.
    ///   - loadError: The error that each of the first `failingLoads` loads
    ///     throws. The default is ``FakeLoadError``.
    ///   - measuredBytes: The bytes that each footprint measure gives.
    ///   - failingMeasures: The number of first footprint measures that fail.
    ///   - makeModel: Makes the model of each load from the name of the
    ///     loader. The default makes a new ``FakeModel``.
    init(
        name: String,
        log: Recorder<String>,
        loadsMayEnd: AsyncStream<Void> = AsyncStream { $0.finish() },
        evictionsMayEnd: AsyncStream<Void> = AsyncStream { $0.finish() },
        failingLoads: Int = 0,
        loadError: any Error = FakeLoadError(),
        measuredBytes: Int64 = 0,
        failingMeasures: Int = 0,
        makeModel: @escaping @Sendable (_ loaderName: String) -> any Sendable = { FakeModel(loaderName: $0) }
    ) {
        self.name = name
        self.log = log
        self.makeModel = makeModel
        self.loadsMayEnd = loadsMayEnd
        self.evictionsMayEnd = evictionsMayEnd
        self.failingLoads = failingLoads
        self.loadError = loadError
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
    /// - Returns: The model that `makeModel` makes.
    /// - Throws: `loadError` for each of the first `failingLoads` loads.
    func load(_ key: ModelPoolKey) async throws -> any Sendable {
        let attempt = startedLoads.next()
        log.append("load \(key.ref.stringValue) by \(name)")
        for await _ in loadsMayEnd {}
        if attempt <= failingLoads {
            throw loadError
        }
        return makeModel(name)
    }

    /// Writes the eviction to the log, and waits for `evictionsMayEnd`.
    ///
    /// - Parameter container: The model to evict.
    func evict(_ container: any Sendable) async {
        let owner = (container as? FakeModel)?.loaderName ?? "an unknown model"
        log.append("evict \(owner)")
        for await _ in evictionsMayEnd {}
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

/// Builds the dimensions that the queue metrics carry. Each test suite of a
/// queue uses these helpers, so a change to the dimensions occurs in one place.
enum QueueMetricDimensions {
    /// Gives the dimensions of the depth meter of a queue.
    ///
    /// - Parameter telemetry: The recorder of the queue.
    /// - Returns: The queue name, then the model ref when the queue belongs
    ///   to one model.
    static func queue(of telemetry: QueueTelemetry) -> [(String, String)] {
        queue(named: telemetry.name.rawValue, model: telemetry.model?.stringValue)
    }

    /// Gives the dimensions of the depth meter of a queue, from the values
    /// that a consumer sees. A suite that imports the module with no
    /// `@testable` cannot see `QueueTelemetry`, so it uses this function.
    ///
    /// - Parameters:
    ///   - name: The name of the queue, as its dimension value.
    ///   - model: The model ref of the queue, as its dimension value, or `nil`
    ///     when the queue does not belong to one model.
    /// - Returns: The queue name, then the model ref when `model` is not `nil`.
    static func queue(named name: String, model: String? = nil) -> [(String, String)] {
        let modelDimension = model.map { [(ExtrasTelemetry.DimensionKey.modelRef, $0)] } ?? []
        return [(ExtrasTelemetry.DimensionKey.queueName, name)] + modelDimension
    }

    /// Gives the dimensions of the timers and of the task counter of one
    /// completed job.
    ///
    /// - Parameters:
    ///   - queue: The dimensions of the queue.
    ///   - outcome: The outcome of the job, as its dimension value.
    /// - Returns: The dimensions of the queue, then the outcome.
    static func job(queue: [(String, String)], outcome: String) -> [(String, String)] {
        queue + [(ExtrasTelemetry.DimensionKey.queueOutcome, outcome)]
    }

    /// Gives the dimensions of the timers and of the task counter of one
    /// completed job of the queue that `telemetry` records.
    ///
    /// - Parameters:
    ///   - telemetry: The recorder of the queue.
    ///   - outcome: The outcome of the job.
    /// - Returns: The dimensions of the queue, then the outcome.
    static func job(of telemetry: QueueTelemetry, outcome: QueueOutcome) -> [(String, String)] {
        job(queue: queue(of: telemetry), outcome: outcome.rawValue)
    }
}

/// Reads and checks the queue metrics that a test recorded. Each test suite of
/// a queue uses these helpers, so a change to the checks occurs in one place.
enum QueueMetricExpectations {
    /// The count that one completed job adds to the task counter.
    private static let oneTask: Int64 = 1

    /// The smallest duration that a timer can record, in nanoseconds.
    private static let noTime: Int64 = 0

    /// Expects that `metrics` holds `count` completed jobs of `queue` with
    /// the `queue.outcome` value `outcome`, and no completed job with an other
    /// outcome. Each job records one count, one wait time, and one run time
    /// when `ran` is true.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the queue recorded into.
    ///   - queue: The dimensions of the queue.
    ///   - outcome: The value of the `queue.outcome` dimension.
    ///   - ran: `true` when the jobs started before they completed, thus
    ///     they record a run time.
    ///   - count: The number of completed jobs.
    /// - Throws: When `metrics` has no such timer or counter.
    static func expectCompletedJobs(
        in metrics: TestMetrics, queue: [(String, String)], outcome: String, ran: Bool, count: Int = 1
    ) throws {
        try expectCompletedJobs(in: metrics, queue: queue, [CompletedJobs(outcome: outcome, ran: ran, count: count)])
    }

    /// The completed jobs of one outcome that a test expects.
    struct CompletedJobs {
        /// The value of the `queue.outcome` dimension.
        let outcome: String

        /// `true` when the jobs started before they completed, thus they
        /// record a run time.
        let ran: Bool

        /// The number of completed jobs.
        var count = 1
    }

    /// Expects that `metrics` holds each group of `expected` as completed
    /// jobs of `queue`, and no completed job with an outcome that `expected`
    /// does not name. A test whose queue completes jobs with more than one
    /// outcome calls this function.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the queue recorded into.
    ///   - queue: The dimensions of the queue.
    ///   - expected: The completed jobs of each outcome.
    /// - Throws: When `metrics` has no such timer or counter.
    static func expectCompletedJobs(
        in metrics: TestMetrics, queue: [(String, String)], _ expected: [CompletedJobs]
    ) throws {
        for jobs in expected {
            try expectCompletedJobs(in: metrics, queue: queue, jobs)
        }
        let expectedOutcomes = Set(expected.map(\.outcome))
        for other in QueueOutcome.allCases.map(\.rawValue) where !expectedOutcomes.contains(other) {
            #expect(throws: TestMetricsError.self) {
                try taskCounts(in: metrics, queue: queue, outcome: other)
            }
        }
    }

    /// Expects that `metrics` holds the completed jobs `jobs` of `queue`: one
    /// count, one wait time, and one run time when the jobs ran, for each job.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the queue recorded into.
    ///   - queue: The dimensions of the queue.
    ///   - jobs: The completed jobs of one outcome.
    /// - Throws: When `metrics` has no such timer or counter.
    private static func expectCompletedJobs(
        in metrics: TestMetrics, queue: [(String, String)], _ jobs: CompletedJobs
    ) throws {
        let counts = try taskCounts(in: metrics, queue: queue, outcome: jobs.outcome)
        #expect(counts == Array(repeating: oneTask, count: jobs.count))
        expectDurations(try waitTimes(in: metrics, queue: queue, outcome: jobs.outcome), count: jobs.count)
        if jobs.ran {
            expectDurations(try runTimes(in: metrics, queue: queue, outcome: jobs.outcome), count: jobs.count)
        } else {
            #expect(throws: TestMetricsError.self) {
                try runTimes(in: metrics, queue: queue, outcome: jobs.outcome)
            }
        }
    }

    /// Expects that `metrics` holds `count` completed jobs of `queue` with
    /// `outcome`. A suite that names the outcome as a ``QueueOutcome`` calls
    /// this function.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the queue recorded into.
    ///   - queue: The dimensions of the queue.
    ///   - outcome: The outcome of the jobs.
    ///   - ran: `true` when the jobs started before they completed.
    ///   - count: The number of completed jobs.
    /// - Throws: When `metrics` has no such timer or counter.
    static func expectCompletedJobs(
        in metrics: TestMetrics, queue: [(String, String)], outcome: QueueOutcome, ran: Bool, count: Int = 1
    ) throws {
        try expectCompletedJobs(in: metrics, queue: queue, outcome: outcome.rawValue, ran: ran, count: count)
    }

    /// Gives the values of the depth meter of `queue`.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the queue recorded into.
    ///   - queue: The dimensions of the queue.
    /// - Returns: The depth after each change, in order.
    /// - Throws: When `metrics` has no such meter.
    static func depth(in metrics: TestMetrics, queue: [(String, String)]) throws -> [Double] {
        try metrics.expectMeter(ExtrasTelemetry.MetricName.queueDepth, queue).values
    }

    /// Gives the values of the task counter of the completed jobs of `queue`
    /// with `outcome`.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the queue recorded into.
    ///   - queue: The dimensions of the queue.
    ///   - outcome: The value of the `queue.outcome` dimension.
    /// - Returns: The count that each completed job added, in order.
    /// - Throws: When `metrics` has no such counter.
    static func taskCounts(in metrics: TestMetrics, queue: [(String, String)], outcome: String) throws -> [Int64] {
        try metrics.expectCounter(
            ExtrasTelemetry.MetricName.queueTasks, QueueMetricDimensions.job(queue: queue, outcome: outcome)
        ).values
    }

    /// Gives the wait times of the completed jobs of `queue` with `outcome`.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the queue recorded into.
    ///   - queue: The dimensions of the queue.
    ///   - outcome: The value of the `queue.outcome` dimension.
    /// - Returns: The wait time of each job in nanoseconds, in order.
    /// - Throws: When `metrics` has no such timer.
    static func waitTimes(in metrics: TestMetrics, queue: [(String, String)], outcome: String) throws -> [Int64] {
        try durations(in: metrics, timer: ExtrasTelemetry.MetricName.queueWait, queue: queue, outcome: outcome)
    }

    /// Gives the run times of the completed jobs of `queue` with `outcome`.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the queue recorded into.
    ///   - queue: The dimensions of the queue.
    ///   - outcome: The value of the `queue.outcome` dimension.
    /// - Returns: The run time of each job in nanoseconds, in order.
    /// - Throws: When `metrics` has no such timer.
    static func runTimes(in metrics: TestMetrics, queue: [(String, String)], outcome: String) throws -> [Int64] {
        try durations(in: metrics, timer: ExtrasTelemetry.MetricName.queueRun, queue: queue, outcome: outcome)
    }

    /// Gives the values of the timer `label` of the completed jobs of `queue`
    /// with `outcome`.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the queue recorded into.
    ///   - label: The label of the timer.
    ///   - queue: The dimensions of the queue.
    ///   - outcome: The value of the `queue.outcome` dimension.
    /// - Returns: The durations in nanoseconds, in order.
    /// - Throws: When `metrics` has no such timer.
    private static func durations(
        in metrics: TestMetrics, timer label: String, queue: [(String, String)], outcome: String
    ) throws -> [Int64] {
        try metrics.expectTimer(label, QueueMetricDimensions.job(queue: queue, outcome: outcome)).values
    }

    /// Expects that `durations` holds `count` values, and that no value is
    /// negative.
    ///
    /// - Parameters:
    ///   - durations: The values of one timer, in nanoseconds.
    ///   - count: The number of values.
    static func expectDurations(_ durations: [Int64], count: Int) {
        #expect(durations.count == count)
        #expect(durations.allSatisfy { $0 >= noTime })
    }
}

/// Reads the cache metrics of a model pool that a test recorded. Each test
/// suite of the pool and of its pooled models uses these helpers, so a change
/// to the names or the dimensions occurs in one place.
enum PoolMetricExpectations {
    /// The meter values that agree with one state of a pool.
    struct Gauges: Equatable {
        /// The bytes of the resident models, also the models whose evict
        /// call runs.
        let residentBytes: Double

        /// The bytes of the load that runs.
        let loadingBytes: Double

        /// The bytes of the models whose evict call runs.
        let evictingBytes: Double

        /// The number of resident models.
        let residentModels: Double

        /// Gives the meter values that agree with the footprint and the
        /// resident model count of `pool`.
        ///
        /// - Parameters:
        ///   - pool: The pool.
        ///   - evictingBytes: The bytes of the models whose evict call runs
        ///     now. The public API of the pool does not show them.
        init(of pool: ModelPool, evictingBytes: Int64) {
            let footprint = pool.footprint
            residentBytes = Double(footprint.totalBytes - footprint.loadingBytes)
            loadingBytes = Double(footprint.loadingBytes)
            self.evictingBytes = Double(evictingBytes)
            residentModels = Double(pool.residentModelCount)
        }

        /// Reads the last value of each meter of a pool.
        ///
        /// - Parameter metrics: The factory that the pool recorded into.
        /// - Throws: When `metrics` has no such meter, or a meter has no value.
        init(in metrics: TestMetrics) throws {
            residentBytes = try Self.lastValue(of: ExtrasTelemetry.MetricName.poolResidentBytes, in: metrics)
            loadingBytes = try Self.lastValue(of: ExtrasTelemetry.MetricName.poolLoadingBytes, in: metrics)
            evictingBytes = try Self.lastValue(of: ExtrasTelemetry.MetricName.poolEvictingBytes, in: metrics)
            residentModels = try Self.lastValue(of: ExtrasTelemetry.MetricName.poolResidentModels, in: metrics)
        }

        /// Gives the last value of the meter `label`, which has no dimension.
        ///
        /// - Parameters:
        ///   - label: The label of the meter.
        ///   - metrics: The factory that the pool recorded into.
        /// - Returns: The last value.
        /// - Throws: When `metrics` has no such meter, or the meter has no
        ///   value.
        private static func lastValue(of label: String, in metrics: TestMetrics) throws -> Double {
            try #require(try metrics.expectMeter(label).lastValue)
        }
    }

    /// Expects that the last value of each pool meter in `metrics` agrees
    /// with the footprint and the resident model count of `pool` now.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the pool recorded into.
    ///   - pool: The pool.
    ///   - evictingBytes: The bytes of the models whose evict call runs now.
    /// - Throws: When `metrics` has no such meter, or a meter has no value.
    static func expectGauges(in metrics: TestMetrics, agreeWith pool: ModelPool, evictingBytes: Int64) throws {
        #expect(try Gauges(in: metrics) == Gauges(of: pool, evictingBytes: evictingBytes))
    }

    /// Gives the values of the acquire counter of `ref` with `result`.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the pool recorded into.
    ///   - ref: The model of the acquires.
    ///   - result: How the pool gave the holds.
    /// - Returns: The count that each acquire added, in order.
    /// - Throws: When `metrics` has no such counter.
    static func acquireCounts(in metrics: TestMetrics, ref: ModelRef, result: PoolCacheResult) throws -> [Int64] {
        try metrics.expectCounter(
            ExtrasTelemetry.MetricName.poolAcquires,
            [
                (ExtrasTelemetry.DimensionKey.modelRef, ref.stringValue),
                (ExtrasTelemetry.DimensionKey.cacheResult, result.rawValue),
            ]
        ).values
    }

    /// Gives the values of the eviction counter of the evictions of `ref`
    /// that occurred.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the pool recorded into.
    ///   - ref: The evicted model.
    /// - Returns: The count that each eviction added, in order.
    /// - Throws: When `metrics` has no such counter.
    static func evictionCounts(in metrics: TestMetrics, ref: ModelRef) throws -> [Int64] {
        try metrics.expectCounter(ExtrasTelemetry.MetricName.poolEvictions, modelDimensions(of: ref)).values
    }

    /// Gives the values of the eviction counter of the eviction jobs of `ref`
    /// that evicted nothing for `reason`.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the pool recorded into.
    ///   - ref: The model of the eviction jobs.
    ///   - reason: Why the jobs evicted nothing.
    /// - Returns: The count that each job added, in order.
    /// - Throws: When `metrics` has no such counter.
    static func skippedEvictionCounts(
        in metrics: TestMetrics, ref: ModelRef, reason: PoolEvictionSkipReason
    ) throws -> [Int64] {
        try metrics.expectCounter(
            ExtrasTelemetry.MetricName.poolEvictions,
            modelDimensions(of: ref) + [(ExtrasTelemetry.DimensionKey.evictionReason, reason.rawValue)]
        ).values
    }

    /// Gives the values of the idle-to-evict timer of `ref`.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the pool recorded into.
    ///   - ref: The evicted model.
    /// - Returns: The idle time of each eviction in nanoseconds, in order.
    /// - Throws: When `metrics` has no such timer.
    static func idleToEvictTimes(in metrics: TestMetrics, ref: ModelRef) throws -> [Int64] {
        try metrics.expectTimer(ExtrasTelemetry.MetricName.poolIdleToEvict, modelDimensions(of: ref)).values
    }

    /// Gives the values of the load-join counter.
    ///
    /// - Parameter metrics: The factory that the pooled model recorded into.
    /// - Returns: The count that each joining caller added, in order.
    /// - Throws: When `metrics` has no such counter.
    static func loadJoins(in metrics: TestMetrics) throws -> [Int64] {
        try metrics.expectCounter(ExtrasTelemetry.MetricName.poolLoadJoins).values
    }

    /// Gives the dimensions of a pool metric of one model.
    ///
    /// - Parameter ref: The model.
    /// - Returns: The model ref as its only dimension.
    private static func modelDimensions(of ref: ModelRef) -> [(String, String)] {
        [(ExtrasTelemetry.DimensionKey.modelRef, ref.stringValue)]
    }
}

/// Reads the model load telemetry that a test recorded: the load span and
/// its phase spans, the load timer, the evict timer and the footprint
/// recorder. Each test suite of the pool and of the MLX loader uses these
/// helpers, so a change to the names or the dimensions occurs in one place.
enum ModelLoadTelemetryExpectations {
    /// Gives the spans of `spans` that have the name `spanName`.
    ///
    /// - Parameters:
    ///   - spanName: The name of the spans to find.
    ///   - spans: The spans that a tracer recorded.
    /// - Returns: The spans with that name, in the order of `spans`.
    static func spans(named spanName: String, in spans: [FinishedInMemorySpan]) -> [FinishedInMemorySpan] {
        spans.filter { $0.operationName == spanName }
    }

    /// Expects that `span` carries the model ref, the revision and the role
    /// of `key`. A key that names no revision has the revision that the MLX
    /// loader loads.
    ///
    /// - Parameters:
    ///   - span: A load span.
    ///   - key: The loaded model.
    static func expectLoadAttributes(of span: FinishedInMemorySpan, key: ModelPoolKey) {
        let revision = MLXModelLoader.revision(of: key)
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.modelRef) == .string(key.ref.stringValue))
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.modelRevision) == .string(revision))
        #expect(
            span.attributes.get(ExtrasTelemetry.AttributeKey.modelRole)
                == .string(ExtrasTelemetry.telemetryRole(of: key.role)))
    }

    /// Gives the values of the load timer of `key` with `outcome`.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the pool recorded into.
    ///   - key: The loaded model.
    ///   - outcome: How the loads ended.
    /// - Returns: The duration of each load in nanoseconds, in order.
    /// - Throws: When `metrics` has no such timer.
    static func loadDurations(
        in metrics: TestMetrics, key: ModelPoolKey, outcome: ModelOperationOutcome
    ) throws -> [Int64] {
        try durations(on: ExtrasTelemetry.MetricName.modelLoadDuration, in: metrics, key: key, outcome: outcome)
    }

    /// Gives the values of the evict timer of `key` with `outcome`.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the pool recorded into.
    ///   - key: The evicted model.
    ///   - outcome: How the evictions ended.
    /// - Returns: The duration of each eviction in nanoseconds, in order.
    /// - Throws: When `metrics` has no such timer.
    static func evictDurations(
        in metrics: TestMetrics, key: ModelPoolKey, outcome: ModelOperationOutcome
    ) throws -> [Int64] {
        try durations(on: ExtrasTelemetry.MetricName.modelEvictDuration, in: metrics, key: key, outcome: outcome)
    }

    /// Gives the values of the model timer `label` of `key` with `outcome`.
    ///
    /// - Parameters:
    ///   - label: The label of the timer.
    ///   - metrics: The factory that the pool recorded into.
    ///   - key: The model.
    ///   - outcome: How the operations ended.
    /// - Returns: The duration of each operation in nanoseconds, in order.
    /// - Throws: When `metrics` has no such timer.
    private static func durations(
        on label: String, in metrics: TestMetrics, key: ModelPoolKey, outcome: ModelOperationOutcome
    ) throws -> [Int64] {
        try metrics.expectTimer(
            label, modelDimensions(of: key) + [(ExtrasTelemetry.DimensionKey.modelOutcome, outcome.rawValue)]
        ).values
    }

    /// Gives the values of the footprint recorder of `key`.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the pool recorded into.
    ///   - key: The measured model.
    /// - Returns: The bytes of each measure, in order.
    /// - Throws: When `metrics` has no such recorder.
    static func footprintBytes(in metrics: TestMetrics, key: ModelPoolKey) throws -> [Double] {
        try metrics.expectRecorder(ExtrasTelemetry.MetricName.modelFootprintBytes, modelDimensions(of: key)).values
    }

    /// Gives the dimensions of a model metric of one key.
    ///
    /// - Parameter key: The model and its role.
    /// - Returns: The model ref, then the role.
    private static func modelDimensions(of key: ModelPoolKey) -> [(String, String)] {
        [
            (ExtrasTelemetry.DimensionKey.modelRef, key.ref.stringValue),
            (ExtrasTelemetry.DimensionKey.modelRole, ExtrasTelemetry.telemetryRole(of: key.role)),
        ]
    }
}

/// An embedding model that runs each call through
/// ``EmbedTelemetry/traceEmbed(of:texts:tokenBudget:tokenize:vectors:)`` with
/// a fake tokenizer and a fake model, thus a call records the embed telemetry
/// with no MLX model.
///
/// The tokenizer gives one token for each Unicode scalar of a text, thus the
/// token count of a text is the count of its scalars. The model gives one
/// vector for each row: the token count of the row.
struct TracedFakeEmbedding: PooledEmbedding {
    /// The model of the telemetry of each call.
    let ref: ModelRef

    /// The token budget of the division of each call.
    var tokenBudget = EmbeddingBatchDivision.defaultTokenBudget

    /// Gives one token for each Unicode scalar of `text`: the value of the
    /// scalar.
    ///
    /// - Parameter text: A text of a call.
    /// - Returns: The tokens of the text.
    static func tokens(of text: String) -> [Int] {
        text.unicodeScalars.map { Int($0.value) }
    }

    /// Gives the vector of a token row: its token count.
    ///
    /// - Parameter row: The tokens of one text.
    /// - Returns: A vector of one value.
    static func vector(ofRow row: [Int]) -> [Float] {
        [Float(row.count)]
    }

    /// Gives the vector of a text: its token count.
    ///
    /// - Parameter text: A text of a call.
    /// - Returns: A vector of one value.
    static func vector(of text: String) -> [Float] {
        vector(ofRow: tokens(of: text))
    }

    /// Gives the division of the rows of `texts`, as a call divides them.
    ///
    /// - Parameter texts: The texts of a call.
    /// - Returns: The division of the tokens of the texts by ``tokenBudget``.
    func division(of texts: [String]) -> EmbeddingBatchDivision {
        EmbeddingBatchDivision(rows: texts.map(Self.tokens(of:)), tokenBudget: tokenBudget)
    }

    /// Runs the embed telemetry with the fake tokenizer and the fake model.
    ///
    /// - Parameter texts: The texts.
    /// - Returns: The vector of each text, from ``vector(of:)``.
    /// - Throws: The error of the telemetry helper.
    func embed(texts: [String]) async throws -> [[Float]] {
        try await EmbedTelemetry.traceEmbed(
            of: ref, texts: texts, tokenBudget: tokenBudget, tokenize: Self.tokens(of:),
            vectors: { rows in rows.map(Self.vector(ofRow:)) })
    }
}

/// Reads the embed telemetry that a test recorded: the embed span, its
/// tokenize span and its sub-batch spans, the duration timer, the token
/// counter and the padded-tokens recorder. Each test suite of the embed
/// telemetry and of the pooled embedder uses these helpers, so a change to
/// the names or the dimensions occurs in one place.
enum EmbedTelemetryExpectations {
    /// Expects that `span` carries the model ref and the counts of the call
    /// of `statistics`.
    ///
    /// - Parameters:
    ///   - span: An embed span.
    ///   - ref: The model of the call.
    ///   - statistics: The counts of the call.
    static func expectCallAttributes(
        of span: FinishedInMemorySpan, ref: ModelRef, statistics: EmbeddingBatchStatistics
    ) {
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.modelRef) == .string(ref.stringValue))
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.embedTextCount) == .int64(Int64(statistics.textCount)))
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.embedTokenCount) == .int64(Int64(statistics.tokenCount)))
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.embedMaxTokens) == .int64(Int64(statistics.maxTokens)))
        #expect(
            span.attributes.get(ExtrasTelemetry.AttributeKey.embedSubBatchCount)
                == .int64(Int64(statistics.subBatchCount)))
        #expect(
            span.attributes.get(ExtrasTelemetry.AttributeKey.embedOverBudgetRows)
                == .int64(Int64(statistics.overBudgetRows)))
    }

    /// Expects that `span` carries the counts of `subBatch`.
    ///
    /// - Parameters:
    ///   - span: A sub-batch span.
    ///   - subBatch: The counts of the sub-batch.
    static func expectSubBatchAttributes(of span: FinishedInMemorySpan, _ subBatch: EmbeddingBatchStatistics.SubBatch) {
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.subBatchRows) == .int64(Int64(subBatch.rows)))
        #expect(
            span.attributes.get(ExtrasTelemetry.AttributeKey.subBatchLongestRow) == .int64(Int64(subBatch.longestRow)))
        #expect(
            span.attributes.get(ExtrasTelemetry.AttributeKey.subBatchPaddedTokens)
                == .int64(Int64(subBatch.paddedTokens)))
        #expect(span.attributes.get(ExtrasTelemetry.AttributeKey.subBatchPadRatio) == .double(subBatch.padRatio))
    }

    /// Gives the spans of `spans` with the name `spanName` whose parent is
    /// `parent`.
    ///
    /// - Parameters:
    ///   - spanName: The name of the child spans.
    ///   - parent: The parent span.
    ///   - spans: The spans that a tracer recorded.
    /// - Returns: The child spans, in the order of `spans`.
    static func children(
        named spanName: String, of parent: FinishedInMemorySpan, in spans: [FinishedInMemorySpan]
    ) -> [FinishedInMemorySpan] {
        ModelLoadTelemetryExpectations.spans(named: spanName, in: spans).filter { $0.parentSpanID == parent.spanID }
    }

    /// Gives the values of the duration timer of `ref`.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the call recorded into.
    ///   - ref: The model of the calls.
    /// - Returns: The duration of each call in nanoseconds, in order.
    /// - Throws: When `metrics` has no such timer.
    static func durations(in metrics: TestMetrics, ref: ModelRef) throws -> [Int64] {
        try metrics.expectTimer(ExtrasTelemetry.MetricName.embedDuration, modelDimensions(of: ref)).values
    }

    /// Gives the values of the token counter of `ref`.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the call recorded into.
    ///   - ref: The model of the calls.
    /// - Returns: The token count that each call added, in order.
    /// - Throws: When `metrics` has no such counter.
    static func tokenCounts(in metrics: TestMetrics, ref: ModelRef) throws -> [Int64] {
        try metrics.expectCounter(ExtrasTelemetry.MetricName.embedTokens, modelDimensions(of: ref)).values
    }

    /// Gives the values of the padded-tokens recorder of `ref`.
    ///
    /// - Parameters:
    ///   - metrics: The factory that the call recorded into.
    ///   - ref: The model of the calls.
    /// - Returns: The padded tokens of each sub-batch, in order.
    /// - Throws: When `metrics` has no such recorder.
    static func paddedTokens(in metrics: TestMetrics, ref: ModelRef) throws -> [Double] {
        try metrics.expectRecorder(ExtrasTelemetry.MetricName.embedSubBatchPaddedTokens, modelDimensions(of: ref))
            .values
    }

    /// Gives the dimensions of an embed metric.
    ///
    /// - Parameter ref: The model of the call.
    /// - Returns: The model ref as its only dimension.
    private static func modelDimensions(of ref: ModelRef) -> [(String, String)] {
        [(ExtrasTelemetry.DimensionKey.modelRef, ref.stringValue)]
    }
}

extension TelemetryCapture.Context {
    /// The log records of the capture at the error level, in order.
    var errorRecords: [TelemetryCapture.LogRecord] {
        logRecords.filter { $0.level == .error }
    }

    /// Waits until the capture holds an error record. A task that the code
    /// under test starts, for example the task of a prewarm, writes its
    /// record later than the call that started it returns.
    ///
    /// - Returns: The error records of the capture, in order.
    /// - Throws: An `ExpectationFailedError` when no error record came.
    func waitForErrorRecords() async throws -> [TelemetryCapture.LogRecord] {
        try #require(await BoundedWait.conditionReached("an error record comes") { !self.errorRecords.isEmpty })
        return errorRecords
    }
}
