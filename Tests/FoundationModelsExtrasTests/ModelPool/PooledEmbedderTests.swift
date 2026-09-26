@testable import FoundationModelsExtras
import Testing

/// All holds of one key share one queue, and a ``PooledEmbedder`` runs each
/// embed call as one job in that queue.
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

    /// Waits until `count` jobs wait in `queue`.
    ///
    /// - Parameters:
    ///   - count: The number of waiting jobs.
    ///   - queue: The queue.
    /// - Throws: An `ExpectationFailedError` when the jobs did not wait.
    private static func waitForQueuedCalls(_ count: Int, on queue: GenerationQueue) async throws {
        try #require(await BoundedWait.conditionReached("\(count) calls wait in the queue") {
            await queue.waitingCount == count
        })
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
        try await Self.waitForQueuedCalls(1, on: model.hold.queue)
        let third = Task { try await model.embedder.embed(texts: ["three"]) }
        try await Self.waitForQueuedCalls(2, on: model.hold.queue)
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
        #expect(embedderB.dimension == Self.vectorA.count)
        #expect(holdA.key == Self.key)
    }

    @Test("the model is not evicted while an embedder handle exists")
    func theHandleKeepsTheModelResident() async throws {
        let pool = ModelPool()
        let loader = FixedLoader(container: FakeEmbedding(vector: Self.vectorA, log: Recorder()))

        var embedder: PooledEmbedder? = try PooledEmbedder(hold: await Self.acquire(from: pool, with: loader))
        let footprintWithTheHandle = pool.footprint
        #expect(embedder?.dimension == Self.vectorA.count)
        embedder = nil

        #expect(footprintWithTheHandle == ModelPoolFootprint(resident: [Self.key: Self.footprintBytes], loadingBytes: 0))
        #expect(await BoundedWait.conditionReached("the eviction after the handle goes") { !pool.isResident(Self.key) })
    }

    @Test("a cancelled embed call that waits in the queue does not block the next call")
    func aCancelledWaitingCallDoesNotBlockTheNextCall() async throws {
        let pool = ModelPool()
        let model = try await Self.startBlockedCall(on: pool)

        let cancelled = Task { try await model.embedder.embed(texts: ["two"]) }
        try await Self.waitForQueuedCalls(1, on: model.hold.queue)
        cancelled.cancel()
        let next = Task { try await model.embedder.embed(texts: ["three"]) }
        try await Self.waitForQueuedCalls(1, on: model.hold.queue)
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

    @Test("the README example: embed two texts through a pooled embedder")
    func readmeEmbedderExample() async throws {
        let pool = ModelPool()
        let loader = FixedLoader(container: FakeEmbedding(vector: Self.vectorA, log: Recorder()))
        let embedding = ModelPoolKey(ref: "mlx-community/bge-small", role: .embedding)
        let embedderBytes: Int64 = 200_000_000
        let texts = ["first text", "second text"]

        // README example: begin
        // The handle keeps the hold, so the model stays resident. Each call
        // is one job in the queue that all holds of the key share.
        let hold = try await pool.acquire(embedding, footprintBytes: embedderBytes, sessionBytes: 0, loader: loader)
        let embedder = try PooledEmbedder(hold: hold)
        let vectors = try await embedder.embed(texts: texts)
        // README example: end

        #expect(vectors.count == texts.count)
        #expect(vectors.allSatisfy { $0.count == embedder.dimension })
    }
}
