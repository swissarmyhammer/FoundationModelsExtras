@testable import FoundationModelsExtras
import Testing

/// All holds of one key share one queue, and a ``PooledEmbedder`` runs each
/// embed call as one job in that queue. An embedder made from a name loads its
/// model on the first embed call.
@Suite("Pooled embedder: one queue for each model, and each embed call runs in it")
struct PooledEmbedderTests {
    /// The key that the tests acquire.
    private static let key = ModelPoolKey(ref: "org/embedder", role: .embedding)

    /// The bytes of ``key`` for its first hold: the weights and one session.
    private static let footprintBytes: Int64 = 10

    /// The bytes of one session.
    private static let sessionBytes: Int64 = 2

    /// The vector of each text for the model of loader A.
    private static let vectorA: [Float] = [1, 0]

    /// The vector of each text for the model of loader B.
    private static let vectorB: [Float] = [0, 1]

    /// One call that waits in the queue.
    private static let oneWaitingCall = 1

    /// Two calls that wait in the queue.
    private static let twoWaitingCalls = 2

    /// The name of the loader that ``embeddingLoader(log:loadsMayEnd:failingLoads:)`` makes.
    private static let loaderName = "A"

    /// The log entry of one load of ``key`` by the loader that
    /// ``embeddingLoader(log:loadsMayEnd:failingLoads:)`` makes.
    private static let loadEntry = "load \(key.ref.stringValue) by \(loaderName)"

    /// Acquires ``key`` from `pool`.
    ///
    /// - Parameters:
    ///   - pool: The pool.
    ///   - loader: The loader.
    /// - Returns: The hold.
    /// - Throws: What the load throws.
    private static func acquire(from pool: ModelPool, with loader: any PooledModelLoader) async throws -> ModelHold {
        try await pool.acquire(key, footprintBytes: footprintBytes, sessionBytes: sessionBytes, loader: loader)
    }

    /// Makes a loader that writes each load to `log`, and gives a
    /// ``FakeEmbedding`` of ``vectorA``.
    ///
    /// - Parameters:
    ///   - log: The log of the loads, the measures and the evictions.
    ///   - loadsMayEnd: A load ends only after this stream finishes. The
    ///     default stream is finished, so a load ends at once.
    ///   - failingLoads: The number of first loads that fail.
    /// - Returns: The loader.
    private static func embeddingLoader(
        log: Recorder<String>,
        loadsMayEnd: AsyncStream<Void> = AsyncStream { $0.finish() },
        failingLoads: Int = 0
    ) -> RecordingLoader {
        let embedding = FakeEmbedding(vector: vectorA, log: Recorder())
        return RecordingLoader(
            name: loaderName, log: log, loadsMayEnd: loadsMayEnd, failingLoads: failingLoads,
            makeModel: { _ in embedding })
    }

    /// The loads in `log`.
    ///
    /// - Parameter log: The log of a loader that
    ///   ``embeddingLoader(log:loadsMayEnd:failingLoads:)`` made.
    /// - Returns: Each load entry, in order.
    private static func loads(in log: Recorder<String>) -> [String] {
        log.values.filter { $0.hasPrefix("load ") }
    }

    /// A hold of a model that blocks its first call, and its embedder.
    private struct BlockedModel {
        /// The hold.
        let hold: ModelHold
        /// The embedder of the hold.
        let embedder: PooledEmbedder
        /// The log of the calls.
        let log: Recorder<String>
        /// Finish this to end the first call.
        let endFirstCall: AsyncStream<Void>.Continuation
        /// The task of the first call, which runs.
        let firstCall: Task<[[Float]], any Error>
    }

    /// Acquires a model whose first call blocks, and starts that call with
    /// the text `"one"`. Returns when the call runs.
    ///
    /// - Parameter pool: The pool.
    /// - Returns: The model and its running first call.
    /// - Throws: An `ExpectationFailedError` when the first call never ran.
    private static func startBlockedCall(on pool: ModelPool) async throws -> BlockedModel {
        let log = Recorder<String>()
        let (firstCallMayEnd, endFirstCall) = AsyncStream.makeStream(of: Void.self)
        let embedding = FakeEmbedding(vector: vectorA, log: log, firstCallMayEnd: firstCallMayEnd)
        let hold = try await acquire(from: pool, with: FixedLoader(container: embedding))
        let embedder = try PooledEmbedder(hold: hold)
        let firstCall = Task { try await embedder.embed(texts: ["one"]) }
        try #require(await BoundedWait.conditionReached("the first call runs") { log.values == ["begin one"] })
        return BlockedModel(hold: hold, embedder: embedder, log: log, endFirstCall: endFirstCall, firstCall: firstCall)
    }

    @Test("two holds of one key get the same queue instance")
    func twoHoldsShareOneQueue() async throws {
        let pool = ModelPool()
        let loader = FixedLoader(container: FakeEmbedding(vector: Self.vectorA, log: Recorder()))

        let first = try await Self.acquire(from: pool, with: loader)
        let second = try await Self.acquire(from: pool, with: loader)

        #expect(first.queue === second.queue)
    }

    @Test("concurrent embed calls on one key run one at a time, in FIFO order")
    func concurrentCallsRunOneAtATimeInOrder() async throws {
        let pool = ModelPool()
        let model = try await Self.startBlockedCall(on: pool)

        let second = Task { try await model.embedder.embed(texts: ["two"]) }
        try await model.hold.queue.waitForWaitingJobs(count: Self.oneWaitingCall)
        let third = Task { try await model.embedder.embed(texts: ["three"]) }
        try await model.hold.queue.waitForWaitingJobs(count: Self.twoWaitingCalls)
        model.endFirstCall.finish()
        _ = try await (model.firstCall.value, second.value, third.value)

        #expect(model.log.values == ["begin one", "end one", "begin two", "end two", "begin three", "end three"])
    }

    @Test("a caller with loader B gets the container of loader A, and embeds through PooledEmbedding")
    func aCallerWithLoaderBEmbedsWithTheModelOfLoaderA() async throws {
        let pool = ModelPool()
        let loaderA = FixedLoader(container: FakeEmbedding(vector: Self.vectorA, log: Recorder()))
        let loaderB = FixedLoader(container: FakeEmbedding(vector: Self.vectorB, log: Recorder()))

        let holdA = try await Self.acquire(from: pool, with: loaderA)
        let embedderB = try PooledEmbedder(hold: await Self.acquire(from: pool, with: loaderB))
        let vectors = try await embedderB.embed(texts: ["one"])

        #expect(vectors == [Self.vectorA])
        #expect(holdA.key == Self.key)
    }

    @Test("the model is not evicted while an embedder handle exists")
    func theHandleKeepsTheModelResident() async throws {
        let pool = ModelPool()
        let loader = FixedLoader(container: FakeEmbedding(vector: Self.vectorA, log: Recorder()))

        var embedder: PooledEmbedder? = try PooledEmbedder(hold: await Self.acquire(from: pool, with: loader))
        let footprintWithTheHandle = pool.footprint
        #expect(try await embedder?.embed(texts: ["one"]) == [Self.vectorA])
        embedder = nil

        #expect(footprintWithTheHandle == ModelPoolFootprint(resident: [Self.key: Self.footprintBytes], loadingBytes: 0))
        #expect(await BoundedWait.conditionReached("the eviction after the handle goes") { !pool.isResident(Self.key) })
    }

    @Test("a cancelled embed call that waits in the queue does not block the next call")
    func aCancelledWaitingCallDoesNotBlockTheNextCall() async throws {
        let pool = ModelPool()
        let model = try await Self.startBlockedCall(on: pool)

        let cancelled = Task { try await model.embedder.embed(texts: ["two"]) }
        try await model.hold.queue.waitForWaitingJobs(count: Self.oneWaitingCall)
        cancelled.cancel()
        let next = Task { try await model.embedder.embed(texts: ["three"]) }
        try await model.hold.queue.waitForWaitingJobs(count: Self.oneWaitingCall)
        model.endFirstCall.finish()
        let vectors = try await next.value

        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(vectors == [Self.vectorA])
        #expect(model.log.values == ["begin one", "end one", "begin three", "end three"])
    }

    @Test("a cancelled embed call that runs does not block the next call")
    func aCancelledRunningCallDoesNotBlockTheNextCall() async throws {
        let pool = ModelPool()
        let model = try await Self.startBlockedCall(on: pool)

        model.firstCall.cancel()
        let next = Task { try await model.embedder.embed(texts: ["two"]) }
        let nextEnded = await BoundedWait.conditionReached("the next call ends") {
            model.log.values.contains("end two")
        }
        model.endFirstCall.finish()

        #expect(nextEnded)
        #expect(try await next.value == [Self.vectorA])
        await #expect(throws: CancellationError.self) { try await model.firstCall.value }
    }

    @Test("a container that does not conform to PooledEmbedding gives a clear error")
    func aContainerThatIsNotAnEmbeddingThrows() async throws {
        let pool = ModelPool()
        let hold = try await Self.acquire(from: pool, with: RecordingLoader(name: "A", log: Recorder()))
        let expected = PooledEmbedderError.notAnEmbedding(key: Self.key, containerType: "FakeModel")

        #expect(throws: expected) { try PooledEmbedder(hold: hold) }
        #expect(expected.errorDescription?.contains("PooledEmbedding") == true)
    }

    @Test("an embedder made from a name loads nothing")
    func aNamedEmbedderLoadsNothing() async throws {
        let log = Recorder<String>()
        let pool = ModelPool(loader: Self.embeddingLoader(log: log))

        let embedder = PooledEmbedder(ref: Self.key.ref, pool: pool)
        // An admission job ends after each load that is in the admission queue now.
        try await pool.admit { _ in }

        withExtendedLifetime(embedder) {
            #expect(pool.footprint == ModelPoolFootprint(resident: [:], loadingBytes: 0))
            #expect(log.values.isEmpty)
        }
    }

    @Test("the first embed call loads the model of the name with the loader of the pool, and gives its vectors")
    func theFirstEmbedCallLoadsTheModel() async throws {
        let log = Recorder<String>()
        let pool = ModelPool(loader: Self.embeddingLoader(log: log))
        let embedder = PooledEmbedder(ref: Self.key.ref, pool: pool)

        let vectors = try await embedder.embed(texts: ["one", "two"])

        #expect(vectors == [Self.vectorA, Self.vectorA])
        #expect(pool.isResident(Self.key))
        #expect(log.values == [Self.loadEntry, "measure \(Self.key.ref.stringValue)"])
    }

    @Test("two concurrent first embed calls of one embedder make one load")
    func concurrentFirstCallsMakeOneLoad() async throws {
        let log = Recorder<String>()
        let (loadsMayEnd, endLoads) = AsyncStream.makeStream(of: Void.self)
        let pool = ModelPool(loader: Self.embeddingLoader(log: log, loadsMayEnd: loadsMayEnd))
        let embedder = PooledEmbedder(ref: Self.key.ref, pool: pool)

        let first = Task { try await embedder.embed(texts: ["one"]) }
        let second = Task { try await embedder.embed(texts: ["two"]) }
        try #require(await BoundedWait.conditionReached("the load runs") { Self.loads(in: log) == [Self.loadEntry] })
        endLoads.finish()
        let vectors = try await [first.value, second.value]

        #expect(vectors == [[Self.vectorA], [Self.vectorA]])
        #expect(Self.loads(in: log) == [Self.loadEntry])
    }

    @Test("two embedders of one name share one resident model")
    func twoEmbeddersOfOneNameShareOneModel() async throws {
        let log = Recorder<String>()
        let pool = ModelPool(loader: Self.embeddingLoader(log: log))
        let first = PooledEmbedder(ref: Self.key.ref, pool: pool)
        let second = PooledEmbedder(ref: Self.key.ref, pool: pool)

        let vectors = try await [first.embed(texts: ["one"]), second.embed(texts: ["two"])]

        #expect(vectors == [[Self.vectorA], [Self.vectorA]])
        #expect(pool.residentModelCount == 1)
        #expect(Self.loads(in: log) == [Self.loadEntry])
    }

    @Test("the model stays resident while a copy of an embedder exists, and is evicted after the last copy of the last embedder goes")
    func theLastCopyOfTheLastEmbedderEvictsTheModel() async throws {
        let log = Recorder<String>()
        let pool = ModelPool(loader: Self.embeddingLoader(log: log))
        var first: PooledEmbedder? = PooledEmbedder(ref: Self.key.ref, pool: pool)
        var copy = first
        var second: PooledEmbedder? = PooledEmbedder(ref: Self.key.ref, pool: pool)

        _ = try await first?.embed(texts: ["one"])
        _ = try await second?.embed(texts: ["two"])
        first = nil
        second = nil
        // An admission job ends after each eviction job that is in the admission queue now.
        try await pool.admit { _ in }
        let residentWhileACopyExists = pool.isResident(Self.key)
        let copyVectors = try await copy?.embed(texts: ["three"])
        copy = nil

        #expect(residentWhileACopyExists)
        #expect(copyVectors == [Self.vectorA])
        #expect(Self.loads(in: log) == [Self.loadEntry])
        #expect(await BoundedWait.conditionReached("the eviction after the last copy goes") { !pool.isResident(Self.key) })
    }

    @Test("after a failed load, the next embed call loads the model again")
    func theNextCallLoadsAgainAfterAFailedLoad() async throws {
        let log = Recorder<String>()
        let pool = ModelPool(loader: Self.embeddingLoader(log: log, failingLoads: 1))
        let embedder = PooledEmbedder(ref: Self.key.ref, pool: pool)

        await #expect(throws: FakeLoadError.self) { try await embedder.embed(texts: ["one"]) }
        let vectors = try await embedder.embed(texts: ["two"])

        #expect(vectors == [Self.vectorA])
        #expect(Self.loads(in: log) == [Self.loadEntry, Self.loadEntry])
    }

    @Test("an embed call by name on a container that is not a PooledEmbedding gives a clear error, and keeps no hold")
    func aNamedContainerThatIsNotAnEmbeddingThrows() async throws {
        let pool = ModelPool(loader: RecordingLoader(name: Self.loaderName, log: Recorder()))
        let embedder = PooledEmbedder(ref: Self.key.ref, pool: pool)
        let expected = PooledEmbedderError.notAnEmbedding(key: Self.key, containerType: "FakeModel")

        await #expect(throws: expected) { try await embedder.embed(texts: ["one"]) }
        #expect(await BoundedWait.conditionReached("the eviction of the model") { !pool.isResident(Self.key) })
    }

    @Test("the README example: an embedder from a name loads the model on its first call")
    func readmeEmbedderExample() async throws {
        let pool = ModelPool(loader: FixedLoader(container: FakeEmbedding(vector: Self.vectorA, log: Recorder())))

        // README example: begin
        // Loads nothing now. The first call loads the model into the pool.
        let embedder = PooledEmbedder(ref: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ", pool: pool)
        let vectors = try await embedder.embed(texts: ["save my work"])
        // README example: end

        #expect(vectors == [Self.vectorA])
    }
}
