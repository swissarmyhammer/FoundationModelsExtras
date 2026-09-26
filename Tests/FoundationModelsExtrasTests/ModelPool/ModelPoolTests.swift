@testable import FoundationModelsExtras
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

    /// The bytes of ``key`` for its first hold: the weights and one session.
    private static let footprintBytes: Int64 = 10

    /// The bytes of one session of the first hold.
    private static let sessionBytes: Int64 = 2

    /// The bytes of one session of a second hold.
    private static let secondSessionBytes: Int64 = 3

    /// The bytes of the weights of ``key``.
    private static let weightsBytes = footprintBytes - sessionBytes

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
    private struct BlockingJob {
        /// The task that waits for the job.
        let task: Task<Void, any Error>

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
    private static func startBlockingJob(on pool: ModelPool, log: Recorder<String>) async throws -> BlockingJob {
        let (mayEnd, end) = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            try await pool.admit { _ in
                log.append("job begins")
                for await _ in mayEnd {}
                log.append("job ends")
            }
        }
        try #require(await BoundedWait.conditionReached("the admit job runs") { log.values.contains("job begins") })
        return BlockingJob(task: task, end: end)
    }

    /// Waits until one job waits in the admission queue of `pool`.
    ///
    /// - Parameter pool: The pool.
    /// - Throws: An `ExpectationFailedError` when no job waited.
    private static func waitForOneQueuedJob(on pool: ModelPool) async throws {
        try #require(await BoundedWait.conditionReached("a job waits in the admission queue") {
            await pool.admissions.waitingCount == 1
        })
    }

    /// Starts an acquire of ``key`` that writes `"resident acquired"` when it
    /// returns, and waits inside the bound for that write. A blocking job runs,
    /// so the test must not wait for the acquire with no bound.
    ///
    /// - Parameters:
    ///   - pool: The pool.
    ///   - loader: The loader.
    ///   - log: The log.
    /// - Returns: The task of the acquire, and whether it returned inside the
    ///   bound.
    private static func acquireWhileAJobRuns(
        from pool: ModelPool, with loader: RecordingLoader, log: Recorder<String>
    ) async -> (task: Task<ModelHold, any Error>, returned: Bool) {
        let task = Task {
            let hold = try await acquire(from: pool, with: loader)
            log.append("resident acquired")
            return hold
        }
        let returned = await BoundedWait.conditionReached("the resident acquire returns") {
            log.values.contains("resident acquired")
        }
        return (task, returned)
    }

    @Test("two concurrent acquires of one new key run the loader one time and get the same container")
    func twoConcurrentAcquiresLoadOneTime() async throws {
        let pool = ModelPool()
        let log = Recorder<String>()
        let (loadsMayEnd, endLoads) = AsyncStream.makeStream(of: Void.self)
        let loader = RecordingLoader(name: "A", log: log, loadsMayEnd: loadsMayEnd)

        let first = Task { try await Self.acquire(from: pool, with: loader) }
        try #require(await BoundedWait.conditionReached("the first load runs") { log.values == [Self.loadByA] })
        let second = Task { try await Self.acquire(from: pool, with: loader) }
        try await Self.waitForOneQueuedJob(on: pool)
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

        let second = await Self.acquireWhileAJobRuns(from: pool, with: loader, log: log)
        job.end.finish()
        try await job.task.value
        let secondHold = try await second.task.value

        #expect(second.returned)
        #expect(log.values == [Self.loadByA, "job begins", "resident acquired", "job ends"])
        #expect(try Self.model(in: firstHold) === Self.model(in: secondHold))
    }

    @Test("acquire of a new key, started while an admit job runs, loads only after that job ends")
    func newKeyAcquireLoadsAfterTheAdmitJob() async throws {
        let pool = ModelPool()
        let log = Recorder<String>()
        let loader = RecordingLoader(name: "A", log: log)
        let job = try await Self.startBlockingJob(on: pool, log: log)

        let acquiring = Task { try await Self.acquire(from: pool, with: loader) }
        try await Self.waitForOneQueuedJob(on: pool)
        let logWhileTheJobRuns = log.values
        job.end.finish()
        try await job.task.value
        let hold = try await acquiring.value

        #expect(logWhileTheJobRuns == ["job begins"])
        #expect(log.values == ["job begins", "job ends", Self.loadByA])
        #expect(hold.key == Self.key)
    }

    @Test("inside an admit job, admission.acquire of a new key loads it with no deadlock")
    func admissionAcquireLoadsInsideTheJob() async throws {
        let pool = ModelPool()
        let log = Recorder<String>()
        let loader = RecordingLoader(name: "A", log: log)

        let admitted = Task {
            try await pool.admit { admission in
                let hold = try await admission.acquire(
                    Self.key, footprintBytes: Self.footprintBytes, sessionBytes: Self.sessionBytes, loader: loader)
                log.append("admitted")
                return hold
            }
        }
        try #require(await BoundedWait.conditionReached("the load inside the admit job ends") {
            log.values.contains("admitted")
        })
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

        try #require(await BoundedWait.conditionReached("the eviction runs") { log.values.contains(Self.evictionOfA) })
        try await pool.admit { _ in }

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
        try await Self.waitForOneQueuedJob(on: pool)
        let second = await Self.acquireWhileAJobRuns(from: pool, with: loader, log: log)
        job.end.finish()
        try await job.task.value
        let secondHold = try await second.task.value
        try await pool.admit { _ in }

        #expect(second.returned)
        #expect(log.values == [Self.loadByA, "job begins", "resident acquired", "job ends"])
        #expect(pool.isResident(Self.key))
        #expect(secondHold.key == Self.key)
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

    /// The first `count` footprints of `stream`.
    ///
    /// - Parameters:
    ///   - count: The number of footprints to read.
    ///   - stream: The stream.
    /// - Returns: The footprints, in order.
    /// - Throws: An `ExpectationFailedError` when fewer footprints came.
    private static func first(
        _ count: Int, of stream: AsyncStream<ModelPoolFootprint>
    ) async throws -> [ModelPoolFootprint] {
        let seen = Recorder<ModelPoolFootprint>()
        Task {
            for await footprint in stream.prefix(count) {
                seen.append(footprint)
            }
        }
        try #require(await BoundedWait.conditionReached("\(count) footprints") { seen.values.count == count })
        return seen.values
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
        try #require(await BoundedWait.conditionReached("the eviction runs") { log.values.contains(Self.evictionOfA) })

        let expected = [
            ModelPoolFootprint(resident: [:], loadingBytes: 0),
            ModelPoolFootprint(resident: [:], loadingBytes: Self.footprintBytes),
            ModelPoolFootprint(resident: [Self.key: Self.footprintBytes], loadingBytes: 0),
            ModelPoolFootprint(resident: [Self.key: Self.weightsBytes], loadingBytes: 0),
            ModelPoolFootprint(resident: [:], loadingBytes: 0),
        ]
        #expect(try await Self.first(expected.count, of: firstStream) == expected)
        #expect(try await Self.first(expected.count, of: secondStream) == expected)
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
        try #require(await BoundedWait.conditionReached("the eviction runs") { log.values.contains(Self.evictionOfA) })
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
}
