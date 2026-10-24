import FoundationModels
@testable import FoundationModelsExtras
import Logging
import Metrics
import MetricsTestKit
import Synchronization
import TelemetryTestSupport
import Testing

/// The model pool loads each model one time, shares it through holds, and
/// runs each load and each eviction as one job in its admission queue.
///
/// The import is `@testable`, so a test can read how many jobs wait in the
/// admission queue. Then a test knows that a job waits before it acts.
@Suite("Model pool: one load for each model, holds that release in deinit, one admission queue")
struct ModelPoolTests {
    /// The key that most tests acquire.
    private static let key = ModelPoolKey(ref: "org/a", role: .llm)

    /// The log line of one load of ``key`` by the loader `A`.
    private static let loadByA = "load org/a by A"

    /// The log line of an eviction of the model of the loader `A`.
    private static let evictionOfA = "evict A"

    /// The log line of one footprint measure of ``key``.
    private static let measureOfKey = "measure org/a"

    /// The bytes of ``key`` for its first hold: the weights and one session.
    private static let footprintBytes: Int64 = 10

    /// The bytes of one session of the first hold.
    private static let sessionBytes: Int64 = 2

    /// The bytes of one session of a second hold.
    private static let secondSessionBytes: Int64 = 3

    /// The bytes of the weights of ``key``.
    private static let weightsBytes = footprintBytes - sessionBytes

    /// How many times the release test releases the last hold and then
    /// submits an admit job at once.
    private static let releaseRepetitions = 200

    /// The number of rounds of the churn test. Each round starts and cancels
    /// one footprint stream, and acquires and releases one hold.
    private static let churnRounds = 20

    /// The depth records of the admission queue while one job runs and no
    /// other job came: the record of its enqueue.
    private static let recordsOfOneRunningJob = 1

    /// The key that the admit job of the load order test loads.
    private static let jobKey = ModelPoolKey(ref: "org/job", role: .llm)

    /// The log line of the load of ``jobKey`` by the loader `A`.
    private static let loadOfJobKey = "load org/job by A"

    /// The first footprints of the load order test: the admit job loads
    /// ``jobKey``, and only then the queued acquire loads ``key``.
    private static let oneLoadAtATime = [
        ModelPoolFootprint(resident: [:], loadingBytes: 0),
        ModelPoolFootprint(resident: [:], loadingBytes: footprintBytes),
        ModelPoolFootprint(resident: [jobKey: footprintBytes], loadingBytes: 0),
        ModelPoolFootprint(resident: [jobKey: footprintBytes], loadingBytes: footprintBytes),
        ModelPoolFootprint(resident: [jobKey: footprintBytes, key: footprintBytes], loadingBytes: 0),
    ]

    /// How many times the order test releases two holds at the same time.
    private static let orderRepetitions = 100

    /// The footprints that one stream sees in the order test: the first value
    /// with two holds, the value after each release in one of the two orders,
    /// and the value after the eviction.
    private static let releaseOrders: [[ModelPoolFootprint]] = {
        let bothHolds = footprintBytes + secondSessionBytes
        let resident = { (bytes: Int64) in ModelPoolFootprint(resident: [key: bytes], loadingBytes: 0) }
        let evicted = ModelPoolFootprint(resident: [:], loadingBytes: 0)
        return [
            [resident(bothHolds), resident(bothHolds - sessionBytes), resident(weightsBytes), evicted],
            [resident(bothHolds), resident(footprintBytes), resident(weightsBytes), evicted],
        ]
    }()

    /// Keeps one hold until a task releases it. Then a test can release two
    /// holds from two tasks at the same time.
    private final class HoldSlot: Sendable {
        /// The hold, or nil after the release.
        private let hold: Mutex<ModelHold?>

        /// Keeps `hold`.
        ///
        /// - Parameter hold: The hold to keep.
        init(_ hold: ModelHold) {
            self.hold = Mutex(hold)
        }

        /// Releases the hold.
        func release() {
            hold.withLock { $0 = nil }
        }
    }

    /// Acquires ``key`` from `pool` with ``footprintBytes`` and `sessionBytes`.
    ///
    /// - Parameters:
    ///   - pool: The pool.
    ///   - loader: The loader.
    ///   - sessionBytes: The bytes of the session of the hold.
    /// - Returns: The hold.
    /// - Throws: What the load throws.
    private static func acquire(
        from pool: ModelPool, with loader: RecordingLoader, sessionBytes: Int64 = sessionBytes
    ) async throws -> ModelHold {
        try await pool.acquire(key, footprintBytes: footprintBytes, sessionBytes: sessionBytes, loader: loader)
    }

    /// The model in `hold`.
    ///
    /// - Parameter hold: A hold of a model that a ``RecordingLoader`` made.
    /// - Returns: The model.
    /// - Throws: An `ExpectationFailedError` when the container is not a
    ///   ``FakeModel``.
    private static func model(in hold: ModelHold) throws -> FakeModel {
        try #require(hold.container as? FakeModel)
    }

    /// An admit job that holds the admission queue until the test ends it.
    private struct BlockingJob<Value: Sendable> {
        /// The task that waits for the job, and gives what the job gave.
        let task: Task<Value, any Error>

        /// Finish this to end the job.
        let end: AsyncStream<Void>.Continuation
    }

    /// Starts an admit job that writes `"job begins"`, waits until the test
    /// ends it, and writes `"job ends"`. Returns when the job runs.
    ///
    /// - Parameters:
    ///   - pool: The pool.
    ///   - log: The log.
    /// - Returns: The job.
    /// - Throws: An `ExpectationFailedError` when the job never ran.
    private static func startBlockingJob(on pool: ModelPool, log: Recorder<String>) async throws -> BlockingJob<Void> {
        try await startBlockingJob(on: pool, log: log) { _ in }
    }

    /// Starts an admit job that writes `"job begins"`, waits until the test
    /// ends it, runs `last`, writes `"job ends"`, and gives what `last` gave.
    /// Returns when the job runs.
    ///
    /// - Parameters:
    ///   - pool: The pool.
    ///   - log: The log.
    ///   - last: The work of the job after the test ends the wait.
    /// - Returns: The job.
    /// - Throws: An `ExpectationFailedError` when the job never ran.
    private static func startBlockingJob<Value: Sendable>(
        on pool: ModelPool, log: Recorder<String>,
        last: @escaping @Sendable (ModelPoolAdmission) async throws -> Value
    ) async throws -> BlockingJob<Value> {
        let (mayEnd, end) = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            try await pool.admit { admission in
                log.append("job begins")
                for await _ in mayEnd {}
                let value = try await last(admission)
                log.append("job ends")
                return value
            }
        }
        await log.waitUntil(holds: "job begins", orUntilEndOf: task)
        try #require(log.values.contains("job begins"))
        return BlockingJob(task: task, end: end)
    }

    /// Starts an acquire of ``key`` that writes `"resident acquired"` when it
    /// returns. Returns when the acquire returned, or when its admission job
    /// waits in the queue behind the blocking job first. The acquire records
    /// its metrics into `capture`, thus the test sees the job that it puts in
    /// the admission queue.
    ///
    /// - Parameters:
    ///   - pool: The pool.
    ///   - loader: The loader.
    ///   - log: The log.
    ///   - capture: The capture that gets the metrics of the acquire.
    /// - Returns: The task of the acquire, and whether it returned with no
    ///   job in the admission queue.
    private static func acquireWhileAJobRuns(
        from pool: ModelPool, with loader: RecordingLoader, log: Recorder<String>,
        recordingInto capture: TelemetryCapture.Context
    ) async -> (task: Task<ModelHold, any Error>, returned: Bool) {
        let admissions = pool.admissions
        let recordsBefore = admissions.depthRecordCount(in: capture)
        let factory = capture.observedMetricsFactory
        let task = Task {
            try await withMetricsFactory(factory) {
                let hold = try await acquire(from: pool, with: loader)
                log.append("resident acquired")
                return hold
            }
        }
        await Waits.untilFirstEnds(
            { await log.waitUntil { $0.contains("resident acquired") } },
            { await admissions.waitForDepthRecords(moreThan: recordsBefore, in: capture) })
        return (task, log.values.contains("resident acquired"))
    }

    /// Starts an acquire with `acquire`, and returns when the admission queue
    /// of `pool` accepted its job, or when the acquire ended first.
    ///
    /// - Parameters:
    ///   - pool: The pool.
    ///   - capture: The capture that gets the metrics of the acquire.
    ///   - acquire: The acquire.
    /// - Returns: The task of the acquire.
    private static func startQueuedAcquire(
        on pool: ModelPool, recordingInto capture: TelemetryCapture.Context,
        _ acquire: @escaping @Sendable () async throws -> ModelHold
    ) async -> Task<ModelHold, any Error> {
        await pool.admissions.startQueuedCall(recordingInto: capture, acquire)
    }

    /// Waits until the loader of `log` writes `entry`, or until each job that
    /// is in the admission queue of `pool` now ended. A load and an evict
    /// call run in an admission job, thus that end is the fault event of a
    /// load or an evict call that never comes.
    ///
    /// - Parameters:
    ///   - log: The log of the loader.
    ///   - entry: The entry to wait for.
    ///   - pool: The pool.
    private static func waitUntil(_ log: Recorder<String>, holds entry: String, orUntilTheJobsOf pool: ModelPool) async {
        await Waits.untilFirstEnds(
            { await log.waitUntil { $0.contains(entry) } },
            { _ = try? await pool.waitForTheEarlierAdmissionJobs() })
    }

    @Test("two concurrent acquires of one new key run the loader one time and get the same container")
    func twoConcurrentAcquiresLoadOneTime() async throws {
        let pool = ModelPool()
        let log = Recorder<String>()
        let (loadsMayEnd, endLoads) = AsyncStream.makeStream(of: Void.self)
        let loader = RecordingLoader(name: "A", log: log, loadsMayEnd: loadsMayEnd)

        defer { endLoads.finish() }
        let first = Task { try await Self.acquire(from: pool, with: loader) }
        await log.waitUntil(holds: Self.loadByA, orUntilEndOf: first)
        try #require(log.values == [Self.loadByA])
        let second = try await TelemetryCapture.run(forbidding: []) { context in
            await Self.startQueuedAcquire(on: pool, recordingInto: context) {
                try await Self.acquire(from: pool, with: loader)
            }
        }
        endLoads.finish()
        let firstHold = try await first.value
        let secondHold = try await second.value

        #expect(log.values == [Self.loadByA])
        #expect(try Self.model(in: firstHold) === Self.model(in: secondHold))
    }

    @Test("acquire of a resident key returns while an admit job runs")
    func residentAcquireDoesNotWaitForAnAdmitJob() async throws {
        let pool = ModelPool()
        let log = Recorder<String>()
        let loader = RecordingLoader(name: "A", log: log)
        let firstHold = try await Self.acquire(from: pool, with: loader)
        let job = try await Self.startBlockingJob(on: pool, log: log)

        let second = try await TelemetryCapture.run(forbidding: []) { context in
            await Self.acquireWhileAJobRuns(from: pool, with: loader, log: log, recordingInto: context)
        }
        job.end.finish()
        try await job.task.value
        let secondHold = try await second.task.value

        #expect(second.returned)
        #expect(log.values == [Self.loadByA, "job begins", "resident acquired", "job ends"])
        #expect(try Self.model(in: firstHold) === Self.model(in: secondHold))
    }

    @Test("acquire of a new key, started while an admit job that loads a first key runs, loads only after that job ends")
    func newKeyAcquireLoadsAfterTheAdmitJob() async throws {
        let pool = ModelPool()
        let log = Recorder<String>()
        let loader = RecordingLoader(name: "A", log: log)
        let footprints = pool.footprints
        let job = try await Self.startBlockingJob(on: pool, log: log) { admission in
            // The job loads its key after the acquire of the test waits in
            // the admission queue.
            try await admission.acquire(
                Self.jobKey, footprintBytes: Self.footprintBytes, sessionBytes: Self.sessionBytes, loader: loader)
        }

        let acquiring = try await TelemetryCapture.run(forbidding: []) { context in
            await Self.startQueuedAcquire(on: pool, recordingInto: context) {
                try await Self.acquire(from: pool, with: loader)
            }
        }
        let logWhileTheJobRuns = log.values
        job.end.finish()
        let jobHold = try await job.task.value
        let hold = try await acquiring.value

        #expect(logWhileTheJobRuns == ["job begins"])
        #expect(log.values == ["job begins", Self.loadOfJobKey, "job ends", Self.loadByA])
        #expect(hold.key == Self.key)
        // The second load starts only after the first model is resident.
        #expect(await Self.first(Self.oneLoadAtATime.count, of: footprints) == Self.oneLoadAtATime)
        withExtendedLifetime(jobHold) {}
    }

    @Test("inside an admit job, admission.acquire of a new key loads it with no deadlock")
    func admissionAcquireLoadsInsideTheJob() async throws {
        let pool = ModelPool()
        let log = Recorder<String>()
        let loader = RecordingLoader(name: "A", log: log)

        // A second admission job while the first one runs never starts, and
        // the first job waits for it: a deadlock. The depth record of that
        // second job ends the wait, and the test then fails before it waits
        // for the deadlocked job.
        let admitted = try await TelemetryCapture.run(forbidding: []) { context in
            let admissions = pool.admissions
            let factory = context.observedMetricsFactory
            let task = Task {
                try await withMetricsFactory(factory) {
                    try await pool.admit { admission in
                        let hold = try await admission.acquire(
                            Self.key, footprintBytes: Self.footprintBytes, sessionBytes: Self.sessionBytes, loader: loader)
                        log.append("admitted")
                        return hold
                    }
                }
            }
            await Waits.untilFirstEnds(
                { _ = await task.result },
                { await admissions.waitForDepthRecords(moreThan: Self.recordsOfOneRunningJob, in: context) })
            return task
        }
        try #require(log.values.contains("admitted"))
        let hold = try await admitted.value

        #expect(log.values == [Self.loadByA, "admitted"])
        #expect(pool.isResident(Self.key))
        #expect(hold.key == Self.key)
    }

    @Test("a caller with loader B gets the container of loader A, and loader B does not run")
    func theFirstLoaderWins() async throws {
        let pool = ModelPool()
        let log = Recorder<String>()
        let loaderA = RecordingLoader(name: "A", log: log)
        let loaderB = RecordingLoader(name: "B", log: log)

        let holdA = try await Self.acquire(from: pool, with: loaderA)
        let holdB = try await Self.acquire(from: pool, with: loaderB)

        #expect(try Self.model(in: holdB) === Self.model(in: holdA))
        #expect(try Self.model(in: holdB).loaderName == "A")
        #expect(log.values == [Self.loadByA])
    }

    @Test("the last hold release evicts the model one time, and the key is then not resident")
    func theLastReleaseEvictsOneTime() async throws {
        let pool = ModelPool()
        let log = Recorder<String>()
        let loader = RecordingLoader(name: "A", log: log)
        do {
            let firstHold = try await Self.acquire(from: pool, with: loader)
            let secondHold = try await Self.acquire(from: pool, with: loader)
            #expect(try Self.model(in: firstHold) === Self.model(in: secondHold))
        }

        try await pool.waitForTheEarlierAdmissionJobs()

        #expect(log.values == [Self.loadByA, Self.evictionOfA])
        #expect(!pool.isResident(Self.key))
        #expect(pool.residentModelCount == 0)
    }

    @Test("an acquire between the last release and the eviction job keeps the model resident, and evict does not run")
    func anAcquireBeforeTheEvictionJobKeepsTheModel() async throws {
        let pool = ModelPool()
        let log = Recorder<String>()
        let loader = RecordingLoader(name: "A", log: log)
        var firstHold: ModelHold? = try await Self.acquire(from: pool, with: loader)
        let job = try await Self.startBlockingJob(on: pool, log: log)
        #expect(firstHold?.key == Self.key)

        firstHold = nil
        // The last release puts the eviction job in the admission queue in
        // the same step, thus it waits there now.
        try #require(await pool.admissions.waitingCount == 1)
        let second = try await TelemetryCapture.run(forbidding: []) { context in
            await Self.acquireWhileAJobRuns(from: pool, with: loader, log: log, recordingInto: context)
        }
        job.end.finish()
        try await job.task.value
        let secondHold = try await second.task.value
        try await pool.waitForTheEarlierAdmissionJobs()

        #expect(second.returned)
        #expect(log.values == [Self.loadByA, "job begins", "resident acquired", "job ends"])
        #expect(pool.isResident(Self.key))
        #expect(secondHold.key == Self.key)
    }

    @Test("an admit job submitted at once after the last release runs after the eviction")
    func anAdmitJobAfterTheLastReleaseRunsAfterTheEviction() async throws {
        for _ in 0..<Self.releaseRepetitions {
            let pool = ModelPool()
            let log = Recorder<String>()
            let loader = RecordingLoader(name: "A", log: log)
            var hold: ModelHold? = try await Self.acquire(from: pool, with: loader)
            #expect(hold?.key == Self.key)

            hold = nil
            let residentInTheJob = try await pool.admit { admission in admission.footprint.resident }

            #expect(residentInTheJob.isEmpty)
            #expect(log.values == [Self.loadByA, Self.evictionOfA])
        }
    }

    /// An eviction that the test holds inside the evict call of the loader.
    private struct BlockedEviction {
        /// The loader whose evict call waits.
        let loader: RecordingLoader

        /// The model that the evict call evicts.
        let model: FakeModel

        /// Finish this to end the evict call.
        let end: AsyncStream<Void>.Continuation
    }

    /// Acquires ``key`` from `pool` with a loader whose evict call waits,
    /// releases the hold, and returns when the evict call runs.
    ///
    /// - Parameters:
    ///   - pool: The pool.
    ///   - log: The log of the loader.
    /// - Returns: The eviction, which waits inside the evict call.
    /// - Throws: An `ExpectationFailedError` when the evict call never ran, or
    ///   what the load throws.
    private static func startBlockedEviction(on pool: ModelPool, log: Recorder<String>) async throws -> BlockedEviction {
        let (evictionsMayEnd, end) = AsyncStream.makeStream(of: Void.self)
        let loader = RecordingLoader(name: "A", log: log, evictionsMayEnd: evictionsMayEnd)
        let evictedModel = try model(in: try await acquire(from: pool, with: loader))
        await waitUntil(log, holds: evictionOfA, orUntilTheJobsOf: pool)
        try #require(log.values.contains(evictionOfA))
        return BlockedEviction(loader: loader, model: evictedModel, end: end)
    }

    @Test("the pool counts an evicted model until the evict call of its loader returns")
    func thePoolCountsTheModelUntilTheEvictCallReturns() async throws {
        let pool = ModelPool()
        let eviction = try await Self.startBlockedEviction(on: pool, log: Recorder<String>())
        let weightsOnly = ModelPoolFootprint(resident: [Self.key: Self.weightsBytes], loadingBytes: 0)

        let footprintInTheEvictCall = pool.footprint
        let firstValueOfANewStream = await Self.first(1, of: pool.footprints)
        let isResidentInTheEvictCall = pool.isResident(Self.key)
        let residentCountInTheEvictCall = pool.residentModelCount
        eviction.end.finish()
        try await pool.admit { _ in }

        #expect(footprintInTheEvictCall == weightsOnly)
        #expect(firstValueOfANewStream == [weightsOnly])
        #expect(isResidentInTheEvictCall)
        #expect(residentCountInTheEvictCall == 1)
        #expect(pool.footprint == ModelPoolFootprint(resident: [:], loadingBytes: 0))
        #expect(!pool.isResident(Self.key))
    }

    @Test("an acquire while the evict call runs gets no hold of the evicted model, but a new load after the evict call")
    func anAcquireInTheEvictCallLoadsAfterIt() async throws {
        let pool = ModelPool()
        let log = Recorder<String>()
        let eviction = try await Self.startBlockedEviction(on: pool, log: log)

        let acquiring = try await TelemetryCapture.run(forbidding: []) { context in
            await Self.startQueuedAcquire(on: pool, recordingInto: context) {
                try await Self.acquire(from: pool, with: eviction.loader)
            }
        }
        let logInTheEvictCall = log.values
        eviction.end.finish()
        let hold = try await acquiring.value

        #expect(logInTheEvictCall == [Self.loadByA, Self.evictionOfA])
        #expect(log.values == [Self.loadByA, Self.evictionOfA, Self.loadByA])
        #expect(try Self.model(in: hold) !== eviction.model)
        #expect(pool.isResident(Self.key))
    }

    @Test("a failed load throws to its caller, and a later acquire loads again")
    func aFailedLoadThrowsAndALaterAcquireLoadsAgain() async throws {
        let pool = ModelPool()
        let log = Recorder<String>()
        let loader = RecordingLoader(name: "A", log: log, failingLoads: 1)

        await #expect(throws: FakeLoadError.self) {
            try await Self.acquire(from: pool, with: loader)
        }
        let footprintAfterTheFailure = pool.footprint
        let hold = try await Self.acquire(from: pool, with: loader)

        #expect(footprintAfterTheFailure == ModelPoolFootprint(resident: [:], loadingBytes: 0))
        #expect(log.values == [Self.loadByA, Self.loadByA])
        #expect(try Self.model(in: hold).loaderName == "A")
    }

    /// The first `count` footprints that `stream` holds now.
    ///
    /// The pool gives each footprint to each stream in the step that changes
    /// it, thus a footprint of a change that ended is in the buffer of the
    /// stream now. The read runs in a cancelled task: a cancelled stream
    /// gives each value of its buffer, and then ends. Thus the read needs no
    /// wait, and a stream with fewer values gives fewer values, and does not
    /// hang.
    ///
    /// - Parameters:
    ///   - count: The number of footprints to read.
    ///   - stream: The stream.
    /// - Returns: The footprints, in order.
    private static func first(_ count: Int, of stream: AsyncStream<ModelPoolFootprint>) async -> [ModelPoolFootprint] {
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var seen: [ModelPoolFootprint] = []
            for await footprint in stream.prefix(count) {
                seen.append(footprint)
            }
            return seen
        }.value
    }

    @Test("two footprint streams both see each change, and a stream sees the loading bytes during a load")
    func twoFootprintStreamsSeeEachChange() async throws {
        let pool = ModelPool()
        let log = Recorder<String>()
        let loader = RecordingLoader(name: "A", log: log)
        let firstStream = pool.footprints
        let secondStream = pool.footprints
        do {
            let hold = try await Self.acquire(from: pool, with: loader)
            #expect(hold.key == Self.key)
        }
        try await pool.waitForTheEarlierAdmissionJobs()

        let expected = [
            ModelPoolFootprint(resident: [:], loadingBytes: 0),
            ModelPoolFootprint(resident: [:], loadingBytes: Self.footprintBytes),
            ModelPoolFootprint(resident: [Self.key: Self.footprintBytes], loadingBytes: 0),
            ModelPoolFootprint(resident: [Self.key: Self.weightsBytes], loadingBytes: 0),
            ModelPoolFootprint(resident: [:], loadingBytes: 0),
        ]
        #expect(await Self.first(expected.count, of: firstStream) == expected)
        #expect(await Self.first(expected.count, of: secondStream) == expected)
    }

    /// A termination handler of a stream takes the state lock. A yield that
    /// runs while the state lock is held can wait for a consumer task that
    /// the runtime cancels, and the termination handler of that task then
    /// waits for the state lock: a deadlock. Thus each delivery to a stream
    /// must run with the state lock free. The pool calls the delivery probe
    /// just before each delivery, and the probe reads the state lock with no
    /// wait. A pool that delivers under the state lock fails this test at
    /// once, and no deadline is necessary.
    @Test("each footprint yield and each progress send runs with the state lock free")
    func eachStreamDeliveryRunsWithTheStateLockFree() async throws {
        let readings = Recorder<StateLockReading>()
        let pool = ModelPool(loader: MLXModelLoader()) { pool, delivery in
            readings.append(StateLockReading(delivery: delivery, isFree: pool.isStateLockFree))
        }
        let loader = RecordingLoader(name: "A", log: Recorder<String>())
        let footprints = pool.footprints
        let progress = pool.progress(for: Self.key.ref)
        do {
            let hold = try await Self.acquire(from: pool, with: loader)
            #expect(hold.key == Self.key)
        }
        try await pool.waitForTheEarlierAdmissionJobs()

        let deliveries = Set(readings.values.map(\.delivery))
        #expect(deliveries == [.footprint, .progress])
        let lockedReadings = readings.values.filter { !$0.isFree }
        #expect(lockedReadings.isEmpty)

        // The two streams were live during each delivery, and got values.
        #expect(await Self.first(1, of: footprints) == [ModelPoolFootprint(resident: [:], loadingBytes: 0)])
        var lastProgress: ModelLoadProgress?
        for await value in progress {
            lastProgress = value
        }
        #expect(lastProgress == .ready)
    }

    /// What the delivery probe of the lock-order test reads before one
    /// delivery.
    private struct StateLockReading: Sendable {
        /// The kind of the delivery.
        let delivery: ModelPool.StreamDelivery

        /// Whether the state lock was free.
        let isFree: Bool
    }

    @Test("after streams that start and cancel beside holds that release and evict, a live stream sees the last footprint")
    func aLiveStreamSeesTheLastFootprintAfterTheChurn() async throws {
        let pool = ModelPool()
        let log = Recorder<String>()
        let loader = RecordingLoader(name: "A", log: log)
        let seen = Recorder<ModelPoolFootprint>()
        let stream = pool.footprints
        let consumer = Task { for await footprint in stream { seen.append(footprint) } }

        for _ in 0..<Self.churnRounds {
            let churned = Task { for await _ in pool.footprints {} }
            churned.cancel()
            await churned.value
            let hold = try await Self.acquire(from: pool, with: loader)
            #expect(hold.key == Self.key)
        }
        try await pool.waitForTheEarlierAdmissionJobs()
        #expect(log.values.contains(Self.evictionOfA))

        let hold = try await Self.acquire(from: pool, with: loader)
        let last = ModelPoolFootprint(resident: [Self.key: Self.footprintBytes], loadingBytes: 0)
        // The pool gave the last footprint to the stream before the acquire
        // returned. A cancelled stream gives each value of its buffer, and
        // then ends, thus the consumer ends after it read that footprint.
        consumer.cancel()
        await consumer.value
        let sawTheLast = seen.values.last == last

        #expect(sawTheLast)
        #expect(pool.footprint == last)
        #expect(hold.key == Self.key)
    }

    @Test("one stream sees the values of two quick releases in the order that they occurred")
    func oneStreamSeesTwoQuickReleasesInOrder() async throws {
        for _ in 0..<Self.orderRepetitions {
            let pool = ModelPool()
            let loader = RecordingLoader(name: "A", log: Recorder<String>())
            let firstHold = HoldSlot(try await Self.acquire(from: pool, with: loader))
            let secondHold = HoldSlot(
                try await Self.acquire(from: pool, with: loader, sessionBytes: Self.secondSessionBytes))
            let stream = pool.footprints

            async let firstRelease: Void = firstHold.release()
            async let secondRelease: Void = secondHold.release()
            _ = await (firstRelease, secondRelease)
            try await pool.waitForTheEarlierAdmissionJobs()
            let seen = await Self.first(Self.releaseOrders[0].count, of: stream)

            #expect(Self.releaseOrders.contains(seen))
        }
    }

    @Test("the byte totals are correct after a load, a second hold, a release and an eviction")
    func theByteTotalsFollowEachChange() async throws {
        let pool = ModelPool()
        let log = Recorder<String>()
        let loader = RecordingLoader(name: "A", log: log)
        var totals: [Int64] = []
        do {
            let firstHold = try await Self.acquire(from: pool, with: loader)
            totals.append(pool.footprint.totalBytes)
            do {
                let secondHold = try await Self.acquire(
                    from: pool, with: loader, sessionBytes: Self.secondSessionBytes)
                totals.append(pool.footprint.totalBytes)
                #expect(secondHold.key == Self.key)
            }
            totals.append(pool.footprint.totalBytes)
            #expect(firstHold.key == Self.key)
        }
        // The pool counts the model until the evict call returns. The admit
        // job runs after the eviction job, thus after that call.
        try await pool.waitForTheEarlierAdmissionJobs()
        #expect(log.values.contains(Self.evictionOfA))
        totals.append(pool.footprint.totalBytes)

        let afterTheSecondHold = Self.footprintBytes + Self.secondSessionBytes
        #expect(totals == [Self.footprintBytes, afterTheSecondHold, Self.footprintBytes, 0])
    }

    @Test("two pools made with init() do not share entries")
    func twoPoolsDoNotShareEntries() async throws {
        let pool = ModelPool()
        let otherPool = ModelPool()
        let loader = RecordingLoader(name: "A", log: Recorder<String>())

        let hold = try await Self.acquire(from: pool, with: loader)

        #expect(pool.isResident(Self.key))
        #expect(!otherPool.isResident(Self.key))
        #expect(otherPool.residentModelCount == 0)
        #expect(otherPool.footprint.totalBytes == 0)
        #expect(hold.key == Self.key)
    }

    @Test("two acquires by key of a pool made with a loader load one time, with the loader of the pool")
    func acquireByKeyLoadsOneTimeForTwoHolds() async throws {
        let log = Recorder<String>()
        let pool = ModelPool(loader: RecordingLoader(name: "A", log: log))

        let firstHold = try await pool.acquire(Self.key)
        let secondHold = try await pool.acquire(Self.key)

        #expect(log.values == [Self.loadByA, Self.measureOfKey])
        #expect(try Self.model(in: firstHold) === Self.model(in: secondHold))
        #expect(pool.residentModelCount == 1)
    }

    @Test("an acquire with no revision and an acquire with the revision main load the model one time")
    func unpinnedAndMainRevisionShareOneLoad() async throws {
        let log = Recorder<String>()
        let pool = ModelPool(loader: RecordingLoader(name: "A", log: log))

        let unpinnedHold = try await pool.acquire(ModelPoolKey(ref: "org/a", role: .llm))
        let mainHold = try await pool.acquire(ModelPoolKey(ref: "org/a@main", role: .llm))

        #expect(log.values.filter { $0.hasPrefix("load ") } == [Self.loadByA])
        #expect(try Self.model(in: unpinnedHold) === Self.model(in: mainHold))
        #expect(pool.residentModelCount == 1)
    }

    @Test("after the last release of the holds of an acquire by key, the loader of the pool evicts the model")
    func acquireByKeyEvictsAfterTheLastRelease() async throws {
        let log = Recorder<String>()
        let pool = ModelPool(loader: RecordingLoader(name: "A", log: log))
        do {
            let firstHold = try await pool.acquire(Self.key)
            let secondHold = try await pool.acquire(Self.key)
            #expect(firstHold.queue === secondHold.queue)
        }

        try await pool.waitForTheEarlierAdmissionJobs()

        #expect(log.values == [Self.loadByA, Self.measureOfKey, Self.evictionOfA])
        #expect(!pool.isResident(Self.key))
    }

    @Test("an acquire by key counts the bytes that the loader of the pool measures after the load")
    func acquireByKeyCountsTheMeasuredFootprint() async throws {
        let pool = ModelPool(loader: RecordingLoader(name: "A", log: Recorder<String>(), measuredBytes: Self.weightsBytes))

        let firstHold = try await pool.acquire(Self.key)
        let secondHold = try await pool.acquire(Self.key)

        #expect(pool.footprint == ModelPoolFootprint(resident: [Self.key: Self.weightsBytes], loadingBytes: 0))
        #expect(firstHold.key == secondHold.key)
    }

    @Test("a failed footprint measure evicts the loaded model, throws, and leaves the key not resident")
    func aFailedMeasureEvictsTheModel() async throws {
        let log = Recorder<String>()
        let pool = ModelPool(loader: RecordingLoader(name: "A", log: log, failingMeasures: 1))

        await #expect(throws: FakeMeasureError.self) { try await pool.acquire(Self.key) }

        #expect(log.values == [Self.loadByA, Self.measureOfKey, Self.evictionOfA])
        #expect(!pool.isResident(Self.key))
        #expect(pool.footprint == ModelPoolFootprint(resident: [:], loadingBytes: 0))
    }

    @Test("a pool made with init() and the shared pool load with MLXModelLoader")
    func theDefaultLoaderIsTheMLXLoader() {
        #expect(ModelPool().loader is MLXModelLoader)
        #expect(ModelPool.shared.loader is MLXModelLoader)
    }

    @Test("the README example: acquire a model, then admit an embedder that fits the budget")
    func readmeModelPoolExample() async throws {
        let loader = RecordingLoader(name: "A", log: Recorder<String>())

        // README example: begin
        let pool = ModelPool()
        let chat = ModelPoolKey(ref: "mlx-community/Qwen3-8B-4bit", role: .llm)
        let embedding = ModelPoolKey(ref: "mlx-community/bge-small", role: .embedding)
        let chatBytes: Int64 = 5_000_000_000
        let sessionBytes: Int64 = 500_000_000
        let embedderBytes: Int64 = 200_000_000
        let budgetBytes: Int64 = 8_000_000_000

        // A resident key adds a hold at once. A new key loads in the admission queue.
        let chatHold = try await pool.acquire(
            chat, footprintBytes: chatBytes, sessionBytes: sessionBytes, loader: loader)

        // One admission job reads the footprint and loads. No other load can
        // run between the read and the load.
        let embedderHold = try await pool.admit { admission -> ModelHold? in
            let fits = admission.footprint.totalBytes + embedderBytes <= budgetBytes
            return if fits {
                try await admission.acquire(embedding, footprintBytes: embedderBytes, sessionBytes: 0, loader: loader)
            } else {
                nil
            }
        }
        // README example: end

        #expect(chatHold.key == chat)
        #expect(embedderHold?.key == embedding)
        #expect(pool.footprint.totalBytes == chatBytes + embedderBytes)
        #expect(pool.residentModelCount == [chat, embedding].count)
    }

    @Test("an acquire of a new key records one task of the admission queue, with no model ref")
    func anAcquireRecordsAnAdmissionTask() async throws {
        let metrics = TestMetrics()
        let pool = ModelPool()
        let loader = RecordingLoader(name: "A", log: Recorder<String>())

        let hold = try await withMetricsFactory(metrics) {
            try await Self.acquire(from: pool, with: loader)
        }

        try QueueMetricExpectations.expectCompletedJobs(
            in: metrics, queue: QueueMetricDimensions.queue(of: QueueTelemetry(name: .admission)),
            outcome: .succeeded, ran: true)
        withExtendedLifetime(hold) {}
    }

    @Test("an embed call through a hold records one task of the model queue with the model ref of the key")
    func anEmbedThroughAHoldRecordsAModelTask() async throws {
        let metrics = TestMetrics()
        let pool = ModelPool()
        let key = ModelPoolKey(ref: "org/embedder", role: .embedding)
        let loader = FixedLoader(container: FakeEmbedding(vector: [1, 0], log: Recorder()))
        let hold = try await pool.acquire(
            key, footprintBytes: Self.footprintBytes, sessionBytes: Self.sessionBytes, loader: loader)
        let embedder = try PooledEmbedder(hold: hold)

        _ = try await withMetricsFactory(metrics) {
            try await embedder.embed(texts: ["one"])
        }

        try QueueMetricExpectations.expectCompletedJobs(
            in: metrics, queue: QueueMetricDimensions.queue(of: QueueTelemetry(name: .model, model: key.ref)),
            outcome: .succeeded, ran: true)
    }
}

/// The cache telemetry of the model pool: one acquire count with its cache
/// result for each hold, one eviction count and one idle time for each
/// eviction, the meters of the footprint, and one log record for a failed
/// footprint measure.
extension ModelPoolTests {
    /// The bytes of the models whose evict call runs, when no evict call runs.
    private static let noEvictingBytes: Int64 = 0

    /// The count that one acquire or one eviction adds to its counter.
    private static let oneCount: Int64 = 1

    /// The number of durations that one eviction records.
    private static let oneDuration = 1

    /// A file path that a container description can hold. No telemetry
    /// record may hold it.
    private static let containerPath = "/Users/someone/models/org-a/weights.safetensors"

    /// A container whose description holds ``containerPath``.
    private struct PathDescribedModel: CustomStringConvertible, Sendable {
        /// The file path of the model.
        var description: String { ModelPoolTests.containerPath }
    }

    /// Acquires ``key`` three times with `acquire`: a first acquire that
    /// loads, a second acquire that waits in the admission queue behind that
    /// load, and a third acquire after both.
    ///
    /// - Parameters:
    ///   - pool: The pool.
    ///   - log: The log of the loader that `acquire` uses.
    ///   - endLoads: Finish this to end the load.
    ///   - capture: The capture that gets the metrics of each acquire.
    ///   - acquire: Acquires ``key`` from `pool`.
    /// - Returns: The three holds.
    /// - Throws: What an acquire throws, or an `ExpectationFailedError` when
    ///   the load never occurred.
    private static func acquireThreeTimes(
        from pool: ModelPool,
        log: Recorder<String>,
        endLoads: AsyncStream<Void>.Continuation,
        recordingInto capture: TelemetryCapture.Context,
        acquire: @escaping @Sendable () async throws -> ModelHold
    ) async throws -> [ModelHold] {
        let factory = capture.observedMetricsFactory
        let first = Task { try await withMetricsFactory(factory) { try await acquire() } }
        await log.waitUntil(holds: loadByA, orUntilEndOf: first)
        try #require(log.values == [loadByA])
        let second = await startQueuedAcquire(on: pool, recordingInto: capture, acquire)
        endLoads.finish()
        let loaded = try await [first.value, second.value]
        return loaded + [try await withMetricsFactory(factory) { try await acquire() }]
    }

    /// Expects one acquire count of ``key`` with each cache result.
    ///
    /// - Parameter metrics: The factory that the pool recorded into.
    /// - Throws: When `metrics` has no such counter.
    private static func expectOneAcquireOfEachResult(in metrics: TestMetrics) throws {
        for result in PoolCacheResult.allCases {
            #expect(try PoolMetricExpectations.acquireCounts(in: metrics, ref: key.ref, result: result) == [oneCount])
        }
    }

    @Test("an acquire with a loader records one load, one late hit and one hit")
    func anAcquireWithALoaderRecordsEachCacheResult() async throws {
        let pool = ModelPool()
        let log = Recorder<String>()
        let (loadsMayEnd, endLoads) = AsyncStream.makeStream(of: Void.self)
        defer { endLoads.finish() }
        let loader = RecordingLoader(name: "A", log: log, loadsMayEnd: loadsMayEnd)

        let (holds, metrics) = try await TelemetryCapture.run(forbidding: []) { context in
            let holds = try await Self.acquireThreeTimes(from: pool, log: log, endLoads: endLoads, recordingInto: context) {
                try await Self.acquire(from: pool, with: loader)
            }
            return (holds, context.metricsFactory)
        }

        try Self.expectOneAcquireOfEachResult(in: metrics)
        withExtendedLifetime(holds) {}
    }

    @Test("an acquire by key records one load, one late hit and one hit")
    func anAcquireByKeyRecordsEachCacheResult() async throws {
        let log = Recorder<String>()
        let (loadsMayEnd, endLoads) = AsyncStream.makeStream(of: Void.self)
        defer { endLoads.finish() }
        let pool = ModelPool(loader: RecordingLoader(name: "A", log: log, loadsMayEnd: loadsMayEnd))

        let (holds, metrics) = try await TelemetryCapture.run(forbidding: []) { context in
            let holds = try await Self.acquireThreeTimes(from: pool, log: log, endLoads: endLoads, recordingInto: context) {
                try await pool.acquire(Self.key)
            }
            return (holds, context.metricsFactory)
        }

        try Self.expectOneAcquireOfEachResult(in: metrics)
        withExtendedLifetime(holds) {}
    }

    @Test("an eviction records one eviction count and one idle time, and no rehold")
    func anEvictionRecordsACountAndAnIdleTime() async throws {
        let metrics = TestMetrics()
        let pool = ModelPool()
        let log = Recorder<String>()
        let loader = RecordingLoader(name: "A", log: log)

        try await withMetricsFactory(metrics) {
            do {
                let hold = try await Self.acquire(from: pool, with: loader)
                #expect(hold.key == Self.key)
            }
            // The last release puts the eviction job in the admission queue
            // first, thus this admit job ends after the eviction.
            try await pool.admit { _ in }
        }

        #expect(log.values == [Self.loadByA, Self.evictionOfA])
        #expect(try PoolMetricExpectations.evictionCounts(in: metrics, ref: Self.key.ref) == [Self.oneCount])
        QueueMetricExpectations.expectDurations(
            try PoolMetricExpectations.idleToEvictTimes(in: metrics, ref: Self.key.ref), count: Self.oneDuration)
        #expect(throws: TestMetricsError.self) {
            try PoolMetricExpectations.skippedEvictionCounts(in: metrics, ref: Self.key.ref, reason: .rehold)
        }
    }

    @Test("an eviction job that a new hold stops records one rehold, and no eviction and no idle time")
    func aReholdRecordsASkippedEviction() async throws {
        let pool = ModelPool()
        let log = Recorder<String>()
        let loader = RecordingLoader(name: "A", log: log)

        let (secondHold, metrics) = try await TelemetryCapture.run(forbidding: []) { context in
            try await withMetricsFactory(context.observedMetricsFactory) {
                var firstHold: ModelHold? = try await Self.acquire(from: pool, with: loader)
                let job = try await Self.startBlockingJob(on: pool, log: log)
                #expect(firstHold?.key == Self.key)
                firstHold = nil
                // The last release puts the eviction job in the admission
                // queue in the same step, thus it waits there now.
                try #require(await pool.admissions.waitingCount == 1)
                let second = await Self.acquireWhileAJobRuns(from: pool, with: loader, log: log, recordingInto: context)
                job.end.finish()
                try await job.task.value
                try await pool.waitForTheEarlierAdmissionJobs()
                return (try await second.task.value, context.metricsFactory)
            }
        }

        #expect(!log.values.contains(Self.evictionOfA))
        #expect(
            try PoolMetricExpectations.skippedEvictionCounts(in: metrics, ref: Self.key.ref, reason: .rehold)
                == [Self.oneCount])
        #expect(throws: TestMetricsError.self) {
            try PoolMetricExpectations.evictionCounts(in: metrics, ref: Self.key.ref)
        }
        #expect(throws: TestMetricsError.self) {
            try PoolMetricExpectations.idleToEvictTimes(in: metrics, ref: Self.key.ref)
        }
        withExtendedLifetime(secondHold) {}
    }

    @Test("the four pool meters agree with the footprint and the resident count after each change")
    func thePoolMetersFollowEachChange() async throws {
        let metrics = TestMetrics()
        let pool = ModelPool()
        let log = Recorder<String>()
        let (loadsMayEnd, endLoads) = AsyncStream.makeStream(of: Void.self)
        let (evictionsMayEnd, endEvictions) = AsyncStream.makeStream(of: Void.self)
        defer {
            endLoads.finish()
            endEvictions.finish()
        }
        let loader = RecordingLoader(name: "A", log: log, loadsMayEnd: loadsMayEnd, evictionsMayEnd: evictionsMayEnd)

        try await withMetricsFactory(metrics) {
            // The task gives a slot, not the hold: a task keeps its value, so a
            // hold that it gave would never go.
            let loading = Task { HoldSlot(try await Self.acquire(from: pool, with: loader)) }
            await log.waitUntil(holds: Self.loadByA, orUntilEndOf: loading)
            try #require(log.values == [Self.loadByA])
            try PoolMetricExpectations.expectGauges(in: metrics, agreeWith: pool, evictingBytes: Self.noEvictingBytes)
            endLoads.finish()
            let firstHold = try await loading.value
            try PoolMetricExpectations.expectGauges(in: metrics, agreeWith: pool, evictingBytes: Self.noEvictingBytes)
            var secondHold: ModelHold? = try await Self.acquire(
                from: pool, with: loader, sessionBytes: Self.secondSessionBytes)
            try PoolMetricExpectations.expectGauges(in: metrics, agreeWith: pool, evictingBytes: Self.noEvictingBytes)
            #expect(secondHold?.key == Self.key)
            secondHold = nil
            try PoolMetricExpectations.expectGauges(in: metrics, agreeWith: pool, evictingBytes: Self.noEvictingBytes)
            firstHold.release()
            await Self.waitUntil(log, holds: Self.evictionOfA, orUntilTheJobsOf: pool)
            try #require(log.values.contains(Self.evictionOfA))
            try PoolMetricExpectations.expectGauges(in: metrics, agreeWith: pool, evictingBytes: Self.weightsBytes)
            endEvictions.finish()
            try await pool.admit { _ in }
            try PoolMetricExpectations.expectGauges(in: metrics, agreeWith: pool, evictingBytes: Self.noEvictingBytes)
        }
    }

    @Test("a failed footprint measure writes one error record with the error type and the model ref")
    func aFailedMeasureWritesOneLogRecord() async throws {
        let pool = ModelPool(loader: RecordingLoader(name: "A", log: Recorder<String>(), failingMeasures: 1))

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            await #expect(throws: FakeMeasureError.self) { try await pool.acquire(Self.key) }
            return context
        }

        let expected = TelemetryCapture.LogRecord(
            level: .error,
            message: "\(ExtrasTelemetry.PoolLogMessage.measureFailed)",
            metadata: [
                ExtrasTelemetry.LogMetadataKey.errorType: .string(ExtrasTelemetry.errorType(of: FakeMeasureError())),
                ExtrasTelemetry.LogMetadataKey.modelRef: .string(Self.key.ref.stringValue),
            ],
            label: ExtrasTelemetry.logLabel
        )
        // The load span writes its "enter" record at the info level first.
        #expect(context.logRecords.filter { $0.level == .error } == [expected])
    }

    @Test("the telemetry of a failed measure, a load, a hit and an eviction holds no path and no error description")
    func thePoolTelemetryHoldsNoContent() async throws {
        let measureError = FakeMeasureError()
        let forbidden = [Self.containerPath, measureError.localizedDescription, String(describing: measureError)]
        let loader = RecordingLoader(
            name: "A", log: Recorder<String>(), failingMeasures: 1, makeModel: { _ in PathDescribedModel() })
        let pool = ModelPool(loader: loader)

        let context = try await TelemetryCapture.run(forbidding: forbidden) { context in
            await #expect(throws: FakeMeasureError.self) { try await pool.acquire(Self.key) }
            do {
                let holds = [try await pool.acquire(Self.key), try await pool.acquire(Self.key)]
                #expect(holds.map(\.key) == [Self.key, Self.key])
            }
            try await pool.admit { _ in }
            return context
        }

        #expect(!context.logRecords.isEmpty)
        #expect(!context.metricRecords.isEmpty)
    }
}

/// The load telemetry of the model pool: one load span and one "enter" record
/// for each load, one load duration with its outcome, and one footprint
/// record for each measured load.
extension ModelPoolTests {
    /// The bytes that the footprint measure of the load telemetry tests gives.
    private static let measuredFootprintBytes: Int64 = 42

    /// The number of load spans that one load opens.
    private static let oneLoadSpan = 1

    /// The number of "enter" records that one load span writes.
    private static let oneEnterRecord = 1

    /// The number of load spans of a failed load and a load that succeeds.
    private static let twoLoadSpans = 2

    /// A folder of the Hugging Face cache that the error of a load can hold.
    /// No telemetry record may hold it.
    private static let cachePath = "/Users/someone/.cache/huggingface/hub/models--org--a/snapshots/main"

    /// Expects one load span of ``key`` with its model ref, revision and role
    /// in `context`, and one "enter" record of that span.
    ///
    /// - Parameter context: The capture of one load of ``key``.
    /// - Throws: When the capture holds no load span.
    private static func expectOneLoadSpanAndEnterRecord(in context: TelemetryCapture.Context) throws {
        let spanName = ExtrasTelemetry.SpanName.modelLoad
        let loads = ModelLoadTelemetryExpectations.spans(named: spanName, in: context.spans)
        #expect(loads.count == oneLoadSpan)
        ModelLoadTelemetryExpectations.expectLoadAttributes(of: try #require(loads.first), key: key)
        let enterMessage = ExtrasTelemetry.EnterRecord.message(forSpanNamed: spanName)
        #expect(context.logRecords.filter { "\($0.message)" == enterMessage }.count == oneEnterRecord)
    }

    @Test("an acquire by key opens one load span with the model ref, the revision and the role, and one enter record")
    func anAcquireByKeyOpensOneLoadSpan() async throws {
        let pool = ModelPool(loader: RecordingLoader(name: "A", log: Recorder<String>()))

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            let hold = try await pool.acquire(Self.key)
            #expect(hold.key == Self.key)
            return context
        }

        try Self.expectOneLoadSpanAndEnterRecord(in: context)
    }

    @Test("an acquire with a loader opens one load span with the model ref, the revision and the role, and one enter record")
    func anAcquireWithALoaderOpensOneLoadSpan() async throws {
        let pool = ModelPool()
        let loader = RecordingLoader(name: "A", log: Recorder<String>())

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            let hold = try await Self.acquire(from: pool, with: loader)
            #expect(hold.key == Self.key)
            return context
        }

        try Self.expectOneLoadSpanAndEnterRecord(in: context)
    }

    @Test("a load that succeeds records one load duration with the outcome succeeded, and none with failed")
    func aLoadThatSucceedsRecordsOneDuration() async throws {
        let metrics = TestMetrics()
        let pool = ModelPool(loader: RecordingLoader(name: "A", log: Recorder<String>()))

        let hold = try await withMetricsFactory(metrics) { try await pool.acquire(Self.key) }

        QueueMetricExpectations.expectDurations(
            try ModelLoadTelemetryExpectations.loadDurations(in: metrics, key: Self.key, outcome: .succeeded),
            count: Self.oneDuration)
        #expect(throws: TestMetricsError.self) {
            try ModelLoadTelemetryExpectations.loadDurations(in: metrics, key: Self.key, outcome: .failed)
        }
        withExtendedLifetime(hold) {}
    }

    @Test("a load that fails records one load duration with the outcome failed, and none with succeeded")
    func aLoadThatFailsRecordsOneDuration() async throws {
        let metrics = TestMetrics()
        let pool = ModelPool(loader: RecordingLoader(name: "A", log: Recorder<String>(), failingLoads: 1))

        await #expect(throws: FakeLoadError.self) {
            try await withMetricsFactory(metrics) { try await pool.acquire(Self.key) }
        }

        QueueMetricExpectations.expectDurations(
            try ModelLoadTelemetryExpectations.loadDurations(in: metrics, key: Self.key, outcome: .failed),
            count: Self.oneDuration)
        #expect(throws: TestMetricsError.self) {
            try ModelLoadTelemetryExpectations.loadDurations(in: metrics, key: Self.key, outcome: .succeeded)
        }
    }

    @Test("a measured load records the measured bytes on the footprint recorder")
    func aMeasuredLoadRecordsTheFootprint() async throws {
        let metrics = TestMetrics()
        let loader = RecordingLoader(name: "A", log: Recorder<String>(), measuredBytes: Self.measuredFootprintBytes)
        let pool = ModelPool(loader: loader)

        let hold = try await withMetricsFactory(metrics) { try await pool.acquire(Self.key) }

        #expect(
            try ModelLoadTelemetryExpectations.footprintBytes(in: metrics, key: Self.key)
                == [Double(Self.measuredFootprintBytes)])
        withExtendedLifetime(hold) {}
    }

    @Test("the load telemetry of a failed load and a measured load holds no cache path and no error description")
    func theLoadTelemetryHoldsNoContent() async throws {
        let loadError = MLXModelLoaderError.unknownFileSize(path: Self.cachePath)
        let forbidden = [
            Self.cachePath, Self.containerPath, loadError.localizedDescription, String(describing: loadError),
        ]
        let loader = RecordingLoader(
            name: "A", log: Recorder<String>(), failingLoads: 1, loadError: loadError,
            measuredBytes: Self.measuredFootprintBytes, makeModel: { _ in PathDescribedModel() })
        let pool = ModelPool(loader: loader)

        let context = try await TelemetryCapture.run(forbidding: forbidden) { context in
            await #expect(throws: MLXModelLoaderError.self) { try await pool.acquire(Self.key) }
            let hold = try await pool.acquire(Self.key)
            #expect(hold.key == Self.key)
            return context
        }

        let loads = ModelLoadTelemetryExpectations.spans(named: ExtrasTelemetry.SpanName.modelLoad, in: context.spans)
        #expect(loads.count == Self.twoLoadSpans)
        #expect(context.metricRecords.contains { $0.label == ExtrasTelemetry.MetricName.modelLoadDuration })
        #expect(context.metricRecords.contains { $0.label == ExtrasTelemetry.MetricName.modelFootprintBytes })
    }

    @Test("an eviction records one evict duration with the model ref, the role and the outcome succeeded")
    func anEvictionRecordsOneEvictDuration() async throws {
        let metrics = TestMetrics()
        let pool = ModelPool(loader: RecordingLoader(name: "A", log: Recorder<String>()))

        try await withMetricsFactory(metrics) {
            do {
                let hold = try await pool.acquire(Self.key)
                #expect(hold.key == Self.key)
            }
            // The last release puts the eviction job in the admission queue
            // first, thus this admit job ends after the eviction.
            try await pool.admit { _ in }
        }

        QueueMetricExpectations.expectDurations(
            try ModelLoadTelemetryExpectations.evictDurations(in: metrics, key: Self.key, outcome: .succeeded),
            count: Self.oneDuration)
        #expect(throws: TestMetricsError.self) {
            try ModelLoadTelemetryExpectations.evictDurations(in: metrics, key: Self.key, outcome: .failed)
        }
    }

    @Test("the telemetry of a failed prewarm and an eviction holds no cache path and no error description")
    func thePrewarmAndEvictTelemetryHoldsNoContent() async throws {
        let loadError = MLXModelLoaderError.unknownFileSize(path: Self.cachePath)
        let forbidden = [
            Self.cachePath, Self.containerPath, loadError.localizedDescription, String(describing: loadError),
        ]
        let loader = RecordingLoader(
            name: "A", log: Recorder<String>(), failingLoads: 1, loadError: loadError,
            makeModel: { _ in PathDescribedModel() })
        let pool = ModelPool(loader: loader)
        let model = PooledModel(ref: Self.key.ref, pool: pool)

        let context = try await TelemetryCapture.run(forbidding: forbidden) { context in
            model.prewarm(transcript: Transcript())
            _ = await context.waitForErrorRecords()
            do {
                let hold = try await pool.acquire(Self.key)
                #expect(hold.key == Self.key)
            }
            try await pool.admit { _ in }
            return context
        }

        #expect(!context.errorRecords.isEmpty)
        #expect(context.metricRecords.contains { $0.label == ExtrasTelemetry.MetricName.modelEvictDuration })
    }
}
